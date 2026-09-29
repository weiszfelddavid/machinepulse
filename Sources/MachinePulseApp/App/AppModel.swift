import AppKit
import Foundation
import MachinePulseCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    var devices: [MachineDevice] = []
    var samples: [String: MetricSample] = [:]
    var histories: [String: [MetricSample]] = [:]
    var capacityRollups: [String: [CapacityHourlyRollup]] = [:]
    var incidents: [String: [HealthIncident]] = [:]
    var reports: [String: HealthReport] = [:]
    var trafficRates: [String: TransferRate] = [:]
    var runningServers: [RunningServer] = []
    var runningServerError: String?
    var diskScans: [String: DiskScan] = [:]
    var diskScanActivity: [String: DiskScanActivity] = [:]
    var preferences: [String: DevicePreference]
    var thresholdSettings: HealthThresholdSettings
    var notificationsEnabled: Bool
    var localDisplayControls: SystemLocalDisplayController
    var isRefreshing = false
    var lastRefresh: Date?
    var discoveryError: String?
    var storageError: String?
    var launchesAtLogin = false
    var loginItemError: String?

    @ObservationIgnored private let discovery = TailscaleDiscovery()
    @ObservationIgnored private let localServerDiscovery = LocalServerDiscovery()
    @ObservationIgnored private let notifications = NotificationCoordinator()
    @ObservationIgnored private let store: MetricsStore?
    @ObservationIgnored private let collectorScript: Data?
    @ObservationIgnored private var sources: [String: any MetricSource] = [:]
    @ObservationIgnored private var sourceKeys: [String: String] = [:]
    @ObservationIgnored private var scheduler = MonitoringScheduler()
    @ObservationIgnored private var discoveryCounters: [String: DiscoveryCounter] = [:]
    @ObservationIgnored private var loadedSampleHistory: Set<String> = []
    @ObservationIgnored private var loadedCapacityHistory: Set<String> = []
    @ObservationIgnored private var loadedIncidentHistory: Set<String> = []
    @ObservationIgnored private var incidentStabilizers: [String: IncidentStabilizer] = [:]
    @ObservationIgnored private var persistedStates: [String: HealthState]
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var maintenanceLoop: Task<Void, Never>?
    #if DEBUG
        @ObservationIgnored private(set) var previewScenarioName: String?
    #endif

    private static let preferencesKey = "devicePreferences.v1"
    private static let thresholdSettingsKey = "healthThresholdSettings.v2"
    private static let notificationsKey = "notificationsEnabled"
    private static let statesKey = "lastHealthStates.v1"
    private static let sampleHistoryWindow = DiskGrowthAnalyzer.defaultWindow
    private static let pruneInterval: TimeInterval = 60 * 60
    /// Without a tailnet the app still monitors the Mac it runs on. The
    /// identity changes to the Tailscale node ID once Tailscale is installed.
    private static let thisMacWithoutTailnet = MachineDevice(
        id: "this-mac",
        name: Host.current().localizedName ?? "This Mac",
        platform: .macOS,
        isLocal: true,
        isOnline: true,
        connection: .local
    )

    init() {
        #if DEBUG
            if let scenarioName = ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_SCENARIO"],
                let scenario = PreviewScenario(rawValue: scenarioName)
            {
                preferences = [:]
                thresholdSettings = HealthThresholdSettings(preset: .balanced)
                notificationsEnabled = false
                localDisplayControls = Self.previewDisplayController()
                persistedStates = [:]
                store = nil
                collectorScript = nil
                previewScenarioName = scenarioName
                applyPreviewScenario(scenario)
                return
            }
        #endif
        let defaults = UserDefaults.standard
        preferences =
            Self.decode([String: DevicePreference].self, from: defaults.data(forKey: Self.preferencesKey)) ?? [:]
        thresholdSettings =
            Self.decode(HealthThresholdSettings.self, from: defaults.data(forKey: Self.thresholdSettingsKey))
            ?? HealthThresholdSettings(preset: .balanced)
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        localDisplayControls = SystemLocalDisplayController()
        persistedStates = Self.decode([String: HealthState].self, from: defaults.data(forKey: Self.statesKey)) ?? [:]

        do {
            store = try MetricsStore()
        } catch {
            store = nil
            storageError = error.localizedDescription
            PulseLog.storage.fault("Could not open the metrics store: \(error.localizedDescription, privacy: .public)")
        }

        collectorScript =
            (Bundle.main.url(forResource: "collector", withExtension: "sh")
            ?? Bundle.module.url(forResource: "collector", withExtension: "sh"))
            .flatMap { try? Data(contentsOf: $0) }
    }

    var enabledDevices: [MachineDevice] {
        devices.filter { preferences[$0.id]?.isEnabled == true }
    }

    var thresholds: HealthThresholds {
        thresholdSettings.thresholds
    }

    var thresholdPreset: HealthSensitivityPreset {
        thresholdSettings.preset
    }

    var aggregateState: HealthState {
        HealthEvaluator.aggregate(enabledDevices.compactMap { reports[$0.id] })
    }

    var aggregateSummary: String {
        let enabled = enabledDevices
        guard !enabled.isEmpty else { return "Choose machines to monitor" }
        if aggregateState == .unreachable {
            return "A machine is unreachable"
        }
        if let first = activeIssues.first {
            return "Needs attention: \(first.1.title)"
        }
        if enabled.contains(where: { reports[$0.id] == nil }) { return "Collecting first samples…" }
        return "Healthy now"
    }

    var activeIssues: [(MachineDevice, HealthIssue)] {
        enabledDevices.flatMap { device in
            (reports[device.id]?.issues ?? []).map { (device, $0) }
        }.sorted {
            if $0.1.state != $1.1.state { return $0.1.state > $1.1.state }
            return $0.1.title < $1.1.title
        }
    }

    func activeIncidents(for deviceID: String) -> [HealthIncident] {
        (incidents[deviceID] ?? []).filter(\.isActive).sorted {
            if $0.currentState != $1.currentState { return $0.currentState > $1.currentState }
            return $0.startedAt < $1.startedAt
        }
    }

    func currentOrRecentIncident(for deviceID: String) -> HealthIncident? {
        FeaturedIncidentPolicy.select(from: incidents[deviceID] ?? [])
    }

    func start() {
        #if DEBUG
            guard previewScenarioName == nil else { return }
        #endif
        guard refreshLoop == nil else { return }
        localDisplayControls.start()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        if notificationsEnabled {
            Task { await notifications.requestPermission() }
        }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await refreshNow()
            }
        }
        if let store {
            maintenanceLoop = Task { [weak self] in
                guard let self else { return }
                do {
                    try await store.backfillCapacityRollupsIfNeeded()
                    for scan in try await store.latestDiskScans() where diskScans[scan.deviceID] == nil {
                        diskScans[scan.deviceID] = scan
                    }
                } catch {
                    storageError = error.localizedDescription
                }
                while !Task.isCancelled {
                    do { try await store.prune() } catch { storageError = error.localizedDescription }
                    try? await Task.sleep(for: .seconds(Self.pruneInterval))
                }
            }
        }
    }

    func refreshNow() async {
        #if DEBUG
            guard previewScenarioName == nil else { return }
        #endif
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        await refreshRunningServers()

        do {
            let discovered = try await discovery.discover()
            discoveryError = nil
            await mergeDiscovery(discovered)
        } catch TailscaleDiscoveryError.unavailable {
            discoveryError = TailscaleDiscoveryError.unavailable.localizedDescription
            if devices.isEmpty { await mergeDiscovery([Self.thisMacWithoutTailnet]) }
        } catch {
            discoveryError = error.localizedDescription
            PulseLog.discovery.error("Tailscale discovery failed: \(error.localizedDescription, privacy: .public)")
        }

        let enabled = enabledDevices
        for device in enabled where preferences[device.id]?.mode != .deep {
            await accept(HealthEvaluator.presenceReport(for: device), for: device.id)
        }
        await reconcileSources(for: enabled)

        let now = Date()
        let dueSources = sources.filter { id, _ in scheduler.isDue(deviceID: id, now: now) }

        for device in enabled where preferences[device.id]?.mode == .deep {
            guard
                scheduler.needsOfflineReport(
                    deviceID: device.id,
                    isOnline: device.isOnline,
                    hasSource: sources[device.id] != nil,
                    now: now
                )
            else { continue }
            let report = collectionFailureReport(
                deviceID: device.id,
                failure: .sshUnavailable("The collection attempt is deferred by retry backoff.")
            )
            await accept(report, for: device.id)
        }
        let results = await withTaskGroup(of: CollectionResult.self, returning: [CollectionResult].self) { group in
            for (id, source) in dueSources {
                let isLocalSource = source is LocalMacMetricSource
                group.addTask {
                    do { return .success(id, try await source.collect()) } catch {
                        return .failure(id, MetricCollectionFailure(error: error, isLocalSource: isLocalSource))
                    }
                }
            }
            var values: [CollectionResult] = []
            for await value in group { values.append(value) }
            return values
        }

        for result in results {
            switch result {
            case let .success(id, sample):
                scheduler.reset(deviceID: id)
                await accept(sample, for: id)
            case let .failure(id, failure):
                let nextAttempt = scheduler.recordFailure(deviceID: id, now: Date())
                PulseLog.collection.error(
                    """
                    Collection failed for \(id, privacy: .public): \
                    \(failure.title, privacy: .public) — \(failure.explanation, privacy: .public); \
                    retrying \(nextAttempt.formatted(date: .omitted, time: .standard), privacy: .public)
                    """)
                await accept(collectionFailureReport(deviceID: id, failure: failure), for: id)
            }
        }
    }

    private func collectionFailureReport(deviceID: String, failure: MetricCollectionFailure) -> HealthReport {
        let device = devices.first { $0.id == deviceID }
        return HealthEvaluator.collectionFailure(
            deviceID: deviceID,
            isReachableThroughTailscale: device?.isOnline ?? false,
            failure: failure,
            offlineMessage: device?.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
        )
    }

    func setEnabled(_ enabled: Bool, for device: MachineDevice) {
        var preference = preferences[device.id] ?? defaultPreference(for: device)
        preference.isEnabled = enabled
        preferences[device.id] = preference
        persistPreferences()
        if !enabled {
            reports[device.id] = nil
            sources[device.id] = nil
            sourceKeys[device.id] = nil
        }
        Task { await refreshNow() }
    }

    func setMode(_ mode: MonitoringMode, for device: MachineDevice) {
        var preference = preferences[device.id] ?? defaultPreference(for: device)
        preference.mode = mode
        preferences[device.id] = preference
        sources[device.id] = nil
        sourceKeys[device.id] = nil
        persistPreferences()
        Task { await refreshNow() }
    }

    func setSSHTarget(_ target: String, for device: MachineDevice) {
        var preference = preferences[device.id] ?? defaultPreference(for: device)
        preference.sshTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences[device.id] = preference
        sources[device.id] = nil
        sourceKeys[device.id] = nil
        persistPreferences()
    }

    func setExpectedUnits(_ units: [ExpectedSystemdUnit], for device: MachineDevice) {
        var preference = preferences[device.id] ?? defaultPreference(for: device)
        preference.expectedUnits = Array(
            units.prefix(ExpectedSystemdUnit.maxWatchlistCount)
        )
        preferences[device.id] = preference
        sources[device.id] = nil
        sourceKeys[device.id] = nil
        persistPreferences()
        Task { await refreshNow() }
    }

    func updateThreshold(_ keyPath: WritableKeyPath<HealthThresholds, Double>, value: Double) {
        thresholdSettings.update(keyPath, value: value)
        persistThresholds()
    }

    func setThresholdPreset(_ preset: HealthSensitivityPreset) {
        thresholdSettings.select(preset)
        persistThresholds()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notificationsKey)
        if enabled { Task { await notifications.requestPermission() } }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            PulseLog.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func prepareToQuit() {
        localDisplayControls.shutdown()
    }

    func supportsDeepMonitoring(_ device: MachineDevice) -> Bool {
        device.platform.supportsFullMetrics
    }

    func openSSH(for device: MachineDevice) {
        guard
            let target = preferences[device.id]?.sshTarget,
            let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
            let url = URL(string: "ssh://\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static let repositoryURL = URL(string: "https://github.com/weiszfelddavid/machinepulse")!
    static let issueFormURL = URL(string: "https://github.com/weiszfelddavid/machinepulse/issues/new/choose")!
    static let creatorProfileURL = URL(string: "https://x.com/weiszfeld")!

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func open(_ server: RunningServer) {
        guard let url = server.browserURL else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func copyAddress(for server: RunningServer) -> Bool {
        let address = server.browserURL?.absoluteString ?? server.address
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(address, forType: .string)
    }

    func stop(_ server: RunningServer) async {
        do {
            try await localServerDiscovery.stop(server)
            runningServerError = nil
            runningServers = try await localServerDiscovery.discover()
        } catch {
            runningServerError = error.localizedDescription
            PulseLog.servers.error(
                "Could not stop local server \(server.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func copyDiagnostic(for device: MachineDevice) {
        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: reports[device.id],
            sample: samples[device.id],
            diskTrend: DiskGrowthAnalyzer.analyze(samples: histories[device.id] ?? []),
            thresholds: thresholds,
            activeIncidents: activeIncidents(for: device.id),
            recentRecoveredIncidents: (incidents[device.id] ?? []).filter { !$0.isActive }
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostic, forType: .string)
    }

    func supportsWorkloads(_ device: MachineDevice) -> Bool {
        device.isLocal || (device.platform == .linux && preferences[device.id]?.mode == .deep)
    }

    func supportsStorage(_ device: MachineDevice) -> Bool {
        if device.isLocal { return true }
        guard device.collectsOverSSH, let preference = preferences[device.id] else { return false }
        return preference.mode == .deep && preference.sshTarget?.isEmpty == false
    }

    /// Scans run only when asked: a walk of a home directory costs seconds
    /// of I/O, not something to repeat every ten seconds.
    func scanDisk(for device: MachineDevice) {
        let deviceID = device.id
        guard supportsStorage(device), diskScanActivity[deviceID]?.isScanning != true else { return }
        diskScanActivity[deviceID] = .scanning(startedAt: Date())
        if device.isLocal {
            Task.detached(priority: .utility) { [weak self] in
                let result = Result { try LocalDiskScanner.scan(deviceID: deviceID) }
                await self?.acceptDiskScan(result, for: deviceID)
            }
            return
        }
        guard let target = preferences[deviceID]?.sshTarget, let collectorScript else {
            diskScanActivity[deviceID] = .failed("Choose an SSH target in Settings to scan this machine.")
            return
        }
        let scanner = SSHDiskScanner(target: target, collectorScript: collectorScript)
        Task { [weak self] in
            let result: Result<DiskScan, any Error>
            do { result = .success(try await scanner.scan(deviceID: deviceID)) } catch { result = .failure(error) }
            await self?.acceptDiskScan(result, for: deviceID)
        }
    }

    private func acceptDiskScan(_ result: Result<DiskScan, any Error>, for deviceID: String) async {
        switch result {
        case let .success(scan):
            diskScans[deviceID] = scan
            diskScanActivity[deviceID] = nil
            if let store {
                do { try await store.save(scan) } catch { storageError = error.localizedDescription }
            }
        case let .failure(error):
            let message = FailureSanitizer.sanitize(error.localizedDescription)
            diskScanActivity[deviceID] = .failed(message)
            PulseLog.collection.error(
                "Disk scan failed for \(deviceID, privacy: .public): \(message, privacy: .public)")
        }
    }

    func copyCleanupPrompt(for device: MachineDevice) {
        guard let scan = diskScans[device.id] else { return }
        let prompt = DiskCleanupComposer.prompt(
            scan: scan,
            machineName: device.name,
            platformName: device.platform.displayName
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    func copyCapacitySummary(for device: MachineDevice) {
        let summary = CapacitySummaryComposer.compose(
            device: device,
            rollups: capacityRollups[device.id] ?? []
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private func refreshRunningServers() async {
        do {
            runningServers = try await localServerDiscovery.discover()
            runningServerError = nil
        } catch {
            runningServerError = error.localizedDescription
            PulseLog.servers.error(
                "Local server discovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func mergeDiscovery(_ discovered: [MachineDevice]) async {
        let needsSSHResolution = discovered.contains { device in
            device.collectsOverSSH && preferences[device.id]?.sshTarget?.isEmpty != false
        }
        let sshCandidates = needsSSHResolution ? await SSHConfigResolver.candidates() : []
        let now = Date()
        var merged: [MachineDevice] = []
        for device in discovered {
            var preference = preferences[device.id] ?? defaultPreference(for: device)
            if preference.sshTarget?.isEmpty != false, device.collectsOverSSH,
                let candidate = SSHConfigResolver.candidate(for: device, in: sshCandidates)
            {
                preference.sshTarget = candidate.alias
                preferences[device.id] = preference
            }
            merged.append(device)

            if let previous = discoveryCounters[device.id] {
                let interval = now.timeIntervalSince(previous.timestamp)
                if interval > 0 {
                    trafficRates[device.id] = TransferRate(
                        receivedBytesPerSecond: counterRate(device.receivedBytes, previous.receivedBytes, interval),
                        transmittedBytesPerSecond: counterRate(
                            device.transmittedBytes, previous.transmittedBytes, interval)
                    )
                }
            }
            discoveryCounters[device.id] = DiscoveryCounter(
                timestamp: now,
                receivedBytes: device.receivedBytes,
                transmittedBytes: device.transmittedBytes
            )
        }
        devices = merged
        persistPreferences()
    }

    private func defaultPreference(for device: MachineDevice) -> DevicePreference {
        let mode: MonitoringMode = supportsDeepMonitoring(device) ? .deep : .presence
        return DevicePreference(isEnabled: false, mode: mode, sshTarget: nil)
    }

    private func reconcileSources(for enabled: [MachineDevice]) async {
        let enabledIDs = Set(enabled.map(\.id))
        for id in sources.keys where !enabledIDs.contains(id) {
            sources[id] = nil
            sourceKeys[id] = nil
            scheduler.reset(deviceID: id)
        }

        for device in enabled where preferences[device.id]?.mode == .deep {
            let desired = MonitoringScheduler.desiredSource(
                platform: device.platform,
                isLocal: device.isLocal,
                mode: .deep,
                sshTarget: preferences[device.id]?.sshTarget,
                hasCollectorScript: collectorScript != nil
            )
            switch desired {
            case .localMac:
                if sourceKeys[device.id] != "local" {
                    sources[device.id] = LocalMacMetricSource(deviceID: device.id)
                    sourceKeys[device.id] = "local"
                }
            case let .ssh(target):
                let expectedUnits = preferences[device.id]?.expectedUnits ?? []
                let watchlistKey = expectedUnits.map(\.name).joined(separator: ",")
                let sourceKey = "ssh:\(target):expected:\(watchlistKey)"
                if sourceKeys[device.id] != sourceKey, let collectorScript {
                    sources[device.id] = SSHMetricSource(
                        deviceID: device.id,
                        target: target,
                        collectorScript: collectorScript,
                        expectedUnits: expectedUnits
                    )
                    sourceKeys[device.id] = sourceKey
                }
            case .presenceOnly:
                break
            case let .unavailable(failure):
                sources[device.id] = nil
                sourceKeys[device.id] = nil
                scheduler.reset(deviceID: device.id)
                await accept(collectionFailureReport(deviceID: device.id, failure: failure), for: device.id)
            }
        }
    }

    /// The samples a rollup of one hour needs: the hour's own, and the last
    /// one before it so the first interval has a start.
    private static func hourWindow(of history: [MetricSample], hour: Date) -> [MetricSample] {
        let end = hour.addingTimeInterval(3_600)
        let previous = history.last { $0.timestamp < hour }
        return (previous.map { [$0] } ?? []) + history.filter { $0.timestamp >= hour && $0.timestamp < end }
    }

    private func accept(_ sample: MetricSample, for id: String) async {
        var previous = samples[id]
        samples[id] = sample
        var history = histories[id] ?? []
        if !loadedSampleHistory.contains(id), let store {
            do {
                history = try await store.recentSamples(
                    deviceID: id,
                    since: Date().addingTimeInterval(-Self.sampleHistoryWindow)
                )
            } catch {
                storageError = error.localizedDescription
            }
        }
        loadedSampleHistory.insert(id)
        if previous == nil { previous = history.last }
        history.append(sample)
        let cutoff = Date().addingTimeInterval(-Self.sampleHistoryWindow)
        history.removeAll { $0.timestamp < cutoff }
        histories[id] = history

        let report = HealthEvaluator.evaluate(
            sample: sample,
            previousSample: previous,
            thresholds: thresholds
        )
        await accept(report, for: id)
        if let store {
            do {
                try await store.save(sample)
                let hour = CapacityRollupBuilder.hour(containing: sample.timestamp)
                let updatedHour = CapacityRollupBuilder.build(samples: Self.hourWindow(of: history, hour: hour))
                    .filter { $0.hourStart == hour }
                try await store.replaceCapacityRollups(deviceID: id, hourStart: hour, with: updatedHour)
                var rollups = capacityRollups[id] ?? []
                if !loadedCapacityHistory.contains(id) {
                    rollups = try await store.recentCapacityRollups(
                        deviceID: id,
                        since: Date().addingTimeInterval(-MetricsStore.capacityRollupRetention)
                    )
                    loadedCapacityHistory.insert(id)
                } else {
                    let hour = CapacityRollupBuilder.hour(containing: sample.timestamp)
                    rollups.removeAll { $0.hourStart == hour }
                    rollups.append(contentsOf: updatedHour)
                    let cutoff = Date().addingTimeInterval(-MetricsStore.capacityRollupRetention)
                    rollups.removeAll { $0.observedThrough < cutoff }
                    rollups.sort {
                        if $0.hourStart != $1.hourStart { return $0.hourStart < $1.hourStart }
                        return $0.segmentIndex < $1.segmentIndex
                    }
                }
                capacityRollups[id] = rollups
            } catch {
                storageError = error.localizedDescription
            }
        }
    }

    private func accept(_ report: HealthReport, for id: String) async {
        if !loadedIncidentHistory.contains(id), let store {
            do {
                let stored = try await store.recentIncidents(
                    deviceID: id,
                    since: Date().addingTimeInterval(-MetricsStore.incidentRetention)
                )
                incidents[id] = stored
                incidentStabilizers[id] = IncidentStabilizer(activeIncidents: stored)
            } catch {
                storageError = error.localizedDescription
            }
        }
        loadedIncidentHistory.insert(id)

        var stabilizer = incidentStabilizers[id] ?? IncidentStabilizer()
        let processing = stabilizer.process(report)
        incidentStabilizers[id] = stabilizer
        for incident in processing.changedIncidents {
            if let store {
                do { try await store.save(incident) } catch { storageError = error.localizedDescription }
            }
            var history = incidents[id] ?? []
            history.removeAll { $0.id == incident.id }
            history.append(incident)
            let cutoff = Date().addingTimeInterval(-MetricsStore.incidentRetention)
            history.removeAll { $0.updatedAt < cutoff }
            incidents[id] = history.sorted { $0.updatedAt > $1.updatedAt }
        }

        let previous = reports[id]
        let previousState = previous?.state ?? persistedStates[id]
        let stabilizedReport = processing.report
        reports[id] = stabilizedReport
        persistedStates[id] = stabilizedReport.state
        UserDefaults.standard.set(try? JSONEncoder().encode(persistedStates), forKey: Self.statesKey)
        guard let previousState, previousState != stabilizedReport.state else { return }

        let deviceName = devices.first(where: { $0.id == id })?.name ?? "Machine"
        if notificationsEnabled {
            await notifications.postTransition(deviceName: deviceName, old: previousState, report: stabilizedReport)
        }
    }

    private func persistPreferences() {
        UserDefaults.standard.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
    }

    private func persistThresholds() {
        UserDefaults.standard.set(
            try? JSONEncoder().encode(thresholdSettings),
            forKey: Self.thresholdSettingsKey
        )
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func counterRate(_ new: UInt64, _ old: UInt64, _ interval: TimeInterval) -> Double {
        new >= old ? Double(new - old) / interval : 0
    }
}

extension AppModel {
    enum DiskScanActivity: Equatable {
        case scanning(startedAt: Date)
        case failed(String)

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }
    }
}

private enum CollectionResult: Sendable {
    case success(String, MetricSample)
    case failure(String, MetricCollectionFailure)
}

struct TransferRate: Equatable {
    let receivedBytesPerSecond: Double
    let transmittedBytesPerSecond: Double
}

struct DiscoveryCounter {
    let timestamp: Date
    let receivedBytes: UInt64
    let transmittedBytes: UInt64
}
