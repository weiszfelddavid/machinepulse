import Foundation

public struct LocalDisplayID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(vendor: UInt32, product: UInt32, serial: UInt32, unit: UInt32) {
        let suffix = serial > 0 ? "serial-\(serial)" : "unit-\(unit)"
        rawValue = "vendor-\(vendor)-product-\(product)-\(suffix)"
    }

    public var id: String { rawValue }
}

public struct LocalDisplayDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: LocalDisplayID
    public let name: String
    public let isBuiltIn: Bool
    public let potentialEDRMultiplier: Double
    public let currentEDRMultiplier: Double

    public init(
        id: LocalDisplayID,
        name: String,
        isBuiltIn: Bool,
        potentialEDRMultiplier: Double,
        currentEDRMultiplier: Double
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.potentialEDRMultiplier = max(1, potentialEDRMultiplier.isFinite ? potentialEDRMultiplier : 1)
        self.currentEDRMultiplier = max(1, currentEDRMultiplier.isFinite ? currentEDRMultiplier : 1)
    }

    public var supportsXDR: Bool { potentialEDRMultiplier > 1 }

    public var maximumProductBoost: Double {
        min(2, potentialEDRMultiplier)
    }
}

public enum LocalDisplayPowerSource: String, Codable, Hashable, Sendable {
    case ac
    case battery
    case unknown
}

public enum LocalDisplayThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var blocksBoost: Bool {
        self == .serious || self == .critical
    }
}

public struct LocalDisplayEnvironment: Codable, Hashable, Sendable {
    public var powerSource: LocalDisplayPowerSource
    public var thermalState: LocalDisplayThermalState
    public var isAwake: Bool
    public var isSessionActive: Bool

    public init(
        powerSource: LocalDisplayPowerSource = .unknown,
        thermalState: LocalDisplayThermalState = .nominal,
        isAwake: Bool = true,
        isSessionActive: Bool = true
    ) {
        self.powerSource = powerSource
        self.thermalState = thermalState
        self.isAwake = isAwake
        self.isSessionActive = isSessionActive
    }
}

public struct LocalDisplayPreferences: Codable, Hashable, Sendable {
    public static let schemaVersion = 2

    public var showsControls: Bool
    public var timeoutMinutes: Int
    public var allowsBoostOnBattery: Bool
    public var restoresAfterSleep: Bool
    public private(set) var preferredBoostByDisplay: [LocalDisplayID: Double]

    public init(
        showsControls: Bool = false,
        timeoutMinutes: Int = 30,
        allowsBoostOnBattery: Bool = true,
        restoresAfterSleep: Bool = true,
        preferredBoostByDisplay: [LocalDisplayID: Double] = [:]
    ) {
        self.showsControls = showsControls
        self.timeoutMinutes = min(max(timeoutMinutes, 5), 120)
        self.allowsBoostOnBattery = allowsBoostOnBattery
        self.restoresAfterSleep = restoresAfterSleep
        self.preferredBoostByDisplay = preferredBoostByDisplay.mapValues(Self.validatePreferredBoost)
    }

    public func preferredBoost(for display: LocalDisplayDescriptor) -> Double {
        Self.clampBoost(preferredBoostByDisplay[display.id] ?? 1.35, for: display)
    }

    public mutating func setPreferredBoost(_ multiplier: Double, for display: LocalDisplayDescriptor) {
        preferredBoostByDisplay[display.id] = Self.clampBoost(multiplier, for: display)
    }

    public static func decodePersisted(_ data: Data?) -> LocalDisplayPreferences {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return LocalDisplayPreferences()
        }
        return decoded
    }

    public static func clampBoost(_ multiplier: Double, for display: LocalDisplayDescriptor) -> Double {
        let finite = multiplier.isFinite ? multiplier : 1.35
        return min(max(finite, min(1.01, display.maximumProductBoost)), display.maximumProductBoost)
    }

    private static func validatePreferredBoost(_ multiplier: Double) -> Double {
        min(max(multiplier.isFinite ? multiplier : 1.35, 1.01), 2)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case showsControls
        case timeoutMinutes
        case allowsBoostOnBattery
        case restoresAfterSleep
        case preferredBoostByDisplay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version == 1 || version == Self.schemaVersion else {
            self.init()
            return
        }
        // Version 1 shipped with battery and sleep-restore off; those values
        // were never user-chosen, so migrating adopts the new defaults while
        // keeping every explicit choice.
        let migratesSafetyDefaults = version == 1
        self.init(
            showsControls: try container.decodeIfPresent(Bool.self, forKey: .showsControls) ?? false,
            timeoutMinutes: try container.decodeIfPresent(Int.self, forKey: .timeoutMinutes) ?? 30,
            allowsBoostOnBattery: migratesSafetyDefaults
                ? true
                : try container.decodeIfPresent(Bool.self, forKey: .allowsBoostOnBattery) ?? true,
            restoresAfterSleep: migratesSafetyDefaults
                ? true
                : try container.decodeIfPresent(Bool.self, forKey: .restoresAfterSleep) ?? true,
            preferredBoostByDisplay: Dictionary(
                uniqueKeysWithValues: try container.decodeIfPresent(
                    [String: Double].self,
                    forKey: .preferredBoostByDisplay
                )?.map { (LocalDisplayID(rawValue: $0.key), $0.value) } ?? []
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(showsControls, forKey: .showsControls)
        try container.encode(timeoutMinutes, forKey: .timeoutMinutes)
        try container.encode(allowsBoostOnBattery, forKey: .allowsBoostOnBattery)
        try container.encode(restoresAfterSleep, forKey: .restoresAfterSleep)
        try container.encode(
            Dictionary(uniqueKeysWithValues: preferredBoostByDisplay.map { ($0.key.rawValue, $0.value) }),
            forKey: .preferredBoostByDisplay
        )
    }
}

public enum XDRStopReason: String, Codable, Hashable, Sendable {
    case user
    case featureDisabled
    case unsupportedDisplay
    case displayRemoved
    case batteryPolicy
    case thermalProtection
    case currentHeadroomUnavailable
    case timeout
    case sleep
    case inactiveSession

    public var explanation: String {
        switch self {
        case .user: "XDR Boost is off."
        case .featureDisabled: "Local display controls are disabled."
        case .unsupportedDisplay: "This display does not report XDR capability."
        case .displayRemoved: "The display was disconnected."
        case .batteryPolicy: "XDR Boost is off while this Mac is on battery."
        case .thermalProtection: "XDR Boost was turned off because the Mac is running hot."
        case .currentHeadroomUnavailable: "macOS is not currently providing EDR headroom."
        case .timeout: "XDR Boost reached its time limit and turned off."
        case .sleep: "XDR Boost paused while the display sleeps."
        case .inactiveSession: "XDR Boost is off while the user session is inactive."
        }
    }
}

public struct XDRSession: Codable, Hashable, Sendable {
    public let displayID: LocalDisplayID
    public var requestedMultiplier: Double
    public var appliedMultiplier: Double
    public let startedAt: Date
    public let expiresAt: Date
    public var activationGraceUntil: Date

    public init(
        displayID: LocalDisplayID,
        requestedMultiplier: Double,
        appliedMultiplier: Double,
        startedAt: Date,
        expiresAt: Date,
        activationGraceUntil: Date
    ) {
        self.displayID = displayID
        self.requestedMultiplier = requestedMultiplier
        self.appliedMultiplier = appliedMultiplier
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.activationGraceUntil = activationGraceUntil
    }
}

public enum XDRCommand: Hashable, Sendable {
    case activate(displayID: LocalDisplayID, multiplier: Double)
    case update(displayID: LocalDisplayID, multiplier: Double)
    case deactivate(displayID: LocalDisplayID, reason: XDRStopReason)
}

public struct LocalDisplayControlState: Identifiable, Hashable, Sendable {
    public let display: LocalDisplayDescriptor
    public let session: XDRSession?
    public let lastStopReason: XDRStopReason?

    public init(
        display: LocalDisplayDescriptor,
        session: XDRSession? = nil,
        lastStopReason: XDRStopReason? = nil
    ) {
        self.display = display
        self.session = session
        self.lastStopReason = lastStopReason
    }

    public var id: LocalDisplayID { display.id }
    public var isBoostActive: Bool { session != nil }
}

@MainActor
public protocol LocalDisplayControlling: AnyObject {
    var displayStates: [LocalDisplayControlState] { get }
    var preferences: LocalDisplayPreferences { get }
    var environment: LocalDisplayEnvironment { get }

    func refresh()
    func setBoostLevel(_ multiplier: Double, for displayID: LocalDisplayID)
}

public struct LocalDisplaySessionManager: Sendable {
    public private(set) var activeSessions: [LocalDisplayID: XDRSession] = [:]
    public private(set) var lastStopReasons: [LocalDisplayID: XDRStopReason] = [:]
    private var suspendedSessions: [LocalDisplayID: XDRSession] = [:]

    public init() {}

    public static func unavailableReason(
        for display: LocalDisplayDescriptor,
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment
    ) -> XDRStopReason? {
        if !preferences.showsControls { return .featureDisabled }
        if !display.supportsXDR { return .unsupportedDisplay }
        if !environment.isAwake { return .sleep }
        if !environment.isSessionActive { return .inactiveSession }
        if environment.thermalState.blocksBoost { return .thermalProtection }
        if environment.powerSource == .battery, !preferences.allowsBoostOnBattery { return .batteryPolicy }
        return nil
    }

    /// The slider position at or below which boost is off: the level control
    /// treats its minimum as "Inactive" rather than using a separate toggle.
    public static let inactiveLevelThreshold = 1.001

    /// Drives boost from a single level value: at or below the inactive
    /// threshold the session ends, above it the session activates at that
    /// level or updates in place.
    public mutating func setLevel(
        _ multiplier: Double,
        for display: LocalDisplayDescriptor,
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment,
        now: Date
    ) -> [XDRCommand] {
        guard multiplier > Self.inactiveLevelThreshold else {
            return disable(displayID: display.id)
        }
        guard activeSessions[display.id] == nil else {
            return setMultiplier(multiplier, for: display, now: now)
        }
        return enable(
            display: display,
            preferences: preferences,
            environment: environment,
            now: now,
            requestedMultiplier: multiplier
        )
    }

    public mutating func enable(
        display: LocalDisplayDescriptor,
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment,
        now: Date,
        requestedMultiplier: Double? = nil
    ) -> [XDRCommand] {
        if let reason = Self.unavailableReason(for: display, preferences: preferences, environment: environment) {
            lastStopReasons[display.id] = reason
            return []
        }

        let requested = LocalDisplayPreferences.clampBoost(
            requestedMultiplier ?? preferences.preferredBoost(for: display),
            for: display
        )
        let applied = initialMultiplier(requested: requested, display: display)
        suspendedSessions[display.id] = nil
        activeSessions[display.id] = XDRSession(
            displayID: display.id,
            requestedMultiplier: requested,
            appliedMultiplier: applied,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(preferences.timeoutMinutes * 60)),
            activationGraceUntil: now.addingTimeInterval(3)
        )
        lastStopReasons[display.id] = nil
        return [.activate(displayID: display.id, multiplier: applied)]
    }

    public mutating func disable(displayID: LocalDisplayID, reason: XDRStopReason = .user) -> [XDRCommand] {
        guard activeSessions.removeValue(forKey: displayID) != nil else { return [] }
        suspendedSessions[displayID] = nil
        lastStopReasons[displayID] = reason
        return [.deactivate(displayID: displayID, reason: reason)]
    }

    public mutating func setMultiplier(
        _ multiplier: Double,
        for display: LocalDisplayDescriptor,
        now: Date
    ) -> [XDRCommand] {
        guard var session = activeSessions[display.id] else { return [] }
        session.requestedMultiplier = LocalDisplayPreferences.clampBoost(multiplier, for: display)
        let applied = effectiveMultiplier(for: session, display: display, now: now)
        guard abs(applied - session.appliedMultiplier) > 0.001 else {
            activeSessions[display.id] = session
            return []
        }
        session.appliedMultiplier = applied
        activeSessions[display.id] = session
        return [.update(displayID: display.id, multiplier: applied)]
    }

    public mutating func reconcile(
        displays: [LocalDisplayDescriptor],
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment,
        now: Date
    ) -> [XDRCommand] {
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        var commands: [XDRCommand] = []

        for displayID in activeSessions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var session = activeSessions[displayID] else { continue }
            guard let display = byID[displayID] else {
                // A closed lid in clamshell mode removes the built-in display
                // without sleeping the Mac; with restoration enabled the
                // session survives as a suspension until the display returns
                // or the original deadline passes.
                if preferences.restoresAfterSleep, session.expiresAt > now {
                    activeSessions[displayID] = nil
                    suspendedSessions[displayID] = session
                    lastStopReasons[displayID] = .displayRemoved
                    commands.append(.deactivate(displayID: displayID, reason: .displayRemoved))
                } else {
                    commands += disable(displayID: displayID, reason: .displayRemoved)
                }
                continue
            }
            if let reason = Self.unavailableReason(for: display, preferences: preferences, environment: environment) {
                commands += disable(displayID: displayID, reason: reason)
                continue
            }
            if now >= session.expiresAt {
                commands += disable(displayID: displayID, reason: .timeout)
                continue
            }
            if display.currentEDRMultiplier <= 1, now >= session.activationGraceUntil {
                commands += disable(displayID: displayID, reason: .currentHeadroomUnavailable)
                continue
            }
            let applied = effectiveMultiplier(for: session, display: display, now: now)
            if abs(applied - session.appliedMultiplier) > 0.001 {
                session.appliedMultiplier = applied
                activeSessions[displayID] = session
                commands.append(.update(displayID: displayID, multiplier: applied))
            }
        }

        for displayID in suspendedSessions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let prior = suspendedSessions[displayID] else { continue }
            guard prior.expiresAt > now else {
                suspendedSessions[displayID] = nil
                lastStopReasons[displayID] = .timeout
                continue
            }
            guard let display = byID[displayID], activeSessions[displayID] == nil else { continue }
            suspendedSessions[displayID] = nil
            if let reason = Self.unavailableReason(for: display, preferences: preferences, environment: environment) {
                lastStopReasons[displayID] = reason
                continue
            }
            let requested = LocalDisplayPreferences.clampBoost(prior.requestedMultiplier, for: display)
            let applied = initialMultiplier(requested: requested, display: display)
            activeSessions[displayID] = XDRSession(
                displayID: displayID,
                requestedMultiplier: requested,
                appliedMultiplier: applied,
                startedAt: prior.startedAt,
                expiresAt: prior.expiresAt,
                activationGraceUntil: now.addingTimeInterval(3)
            )
            lastStopReasons[displayID] = nil
            commands.append(.activate(displayID: displayID, multiplier: applied))
        }
        return commands
    }

    public mutating func suspend(
        preferences: LocalDisplayPreferences,
        reason: XDRStopReason,
        now: Date
    ) -> [XDRCommand] {
        let sessions = activeSessions.values.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
        guard !sessions.isEmpty else { return [] }
        suspendedSessions =
            preferences.restoresAfterSleep
            ? Dictionary(uniqueKeysWithValues: sessions.filter { $0.expiresAt > now }.map { ($0.displayID, $0) })
            : [:]
        activeSessions = [:]
        for session in sessions { lastStopReasons[session.displayID] = reason }
        return sessions.map { .deactivate(displayID: $0.displayID, reason: reason) }
    }

    public mutating func resume(
        displays: [LocalDisplayDescriptor],
        preferences: LocalDisplayPreferences,
        environment: LocalDisplayEnvironment,
        now: Date
    ) -> [XDRCommand] {
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let candidates = suspendedSessions.values.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
        suspendedSessions = [:]
        var commands: [XDRCommand] = []
        guard preferences.restoresAfterSleep else { return commands }

        for prior in candidates where prior.expiresAt > now {
            guard let display = byID[prior.displayID] else {
                lastStopReasons[prior.displayID] = .displayRemoved
                continue
            }
            if let reason = Self.unavailableReason(for: display, preferences: preferences, environment: environment) {
                lastStopReasons[display.id] = reason
                continue
            }
            let requested = LocalDisplayPreferences.clampBoost(prior.requestedMultiplier, for: display)
            let applied = initialMultiplier(requested: requested, display: display)
            activeSessions[display.id] = XDRSession(
                displayID: display.id,
                requestedMultiplier: requested,
                appliedMultiplier: applied,
                startedAt: prior.startedAt,
                expiresAt: prior.expiresAt,
                activationGraceUntil: now.addingTimeInterval(3)
            )
            lastStopReasons[display.id] = nil
            commands.append(.activate(displayID: display.id, multiplier: applied))
        }
        return commands
    }

    private func initialMultiplier(requested: Double, display: LocalDisplayDescriptor) -> Double {
        guard display.currentEDRMultiplier <= 1 else {
            return min(requested, display.currentEDRMultiplier, display.maximumProductBoost)
        }
        return min(1.01, display.maximumProductBoost)
    }

    private func effectiveMultiplier(for session: XDRSession, display: LocalDisplayDescriptor, now: Date) -> Double {
        if display.currentEDRMultiplier <= 1, now < session.activationGraceUntil {
            return min(1.01, display.maximumProductBoost)
        }
        return min(session.requestedMultiplier, display.currentEDRMultiplier, display.maximumProductBoost)
    }
}
