import Foundation
import SQLite3
import Testing
@testable import MachinePulseCore

struct CapacityHistoryTests {
    @Test func percentileRollupsAreDeterministicAndUseNearestRank() {
        let hour = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = (1...100).map { index in
            sample(
                at: hour.addingTimeInterval(Double(index)),
                cpu: Double(index),
                memoryUsedPercent: Double(index)
            )
        }

        let ordered = CapacityRollupBuilder.build(samples: samples)
        let reversed = CapacityRollupBuilder.build(samples: samples.reversed())

        #expect(ordered == reversed)
        #expect(ordered.count == 1)
        #expect(ordered.first?.host.cpuPercent?.p50 == 50)
        #expect(ordered.first?.host.cpuPercent?.p95 == 95)
        #expect(ordered.first?.host.cpuPercent?.p99 == 99)
        #expect(ordered.first?.sampleCount == 100)
    }

    @Test func incompatibleIdentityAndMaterialGapStartANewSegment() throws {
        let hour = CapacityRollupBuilder.hour(containing: Date(timeIntervalSince1970: 1_800_000_000))
        let original = sample(
            at: hour.addingTimeInterval(10),
            hostname: "host-a",
            bootID: "boot-a",
            collectorVersion: "collector-a",
            filesystemID: "filesystem-a",
            diskTotalBytes: 100_000_000_000
        )
        let changed = sample(
            at: hour.addingTimeInterval(160),
            hostname: "host-b",
            uptime: 5,
            bootID: "boot-b",
            collectorVersion: "collector-b",
            filesystemID: "filesystem-b",
            diskTotalBytes: 120_000_000_000
        )

        let rollups = CapacityRollupBuilder.build(samples: [original, changed])
        let historyBreak = try #require(rollups.last?.breakBefore)

        #expect(rollups.count == 2)
        #expect(Set(historyBreak.reasons) == Set(CapacityHistoryBreakReason.allCases))
        #expect(historyBreak.gapSeconds == 150)
        #expect(rollups.last?.expectedSampleCount == 15)
    }

    @Test func hostAndWorkloadConsequencesAreSummarizedAcrossAnHour() throws {
        let hour = CapacityRollupBuilder.hour(containing: Date(timeIntervalSince1970: 1_800_000_000))
        let previousControl = control(
            periods: 100,
            throttledPeriods: 10,
            memoryHighEvents: 1,
            memoryMaxEvents: 0,
            oomEvents: 0,
            oomKillEvents: 0,
            tasksCurrent: 5
        )
        let currentControl = control(
            periods: 200,
            throttledPeriods: 60,
            memoryHighEvents: 4,
            memoryMaxEvents: 1,
            oomEvents: 1,
            oomKillEvents: 1,
            tasksCurrent: 10
        )
        let previous = sample(
            at: hour.addingTimeInterval(10),
            oomKillCount: 2,
            expectedUnits: [expectedUnit(.active), expectedUnit(.inactive)],
            controls: [previousControl]
        )
        let current = sample(
            at: hour.addingTimeInterval(20),
            oomKillCount: 3,
            failedServices: [ServiceMetric(name: "example.service")],
            expectedUnits: [expectedUnit(.active), expectedUnit(.active)],
            controls: [currentControl]
        )

        let rollup = try #require(CapacityRollupBuilder.build(samples: [previous, current]).first)

        #expect(rollup.host.oomKillCount == 1)
        #expect(rollup.host.failedServiceSampleCount == 1)
        #expect(rollup.host.expectedUnitObservationCount == 4)
        #expect(rollup.host.activeExpectedUnitObservationCount == 3)
        #expect(rollup.workload.cpuThrottledPeriodPercent?.p95 == 50)
        #expect(rollup.workload.memoryHighEvents == 3)
        #expect(rollup.workload.memoryMaxEvents == 1)
        #expect(rollup.workload.oomEvents == 1)
        #expect(rollup.workload.oomKillEvents == 1)
        #expect(rollup.workload.tasksAtLimitSampleCount == 1)
        #expect(rollup.workload.configuredLimitObservationCount == 8)
    }

    @Test func capacitySummaryStatesWindowCoverageAndLimitations() throws {
        let hour = CapacityRollupBuilder.hour(containing: Date(timeIntervalSince1970: 1_800_000_000))
        let rollups = CapacityRollupBuilder.build(samples: [
            sample(at: hour.addingTimeInterval(10)),
            sample(at: hour.addingTimeInterval(30)),
        ])
        let device = MachineDevice(
            id: "linux",
            name: "Example server",
            platform: .linux,
            isLocal: false,
            isOnline: true,
            connection: .direct
        )

        let summary = CapacitySummaryComposer.compose(device: device, rollups: rollups)

        #expect(summary.contains("Observation window:"))
        #expect(summary.contains("Observed samples: 2 of approximately 3"))
        #expect(summary.contains("Host utilization"))
        #expect(summary.contains("Host saturation"))
        #expect(summary.contains("Workload limits"))
        #expect(summary.contains("Raw 90-day percentiles cannot be reconstructed"))
        #expect(summary.contains("Compare quiet, scheduled, and one-time work separately"))
        #expect(summary.contains("does not forecast demand or recommend a machine size"))
    }

    @Test func legacySamplesBackfillAdditivelyAndOnlyOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite3")
        let hour = CapacityRollupBuilder.hour(containing: Date(timeIntervalSince1970: 1_800_000_000))
        let samples = [
            sample(at: hour.addingTimeInterval(10), cpu: 10),
            sample(at: hour.addingTimeInterval(20), cpu: 20),
        ]
        try seedLegacyMetricDatabase(url: url, samples: samples)

        let store = try MetricsStore(url: url)
        #expect(try await store.recentCapacityRollups(deviceID: "linux", since: .distantPast).isEmpty)
        try await store.backfillCapacityRollupsIfNeeded()
        let first = try await store.recentCapacityRollups(deviceID: "linux", since: .distantPast)
        try await store.backfillCapacityRollupsIfNeeded()
        let second = try await store.recentCapacityRollups(deviceID: "linux", since: .distantPast)
        let raw = try await store.recentSamples(deviceID: "linux", since: .distantPast)

        #expect(first == second)
        #expect(first.count == 1)
        #expect(raw.count == 2)
    }

    @Test func pruningKeepsNinetyDaysAndEnforcesThePayloadBudget() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try MetricsStore(
            url: directory.appendingPathComponent("bounded.sqlite3"),
            rollupPayloadBudgetBytes: 3_000
        )
        for offset in 0..<6 {
            try await saveWithRollups(
                sample(at: now.addingTimeInterval(Double(offset - 5) * 3_600), cpu: Double(offset * 10)), in: store)
        }
        let bounded = try await store.capacityRollupStorage()
        #expect(bounded.payloadBytes <= 3_000)
        #expect(bounded.rowCount < 6)

        let retentionStore = try MetricsStore(url: directory.appendingPathComponent("retention.sqlite3"))
        try await saveWithRollups(
            sample(at: now.addingTimeInterval(-MetricsStore.capacityRollupRetention - 1)), in: retentionStore)
        try await saveWithRollups(sample(at: now), in: retentionStore)
        try await retentionStore.prune(now: now)
        let retained = try await retentionStore.recentCapacityRollups(deviceID: "linux", since: .distantPast)
        #expect(retained.count == 1)
        #expect(retained.first?.hourStart == CapacityRollupBuilder.hour(containing: now))
    }

    private func saveWithRollups(_ sample: MetricSample, in store: MetricsStore) async throws {
        try await store.save(sample)
        try await store.replaceCapacityRollups(
            deviceID: sample.deviceID,
            hourStart: CapacityRollupBuilder.hour(containing: sample.timestamp),
            with: CapacityRollupBuilder.build(samples: [sample])
        )
    }

    private func sample(
        at timestamp: Date,
        hostname: String = "example",
        uptime: TimeInterval = 1_000,
        cpu: Double = 25,
        memoryUsedPercent: Double = 50,
        bootID: String = "boot-a",
        collectorVersion: String? = "collector-a",
        filesystemID: String? = "filesystem-a",
        diskTotalBytes: UInt64 = 100_000_000_000,
        oomKillCount: Int = 0,
        failedServices: [ServiceMetric] = [],
        expectedUnits: [ExpectedUnitMetric]? = nil,
        controls: [WorkloadResourceControlMetric]? = nil
    ) -> MetricSample {
        let memoryTotal: UInt64 = 10_000
        let available = UInt64(Double(memoryTotal) * (1 - memoryUsedPercent / 100))
        return MetricSample(
            deviceID: "linux",
            timestamp: timestamp,
            hostname: hostname,
            uptimeSeconds: uptime,
            cpuPercent: cpu,
            logicalCPUCount: 4,
            loadAverage1: 1,
            loadAverage5: 1,
            loadAverage15: 1,
            memoryTotalBytes: memoryTotal,
            memoryAvailableBytes: available,
            swapTotalBytes: 2_000,
            swapUsedBytes: 500,
            diskTotalBytes: diskTotalBytes,
            diskUsedBytes: diskTotalBytes / 2,
            diskReadBytesPerSecond: 1_000,
            diskWriteBytesPerSecond: 500,
            networkReceiveBytesPerSecond: 2_000,
            networkTransmitBytesPerSecond: 1_000,
            cpuPressure: PressureMetric(someAverage10: 2, fullAverage10: 0),
            memoryPressure: PressureMetric(someAverage10: 1, fullAverage10: 0.5),
            ioPressure: PressureMetric(someAverage10: 3, fullAverage10: 1),
            failedServices: failedServices,
            expectedUnits: expectedUnits,
            workloadResourceControls: controls,
            oomKillCount: oomKillCount,
            bootID: bootID,
            collectorVersion: collectorVersion,
            rootFilesystemID: filesystemID
        )
    }

    private func expectedUnit(_ state: ExpectedUnitState) -> ExpectedUnitMetric {
        ExpectedUnitMetric(name: "example.service", kind: .service, state: state)
    }

    private func control(
        periods: UInt64,
        throttledPeriods: UInt64,
        memoryHighEvents: UInt64,
        memoryMaxEvents: UInt64,
        oomEvents: UInt64,
        oomKillEvents: UInt64,
        tasksCurrent: UInt64
    ) -> WorkloadResourceControlMetric {
        WorkloadResourceControlMetric(
            id: "/system.slice/example.service",
            name: "example.service",
            systemdUnit: "example.service",
            cgroupPath: "/system.slice/example.service",
            availability: .available,
            memoryCurrentBytes: value(100),
            memoryPeakBytes: value(200),
            memoryHigh: limit(1_000),
            memoryMax: limit(2_000),
            memoryEvents: WorkloadMemoryEventsMetric(
                high: value(memoryHighEvents),
                max: value(memoryMaxEvents),
                oom: value(oomEvents),
                oomKill: value(oomKillEvents)
            ),
            cpuQuota: WorkloadCPUQuotaMetric(
                state: .configured,
                quotaMicroseconds: 100_000,
                periodMicroseconds: 100_000
            ),
            cpuWeight: value(100),
            cpuStat: WorkloadCPUStatMetric(
                usageMicroseconds: value(1_000),
                userMicroseconds: value(800),
                systemMicroseconds: value(200),
                periods: value(periods),
                throttledPeriods: value(throttledPeriods),
                throttledMicroseconds: value(100)
            ),
            ioWeight: value(100),
            ioPressure: WorkloadPressureMetric(
                availability: .available,
                someAverage10: 4,
                fullAverage10: 2
            ),
            tasksCurrent: value(tasksCurrent),
            tasksMax: limit(10)
        )
    }

    private func value(_ value: UInt64) -> WorkloadResourceValueMetric {
        WorkloadResourceValueMetric(availability: .available, value: value)
    }

    private func limit(_ value: UInt64) -> WorkloadResourceLimitMetric {
        WorkloadResourceLimitMetric(state: .configured, value: value)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseCapacityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func seedLegacyMetricDatabase(url: URL, samples: [MetricSample]) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        #expect(
            sqlite3_exec(
                handle,
                """
                CREATE TABLE metric_samples (
                    id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    payload BLOB NOT NULL
                );
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        for sample in samples {
            var statement: OpaquePointer?
            #expect(
                sqlite3_prepare_v2(
                    handle,
                    "INSERT INTO metric_samples(id, device_id, timestamp, payload) VALUES(?, ?, ?, ?);",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            )
            let prepared = try #require(statement)
            sqlite3_bind_text(prepared, 1, sample.id.uuidString, -1, capacitySQLiteTransient)
            sqlite3_bind_text(prepared, 2, sample.deviceID, -1, capacitySQLiteTransient)
            sqlite3_bind_double(prepared, 3, sample.timestamp.timeIntervalSince1970)
            let payload = try encoder.encode(sample)
            payload.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(
                    prepared,
                    4,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    capacitySQLiteTransient
                )
            }
            #expect(sqlite3_step(prepared) == SQLITE_DONE)
            sqlite3_finalize(prepared)
        }
    }
}

private let capacitySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
