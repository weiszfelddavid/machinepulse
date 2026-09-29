import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import MachinePulseCore
import Observation

@MainActor
@Observable
final class SystemLocalDisplayController: LocalDisplayControlling {
    private(set) var displayStates: [LocalDisplayControlState] = []
    private(set) var preferences: LocalDisplayPreferences
    private(set) var environment: LocalDisplayEnvironment
    private(set) var controllerError: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let overlays: any XDROverlayManaging
    @ObservationIgnored private var manager = LocalDisplaySessionManager()
    @ObservationIgnored private var screensByID: [LocalDisplayID: NSScreen] = [:]
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isAwake = true
    @ObservationIgnored private let isPreview: Bool

    private static let preferencesKey = "localDisplayControls.v1"

    init() {
        preferences = LocalDisplayPreferences.decodePersisted(defaults.data(forKey: Self.preferencesKey))
        environment = Self.systemEnvironment(isAwake: true)
        overlays = XDROverlayController()
        isPreview = false
        refresh()
    }

    private init(
        previewStates: [LocalDisplayControlState],
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment
    ) {
        self.preferences = preferences
        self.environment = environment
        overlays = XDROverlayController()
        isPreview = true
        displayStates = previewStates
    }

    static func preview(
        states: [LocalDisplayControlState] = [],
        preferences: LocalDisplayPreferences = LocalDisplayPreferences(),
        environment: LocalDisplayEnvironment = LocalDisplayEnvironment()
    ) -> SystemLocalDisplayController {
        SystemLocalDisplayController(
            previewStates: states,
            preferences: preferences,
            environment: environment
        )
    }

    func start() {
        guard !isPreview, !started else { return }
        started = true
        registerObservers()
        refresh()
        updatePolling()
    }

    func refresh() {
        refresh(reassertionReason: nil)
    }

    private func refresh(reassertionReason: XDROverlayReassertionReason?) {
        guard !isPreview else { return }
        environment = Self.systemEnvironment(isAwake: isAwake)
        let discovery = Self.discoverDisplays()
        screensByID = discovery.screens
        let commands = manager.reconcile(
            displays: discovery.displays,
            preferences: preferences,
            environment: environment,
            now: Date()
        )
        execute(commands)
        maintainActiveOverlays()
        if let reassertionReason {
            overlays.reassertAll(reason: reassertionReason)
        }
        publish(discovery.displays)
        updatePolling()
    }

    func setControlsShown(_ shown: Bool) {
        preferences.showsControls = shown
        persistPreferences()
        refresh()
    }

    func setTimeoutMinutes(_ minutes: Int) {
        preferences = LocalDisplayPreferences(
            showsControls: preferences.showsControls,
            timeoutMinutes: minutes,
            allowsBoostOnBattery: preferences.allowsBoostOnBattery,
            restoresAfterSleep: preferences.restoresAfterSleep,
            preferredBoostByDisplay: preferences.preferredBoostByDisplay
        )
        persistPreferences()
        publishCurrentScreens()
    }

    func setAllowsBoostOnBattery(_ allowed: Bool) {
        preferences.allowsBoostOnBattery = allowed
        persistPreferences()
        refresh()
    }

    func setRestoresAfterSleep(_ restores: Bool) {
        preferences.restoresAfterSleep = restores
        persistPreferences()
        publishCurrentScreens()
    }

    /// Single-control boost: the slider's minimum means inactive, anything
    /// above activates or retunes the session at that level.
    func setBoostLevel(_ multiplier: Double, for displayID: LocalDisplayID) {
        guard !isPreview, let state = displayStates.first(where: { $0.id == displayID }) else { return }
        if multiplier > LocalDisplaySessionManager.inactiveLevelThreshold {
            preferences.setPreferredBoost(multiplier, for: state.display)
            persistPreferences()
        }
        execute(
            manager.setLevel(
                multiplier,
                for: state.display,
                preferences: preferences,
                environment: environment,
                now: Date()
            )
        )
        publishCurrentScreens()
        updatePolling()
    }

    func turnOffAllBoosts() {
        let commands = manager.activeSessions.keys
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap { manager.disable(displayID: $0) }
        execute(commands)
        publishCurrentScreens()
        updatePolling()
    }

    func openDisplaysSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func copyXDRDiagnostic() -> Bool {
        guard !isPreview else { return false }
        let snapshot = overlays.diagnosticSnapshot
        let displayNames = Dictionary(uniqueKeysWithValues: displayStates.map { ($0.id, $0.display.name) })
        let lifecycleByDisplay = Dictionary(
            uniqueKeysWithValues: snapshot.lifecycle.activeOverlays.map { ($0.displayID, $0) }
        )
        let payload = CopiedXDRDiagnostic(
            formatVersion: 1,
            generatedAt: snapshot.generatedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "development",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            renderMode: "continuous",
            targetFramesPerSecond: XDROverlayRenderPolicy.framesPerSecond,
            privacy: "No pixels, window titles, app names, or screen content are captured.",
            environment: environment,
            displays: displayStates.map { state in
                CopiedXDRDisplay(
                    name: state.display.name,
                    isBuiltIn: state.display.isBuiltIn,
                    potentialEDRMultiplier: state.display.potentialEDRMultiplier,
                    currentEDRMultiplier: state.display.currentEDRMultiplier,
                    boostActive: state.isBoostActive,
                    requestedMultiplier: state.session?.requestedMultiplier,
                    appliedMultiplier: state.session?.appliedMultiplier
                )
            },
            overlays: snapshot.overlays.map { overlay in
                let lifecycle = lifecycleByDisplay[overlay.displayID]
                return CopiedXDROverlay(
                    displayName: displayNames[overlay.displayID] ?? "Disconnected display",
                    instanceID: overlay.instanceID,
                    multiplier: overlay.multiplier,
                    frame: CopiedXDRFrame(overlay.frame),
                    isVisible: overlay.isVisible,
                    targetFramesPerSecond: overlay.targetFramesPerSecond,
                    presentedFrameCount: overlay.renderCounts.presentedFrameCount,
                    failedFrameCount: overlay.renderCounts.failedFrameCount,
                    activatedAt: lifecycle?.activatedAt,
                    geometryChangeCount: lifecycle?.geometryChangeCount ?? 0,
                    multiplierChangeCount: lifecycle?.multiplierChangeCount ?? 0,
                    reassertionCount: lifecycle?.reassertionCount ?? 0,
                    visibilityRestoreCount: lifecycle?.visibilityRestoreCount ?? 0,
                    lastReassertionReason: lifecycle?.lastReassertionReason
                )
            },
            recentLifecycleEvents: snapshot.lifecycle.recentEvents.map { event in
                CopiedXDRLifecycleEvent(
                    timestamp: event.timestamp,
                    displayName: displayNames[event.displayID] ?? "Disconnected display",
                    instanceID: event.instanceID,
                    kind: event.kind,
                    reassertionReason: event.reassertionReason
                )
            },
            droppedLifecycleEventCount: snapshot.lifecycle.droppedEventCount
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(payload),
            let json = String(data: data, encoding: .utf8)
        else { return false }

        let activeLine =
            payload.overlays.isEmpty
            ? "Active overlays: none"
            : "Active overlays: \(payload.overlays.count) · one identity per display"
        let diagnostic = """
            MachinePulse XDR diagnostic
            Generated: \(snapshot.generatedAt.formatted(.iso8601))
            App: \(payload.appVersion) (\(payload.appBuild))
            macOS: \(payload.macOSVersion)
            Rendering: continuous at \(payload.targetFramesPerSecond) fps
            \(activeLine)
            Privacy: \(payload.privacy)

            All captured data (JSON):
            \(json)
            """
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(diagnostic, forType: .string)
    }

    func shutdown() {
        pollingTask?.cancel()
        pollingTask = nil
        overlays.deactivateAll()
        manager = LocalDisplaySessionManager()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens = []
        publishCurrentScreens()
    }

    private func publish(_ displays: [LocalDisplayDescriptor]) {
        displayStates = displays.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.map {
            LocalDisplayControlState(
                display: $0,
                session: manager.activeSessions[$0.id],
                lastStopReason: manager.lastStopReasons[$0.id]
            )
        }
    }

    private func publishCurrentScreens() {
        let descriptors = displayStates.map(\.display)
        publish(descriptors)
    }

    private func execute(_ commands: [XDRCommand]) {
        for command in commands {
            switch command {
            case let .activate(displayID, multiplier):
                guard let screen = screensByID[displayID] else {
                    _ = manager.disable(displayID: displayID, reason: .displayRemoved)
                    continue
                }
                PulseLog.display.info(
                    "Boost on for \(displayID.rawValue, privacy: .public) at \(multiplier, privacy: .public)")
                if !overlays.activate(displayID: displayID, screen: screen, multiplier: multiplier) {
                    controllerError = "MachinePulse could not create an EDR-capable Metal overlay."
                    _ = manager.disable(displayID: displayID, reason: .currentHeadroomUnavailable)
                } else {
                    controllerError = nil
                }
            case let .update(displayID, multiplier):
                guard let screen = screensByID[displayID] else { continue }
                overlays.update(displayID: displayID, screen: screen, multiplier: multiplier)
            case let .deactivate(displayID, reason):
                PulseLog.display.info(
                    "Boost off for \(displayID.rawValue, privacy: .public): \(reason.rawValue, privacy: .public)")
                overlays.deactivate(displayID: displayID)
            }
        }
    }

    private func maintainActiveOverlays() {
        for session in manager.activeSessions.values {
            guard let screen = screensByID[session.displayID] else { continue }
            overlays.update(
                displayID: session.displayID,
                screen: screen,
                multiplier: session.appliedMultiplier
            )
        }
    }

    private func handleSuspend(reason: XDRStopReason) {
        isAwake = reason != .sleep
        environment = Self.systemEnvironment(isAwake: isAwake)
        execute(manager.suspend(preferences: preferences, reason: reason, now: Date()))
        publishCurrentScreens()
        updatePolling()
    }

    private func handleResume() {
        isAwake = true
        environment = Self.systemEnvironment(isAwake: true)
        let discovery = Self.discoverDisplays()
        screensByID = discovery.screens
        execute(
            manager.resume(
                displays: discovery.displays,
                preferences: preferences,
                environment: environment,
                now: Date()
            )
        )
        publish(discovery.displays)
        updatePolling()
    }

    private func updatePolling() {
        let shouldPoll = started && (preferences.showsControls || !manager.activeSessions.isEmpty)
        if shouldPoll, pollingTask == nil {
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    self?.refresh()
                }
            }
        } else if !shouldPoll {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(reassertionReason: .screenParametersChanged)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(reassertionReason: .applicationResignedActive)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(reassertionReason: .applicationBecameActive)
                }
            }
        )
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
        notificationTokens.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.shutdown() }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            notificationTokens.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleSuspend(reason: .sleep) }
                }
            )
        }
        notificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSuspend(reason: .inactiveSession) }
            }
        )
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            notificationTokens.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleResume() }
                }
            )
        }
        notificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(reassertionReason: .activeSpaceChanged)
                }
            }
        )
    }

    private func persistPreferences() {
        guard !isPreview else { return }
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
    }

    private static func discoverDisplays() -> (
        displays: [LocalDisplayDescriptor],
        screens: [LocalDisplayID: NSScreen]
    ) {
        var displays: [LocalDisplayDescriptor] = []
        var screens: [LocalDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.directDisplayID else { continue }
            let stableID = stableDisplayID(for: displayID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let descriptor = LocalDisplayDescriptor(
                id: stableID,
                name: screen.localizedName,
                isBuiltIn: isBuiltIn,
                potentialEDRMultiplier: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                currentEDRMultiplier: Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            )
            displays.append(descriptor)
            screens[stableID] = screen
        }
        return (displays, screens)
    }

    private static func stableDisplayID(for displayID: CGDirectDisplayID) -> LocalDisplayID {
        LocalDisplayID(
            vendor: CGDisplayVendorNumber(displayID),
            product: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            unit: CGDisplayUnitNumber(displayID)
        )
    }

    private static func systemEnvironment(isAwake: Bool) -> LocalDisplayEnvironment {
        LocalDisplayEnvironment(
            powerSource: currentPowerSource(),
            thermalState: currentThermalState(),
            isAwake: isAwake,
            isSessionActive: currentSessionIsActive()
        )
    }

    private static func currentPowerSource() -> LocalDisplayPowerSource {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch source {
        case "AC Power": return .ac
        case "Battery Power": return .battery
        default: return .unknown
        }
    }

    private static func currentThermalState() -> LocalDisplayThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    private static func currentSessionIsActive() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (dictionary["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
    }
}

private struct CopiedXDRDiagnostic: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let renderMode: String
    let targetFramesPerSecond: Int
    let privacy: String
    let environment: LocalDisplayEnvironment
    let displays: [CopiedXDRDisplay]
    let overlays: [CopiedXDROverlay]
    let recentLifecycleEvents: [CopiedXDRLifecycleEvent]
    let droppedLifecycleEventCount: Int
}

private struct CopiedXDRDisplay: Codable {
    let name: String
    let isBuiltIn: Bool
    let potentialEDRMultiplier: Double
    let currentEDRMultiplier: Double
    let boostActive: Bool
    let requestedMultiplier: Double?
    let appliedMultiplier: Double?
}

private struct CopiedXDROverlay: Codable {
    let displayName: String
    let instanceID: UUID
    let multiplier: Double
    let frame: CopiedXDRFrame
    let isVisible: Bool
    let targetFramesPerSecond: Int
    let presentedFrameCount: Int
    let failedFrameCount: Int
    let activatedAt: Date?
    let geometryChangeCount: Int
    let multiplierChangeCount: Int
    let reassertionCount: Int
    let visibilityRestoreCount: Int
    let lastReassertionReason: XDROverlayReassertionReason?
}

private struct CopiedXDRFrame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ frame: CGRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
    }
}

private struct CopiedXDRLifecycleEvent: Codable {
    let timestamp: Date
    let displayName: String
    let instanceID: UUID
    let kind: XDROverlayLifecycleEventKind
    let reassertionReason: XDROverlayReassertionReason?
}

private extension NSScreen {
    var directDisplayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
