#if DEBUG
    import Foundation
    import MachinePulseCore

    /// Deterministic fixtures for every popover state. They render without
    /// polling, a database, or preferences, and they are what a visual change
    /// is reviewed against.
    extension AppModel {
        enum PreviewScenario: String {
            case empty
            case loading
            case healthy
            case warning
            case critical
            case clearing
            case recovered
            case unreachable
            case collectionUnavailable = "collection-unavailable"
            case collectionFailed = "collection-failed"
            case collectionRecovered = "collection-recovered"
            case oom
            case diskGrowth = "disk-growth"
            case expectedUnit = "expected-unit"
            case servers
        }

        static func previewDisplayController() -> SystemLocalDisplayController {
            guard
                let scenario = ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_DISPLAY_SCENARIO"]
            else { return .preview() }
            let builtIn = LocalDisplayDescriptor(
                id: LocalDisplayID(rawValue: "preview-built-in-xdr"),
                name: "Built-in Retina Display",
                isBuiltIn: true,
                potentialEDRMultiplier: 16,
                currentEDRMultiplier: 2
            )
            let external = LocalDisplayDescriptor(
                id: LocalDisplayID(rawValue: "preview-standard-display"),
                name: "Studio Display",
                isBuiltIn: false,
                potentialEDRMultiplier: 1,
                currentEDRMultiplier: 1
            )
            let preferences = LocalDisplayPreferences(showsControls: true)
            let environment: LocalDisplayEnvironment
            let state: LocalDisplayControlState
            switch scenario {
            case "active":
                let now = Date()
                state = LocalDisplayControlState(
                    display: builtIn,
                    session: XDRSession(
                        displayID: builtIn.id,
                        requestedMultiplier: 1.35,
                        appliedMultiplier: 1.35,
                        startedAt: now.addingTimeInterval(-180),
                        expiresAt: now.addingTimeInterval(27 * 60),
                        activationGraceUntil: now
                    )
                )
                environment = .init(powerSource: .ac)
            case "battery":
                state = LocalDisplayControlState(display: builtIn, lastStopReason: .batteryPolicy)
                environment = .init(powerSource: .battery)
            case "thermal":
                state = LocalDisplayControlState(display: builtIn, lastStopReason: .thermalProtection)
                environment = .init(powerSource: .ac, thermalState: .serious)
            default:
                state = LocalDisplayControlState(display: builtIn)
                environment = .init(powerSource: .ac)
            }
            return .preview(
                states: [state, LocalDisplayControlState(display: external)],
                preferences: preferences,
                environment: environment
            )
        }

        indirect enum PreviewEntry {
            case dir(String, [PreviewEntry])
            case file(String, UInt64, daysOld: Int)

            var name: String {
                switch self {
                case let .dir(name, _), let .file(name, _, _): name
                }
            }
        }

        static func previewDiskScan(deviceID: String, now: Date) -> DiskScan {
            let gib: UInt64 = 1_024 * 1_024 * 1_024
            let mib: UInt64 = 1_024 * 1_024
            let home: [PreviewEntry] = [
                .dir(
                    "src",
                    [
                        .dir(
                            "tries",
                            [
                                .dir("2026-09-01-telemetry", [.dir("target", [.file("deps", 17 * gib, daysOld: 3)])]),
                                .dir("2026-08-20-hyprland", [.file("build", 14 * gib, daysOld: 38)]),
                                .dir("motorsport", [.dir("target", [.file("deps", 14 * gib, daysOld: 9)])]),
                            ]),
                        .dir("github.com", [.dir("example", [.file("site-generator", 15 * gib, daysOld: 12)])]),
                    ]),
                .dir(
                    ".codex",
                    [
                        .dir(
                            "worktrees",
                            [
                                .dir("f4b5", [.file("walgit", 88 * gib, daysOld: 40)]),
                                .dir("a1c2", [.file("x", 6 * gib, daysOld: 5)]),
                            ])
                    ]),
                .dir(
                    "Sync",
                    [
                        .dir(
                            "Telemetry",
                            [.file("26-August", 48 * gib, daysOld: 30), .file("26-September", 19 * gib, daysOld: 4)]),
                        .dir(".stversions", [.file("current", 11 * gib, daysOld: 20)]),
                    ]),
                .dir(
                    "world",
                    [
                        .dir(".git", [.dir("objects", [.file("pack", 51 * gib, daysOld: 1)])]),
                        .file("walgit-import", 41 * gib, daysOld: 2),
                    ]),
                .dir(
                    ".cache",
                    [
                        .dir("kache", [.dir("store", [.file("blobs", 35 * gib, daysOld: 1)])]),
                        .file("other", 34 * gib, daysOld: 6),
                    ]),
                .dir(
                    ".local",
                    [
                        .dir(
                            "share",
                            [
                                .dir("Steam", [.file("steamapps", 96 * gib, daysOld: 15)]),
                                .file("misc", 22 * gib, daysOld: 3),
                            ])
                    ]),
                .dir(
                    "Documents",
                    [.dir("collection", [.file("2026", 61 * gib, daysOld: 10)]), .file("notes", 14 * gib, daysOld: 1)]),
                .dir(
                    ".microsandbox",
                    [
                        .dir("sandboxes", [.file("a", 37 * gib, daysOld: 2)]),
                        .dir("cache", [.dir("layers", [.file("l", 20 * gib, daysOld: 2)])]),
                    ]),
                .dir(
                    "Downloads",
                    [.file("installer.dmg", 9 * gib, daysOld: 60), .file("dataset.zip", 700 * mib, daysOld: 3)]),
                .dir("models", [.file("weights.gguf", 12 * gib, daysOld: 20)]),
            ]
            func flags(_ entries: [PreviewEntry]) -> DiskClassifier.SiblingFlags {
                var flags = DiskClassifier.SiblingFlags()
                for entry in entries { flags.note(entry.name) }
                return flags
            }
            func feed(_ entries: [PreviewEntry], into engine: inout DiskScanEngine) {
                for entry in entries {
                    switch entry {
                    case let .file(name, bytes, daysOld):
                        engine.addEntry(
                            name: name, entryKind: .file, bytes: bytes,
                            modified: Int64(now.timeIntervalSince1970) - Int64(daysOld) * 86_400)
                    case let .dir(name, children):
                        engine.enterDirectory(name: name, flags: flags(children))
                        feed(children, into: &engine)
                        engine.leaveDirectory(ownBytes: 4_096, ownModified: 0)
                    }
                }
            }
            var options = DiskScanOptions()
            options.now = now
            var engine = DiskScanEngine(rootName: "home", rootFlags: flags(home), options: options)
            feed(home, into: &engine)
            let (root, findings) = engine.finish(rootOwnBytes: 4_096, rootModified: 0)
            return DiskScan(
                deviceID: deviceID,
                scannedAt: now.addingTimeInterval(-6 * 60),
                rootPath: "/home/example",
                durationSeconds: 1.2,
                unreadableCount: 0,
                volume: DiskVolume(totalBytes: 952 * gib, freeBytes: 107 * gib, availableBytes: 107 * gib),
                root: root,
                findings: findings,
                scannerVersion: "preview"
            )
        }

        static func previewResourceControls(sampleIndex: Int = 0) -> [WorkloadResourceControlMetric] {
            func value(_ value: UInt64) -> WorkloadResourceValueMetric {
                WorkloadResourceValueMetric(availability: .available, value: value)
            }
            func configured(_ value: UInt64) -> WorkloadResourceLimitMetric {
                WorkloadResourceLimitMetric(state: .configured, value: value)
            }
            func events(
                high: UInt64,
                max: UInt64,
                oom: UInt64,
                killed: UInt64
            ) -> WorkloadMemoryEventsMetric {
                WorkloadMemoryEventsMetric(
                    high: value(high),
                    max: value(max),
                    oom: value(oom),
                    oomKill: value(killed)
                )
            }
            func cpuStat(
                periods: UInt64,
                throttled: UInt64,
                duration: UInt64
            ) -> WorkloadCPUStatMetric {
                WorkloadCPUStatMetric(
                    usageMicroseconds: value(82_000_000 + UInt64(sampleIndex) * 500_000),
                    userMicroseconds: value(61_000_000 + UInt64(sampleIndex) * 400_000),
                    systemMicroseconds: value(21_000_000 + UInt64(sampleIndex) * 100_000),
                    periods: value(periods),
                    throttledPeriods: value(throttled),
                    throttledMicroseconds: value(duration)
                )
            }
            return [
                WorkloadResourceControlMetric(
                    id: "/system.slice/example-dashboard.service",
                    name: "example-dashboard.service",
                    systemdUnit: "example-dashboard.service",
                    cgroupPath: "/system.slice/example-dashboard.service",
                    availability: .available,
                    memoryCurrentBytes: value(412 * 1_024 * 1_024),
                    memoryPeakBytes: value(638 * 1_024 * 1_024),
                    memoryHigh: configured(768 * 1_024 * 1_024),
                    memoryMax: configured(1_024 * 1_024 * 1_024),
                    memoryEvents: events(high: 3, max: 0, oom: 0, killed: 0),
                    cpuQuota: WorkloadCPUQuotaMetric(
                        state: .configured,
                        quotaMicroseconds: 200_000,
                        periodMicroseconds: 100_000
                    ),
                    cpuWeight: value(100),
                    cpuStat: cpuStat(
                        periods: 4_200 + UInt64(sampleIndex) * 10,
                        throttled: 4 + UInt64(sampleIndex) * 3,
                        duration: 1_250_000 + UInt64(sampleIndex) * 300_000
                    ),
                    ioWeight: value(100),
                    ioPressure: WorkloadPressureMetric(
                        availability: .available,
                        someAverage10: 0.6,
                        fullAverage10: 0.1
                    ),
                    tasksCurrent: value(12),
                    tasksMax: configured(512)
                ),
                WorkloadResourceControlMetric(
                    id: "/user.slice/user-1000.slice/app.slice/example-browser.scope",
                    name: "chromium",
                    systemdUnit: "example-browser.scope",
                    cgroupPath: "/user.slice/user-1000.slice/app.slice/example-browser.scope",
                    availability: .available,
                    memoryCurrentBytes: value(1_280 * 1_024 * 1_024),
                    memoryPeakBytes: value(1_860 * 1_024 * 1_024),
                    memoryHigh: configured(2_048 * 1_024 * 1_024),
                    memoryMax: configured(2_048 * 1_024 * 1_024),
                    memoryEvents: events(high: 18, max: 2, oom: 1, killed: 1),
                    cpuQuota: WorkloadCPUQuotaMetric(
                        state: .unlimited,
                        periodMicroseconds: 100_000
                    ),
                    cpuWeight: value(100),
                    cpuStat: cpuStat(
                        periods: 4_200 + UInt64(sampleIndex) * 10,
                        throttled: 0,
                        duration: 0
                    ),
                    ioWeight: value(100),
                    ioPressure: WorkloadPressureMetric(
                        availability: .available,
                        someAverage10: 2.4,
                        fullAverage10: 0.8
                    ),
                    tasksCurrent: value(68),
                    tasksMax: configured(256)
                ),
            ]
        }

        func applyPreviewScenario(_ scenario: PreviewScenario) {
            let now = Date()
            guard scenario != .empty else {
                lastRefresh = now
                return
            }

            if scenario == .servers {
                runningServers = [
                    RunningServer(
                        processID: 4_201,
                        userID: 501,
                        processName: "symfony",
                        command: "symfony server:start --no-tls --port=8000",
                        projectName: "storefront",
                        projectPath: "/Users/example/code_vault/developers",
                        host: "localhost",
                        port: 8_000,
                        startedAt: now.addingTimeInterval(-7_200),
                        kind: .web,
                        scheme: "http"
                    ),
                    RunningServer(
                        processID: 4_202,
                        userID: 501,
                        processName: "symfony",
                        command: "symfony server:start --no-tls --port=8001",
                        projectName: "docs-site",
                        projectPath: "/Users/example/code_vault/website",
                        host: "localhost",
                        port: 8_001,
                        startedAt: now.addingTimeInterval(-3_600),
                        kind: .web,
                        scheme: "http"
                    ),
                ]
            }

            let previewsLocalWorkloads = scenario == .servers
            let device = MachineDevice(
                id: previewsLocalWorkloads ? "preview-this-mac" : "preview-linux",
                name: previewsLocalWorkloads ? "Example MacBook Pro" : "example-server",
                dnsName: previewsLocalWorkloads ? nil : "example-server.example.ts.net",
                addresses: previewsLocalWorkloads ? [] : ["100.64.0.10"],
                platform: previewsLocalWorkloads ? .macOS : .linux,
                isLocal: previewsLocalWorkloads,
                isOnline: scenario != .unreachable,
                connection: previewsLocalWorkloads ? .local : (scenario == .unreachable ? .offline : .direct)
            )
            devices = [device]
            preferences[device.id] = DevicePreference(
                isEnabled: true,
                mode: .deep,
                sshTarget: previewsLocalWorkloads ? nil : "example-server",
                expectedUnits: scenario == .expectedUnit
                    ? ["api.service", "backup.timer"].compactMap(ExpectedSystemdUnit.init(name:))
                    : []
            )
            diskScans[device.id] = Self.previewDiskScan(deviceID: device.id, now: now)
            if ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_DISPLAY_SCENARIO"] != nil,
                !device.isLocal
            {
                let localMac = MachineDevice(
                    id: "preview-this-mac",
                    name: "Example MacBook Pro",
                    platform: .macOS,
                    isLocal: true,
                    isOnline: true,
                    connection: .local
                )
                devices.append(localMac)
                preferences[localMac.id] = DevicePreference(isEnabled: true, mode: .presence, sshTarget: nil)
                reports[localMac.id] = HealthReport(
                    deviceID: localMac.id,
                    state: .healthy,
                    summary: "Everything looks steady",
                    issues: [],
                    evaluatedAt: now
                )
            }
            lastRefresh = now

            if scenario == .loading { return }

            let history = (0..<90).map { index in
                let gapOffset: TimeInterval = index <= 44 ? -35 : 0
                return MetricSample(
                    deviceID: device.id,
                    timestamp: now.addingTimeInterval(TimeInterval((index - 89) * 10) + gapOffset),
                    hostname: "example-server",
                    uptimeSeconds: 2 * 24 * 60 * 60 + 3_600,
                    cpuPercent: Double(28 + (index % 11) * 3),
                    logicalCPUCount: 8,
                    loadAverage1: 1.1,
                    loadAverage5: 1.0,
                    loadAverage15: 0.9,
                    memoryTotalBytes: 16_000_000_000,
                    memoryAvailableBytes: 7_500_000_000,
                    swapTotalBytes: 2_000_000_000,
                    swapUsedBytes: 300_000_000,
                    diskTotalBytes: 250_000_000_000,
                    diskUsedBytes: scenario == .diskGrowth
                        ? 158_000_000_000 + UInt64(index) * 40_000_000
                        : 162_500_000_000,
                    diskReadBytesPerSecond: 37_400_000,
                    diskWriteBytesPerSecond: 35_900_000,
                    networkReceiveBytesPerSecond: 516_000,
                    networkTransmitBytesPerSecond: 40_000,
                    ioPressure: PressureMetric(
                        someAverage10: scenario == .warning || scenario == .critical ? Double(10 + index % 8) : 1,
                        fullAverage10: 0
                    ),
                    topCPUProcesses: [ProcessMetric(name: "php", cpuPercent: 35, residentBytes: 420_000_000)],
                    topMemoryProcesses: [ProcessMetric(name: "database", cpuPercent: 8, residentBytes: 1_200_000_000)],
                    topIOProcesses: [
                        ProcessIOMetric(
                            name: "php",
                            systemdUnit: "example-refresh.service",
                            readBytesPerSecond: 24_000_000,
                            writeBytesPerSecond: 2_000_000
                        )
                    ],
                    expectedUnits: scenario == .expectedUnit
                        ? [
                            ExpectedUnitMetric(
                                name: "api.service", kind: .service, state: .active, substate: "running"),
                            ExpectedUnitMetric(
                                name: "backup.timer", kind: .timer, state: .inactive, substate: "dead"),
                        ]
                        : nil,
                    remoteWorkloads: previewsLocalWorkloads
                        ? nil
                        : [
                            RemoteWorkloadMetric(
                                id: "example-dashboard.service",
                                name: "example-dashboard.service",
                                processName: "gunicorn",
                                systemdUnit: "example-dashboard.service",
                                state: .active,
                                substate: "listening",
                                uptimeSeconds: 28_800,
                                listeners: [
                                    WorkloadListenerMetric(
                                        address: "0.0.0.0",
                                        port: 8_443,
                                        binding: .allInterfaces,
                                        webProtocol: .https
                                    )
                                ]
                            ),
                            RemoteWorkloadMetric(
                                id: "postgresql.service",
                                name: "postgresql.service",
                                processName: "postgres",
                                systemdUnit: "postgresql.service",
                                state: .active,
                                substate: "listening",
                                uptimeSeconds: 172_800,
                                listeners: [
                                    WorkloadListenerMetric(
                                        address: "127.0.0.1",
                                        port: 5_432,
                                        binding: .loopback
                                    )
                                ]
                            ),
                        ],
                    workloadResourceControls: previewsLocalWorkloads
                        ? nil : Self.previewResourceControls(sampleIndex: index),
                    oomKillCount: scenario == .oom ? 1 : 0,
                    lastOOMKillAt: scenario == .oom ? now.addingTimeInterval(-20) : nil,
                    oomCollectionStatus: .available,
                    latestOOMEvent: scenario == .oom
                        ? OOMEventMetric(
                            timestamp: now.addingTimeInterval(-20),
                            victimProcess: "php",
                            processID: 4_242,
                            cgroup: "/system.slice/import-worker.service",
                            constraint: .cgroup,
                            memoryUsageBytes: 500 * 1_024 * 1_024,
                            memoryLimitBytes: 512 * 1_024 * 1_024
                        )
                        : nil,
                    bootID: "preview-boot",
                    collectorVersion: "linux-agentless-v6",
                    rootFilesystemID: "uuid:preview-filesystem"
                )
            }
            samples[device.id] = history.last
            histories[device.id] = history
            capacityRollups[device.id] = CapacityRollupBuilder.build(samples: history)

            switch scenario {
            case .healthy, .servers, .diskGrowth:
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .healthy,
                    summary: "Everything looks steady",
                    issues: [],
                    evaluatedAt: now
                )
            case .warning, .critical:
                let state: HealthState = scenario == .critical ? .critical : .warning
                let measurement = scenario == .critical ? 29.0 : 12.0
                let issue = HealthIssue(
                    id: "io-pressure",
                    kind: .diskPressure,
                    state: state,
                    title: "Storage contention",
                    explanation: String(
                        format:
                            "At least one non-idle task waited on storage during %.1f%% of the latest 10-second window; all non-idle tasks waited together during %.1f%%.",
                        measurement,
                        measurement - 0.4
                    ),
                    measurement: measurement,
                    threshold: state == .critical ? 25 : 8,
                    evidence:
                        "Same-sample I/O leader: example-refresh.service (php), reading 24 MB/s and writing 2 MB/s. This is correlated activity, not proven cause."
                )
                let workloadIssue = HealthIssue(
                    id: "workload:/system.slice/example-dashboard.service:cpu-throttling",
                    kind: .cpu,
                    state: state,
                    title: "example-dashboard.service is CPU throttled",
                    explanation:
                        "The workload was throttled during \(state == .critical ? "60%" : "30%") of CPU periods since the previous sample.",
                    measurement: state == .critical ? 60 : 30,
                    threshold: state == .critical ? 50 : 20,
                    evidence:
                        "CPU quota 200%; \(state == .critical ? "60" : "30") of 100 periods were throttled.",
                    workload: WorkloadHealthContext(
                        id: "/system.slice/example-dashboard.service",
                        name: "example-dashboard.service",
                        systemdUnit: "example-dashboard.service"
                    )
                )
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: state,
                    summary: issue.title,
                    issues: [issue, workloadIssue],
                    evaluatedAt: now
                )
                incidents[device.id] = [
                    HealthIncident(
                        issue: issue,
                        deviceID: device.id,
                        at: now,
                        startedAt: now.addingTimeInterval(-37)
                    )
                ]
            case .clearing:
                let issue = HealthIssue(
                    id: "io-pressure",
                    kind: .diskPressure,
                    state: .critical,
                    title: "Storage contention",
                    explanation:
                        "At least one non-idle task waited on storage during 29.0% of the latest 10-second window; all non-idle tasks waited together during 28.6%.",
                    measurement: 29,
                    threshold: 25,
                    evidence:
                        "Same-sample I/O leader: example-refresh.service (php), reading 24 MB/s and writing 2 MB/s. This is correlated activity, not proven cause."
                )
                var incident = HealthIncident(
                    issue: issue,
                    deviceID: device.id,
                    at: now.addingTimeInterval(-50),
                    startedAt: now.addingTimeInterval(-87)
                )
                incident.markClearing(clearSampleCount: 5, requiredClearSampleCount: 12, at: now)
                let clearingIssue = incident.healthIssue
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: clearingIssue.state,
                    summary: clearingIssue.title,
                    issues: [clearingIssue],
                    evaluatedAt: now
                )
                incidents[device.id] = [incident]
            case .recovered:
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .healthy,
                    summary: "Everything looks steady",
                    issues: [],
                    evaluatedAt: now
                )
                let issue = HealthIssue(
                    id: "io-pressure",
                    kind: .diskPressure,
                    state: .critical,
                    title: "Storage contention",
                    explanation:
                        "At least one non-idle task waited on storage during 29.0% of the latest 10-second window; all non-idle tasks waited together during 28.6%.",
                    measurement: 29,
                    threshold: 25,
                    evidence:
                        "Same-sample I/O leader: example-refresh.service (php), reading 24 MB/s and writing 2 MB/s. This is correlated activity, not proven cause."
                )
                var incident = HealthIncident(
                    issue: issue,
                    deviceID: device.id,
                    at: now.addingTimeInterval(-2),
                    startedAt: now.addingTimeInterval(-39)
                )
                incident.resolve(at: now.addingTimeInterval(-2))
                incidents[device.id] = [incident]
            case .unreachable:
                let issue = HealthIssue(
                    id: "connectivity",
                    kind: .connectivity,
                    state: .unreachable,
                    title: "Machine is unreachable",
                    explanation: "Tailscale reports this device as offline."
                )
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .unreachable,
                    summary: issue.title,
                    issues: [issue],
                    evaluatedAt: now
                )
                incidents[device.id] = [HealthIncident(issue: issue, deviceID: device.id, at: now)]
            case .collectionUnavailable, .collectionFailed:
                let failure: MetricCollectionFailure =
                    scenario == .collectionUnavailable
                    ? .sshUnavailable("Permission denied (publickey).")
                    : .collectorFailed("ValueError: invalid literal for int() with base 10: '0.4 11272'")
                let report = HealthEvaluator.collectionFailure(
                    deviceID: device.id,
                    isReachableThroughTailscale: true,
                    failure: failure,
                    evaluatedAt: now
                )
                reports[device.id] = report
                if let issue = report.issues.first {
                    incidents[device.id] = [
                        HealthIncident(
                            issue: issue,
                            deviceID: device.id,
                            at: now,
                            startedAt: now.addingTimeInterval(-95)
                        )
                    ]
                }
            case .collectionRecovered:
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .healthy,
                    summary: "Everything looks steady",
                    issues: [],
                    evaluatedAt: now
                )
                let issue = HealthIssue(
                    id: MetricCollectionFailure.issueID,
                    kind: .collection,
                    state: .warning,
                    title: "Metrics collection failed",
                    explanation:
                        "The machine is reachable through Tailscale, but returned an invalid metrics payload: ValueError: invalid literal for int() with base 10: '0.4 11272'"
                )
                var incident = HealthIncident(
                    issue: issue,
                    deviceID: device.id,
                    at: now.addingTimeInterval(-30),
                    startedAt: now.addingTimeInterval(-210)
                )
                incident.resolve(at: now.addingTimeInterval(-30))
                incidents[device.id] = [incident]
            case .oom:
                let issue = HealthIssue(
                    id: "oom",
                    kind: .oom,
                    state: .critical,
                    title: "A new out-of-memory kill occurred",
                    explanation:
                        "The kernel killed php (PID 4242) inside a memory-limited workload. This does not by itself mean the whole machine ran out of memory.",
                    evidence:
                        "Memory cgroup: /system.slice/import-worker.service. Memory usage 500 MB of 512 MB limit."
                )
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .critical,
                    summary: issue.title,
                    issues: [issue],
                    evaluatedAt: now
                )
                incidents[device.id] = [HealthIncident(issue: issue, deviceID: device.id, at: now)]
            case .expectedUnit:
                let issue = HealthIssue(
                    id: "expected-unit:backup.timer",
                    kind: .service,
                    state: .warning,
                    title: "Expected timer is inactive",
                    explanation: "backup.timer is configured as expected, but systemd reports it inactive.",
                    evidence: "systemd substate: dead."
                )
                reports[device.id] = HealthReport(
                    deviceID: device.id,
                    state: .warning,
                    summary: issue.title,
                    issues: [issue],
                    evaluatedAt: now
                )
                incidents[device.id] = [
                    HealthIncident(issue: issue, deviceID: device.id, at: now, startedAt: now.addingTimeInterval(-30))
                ]
            case .empty, .loading:
                break
            }
        }
    }
#endif
