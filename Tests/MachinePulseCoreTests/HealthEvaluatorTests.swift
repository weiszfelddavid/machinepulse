import Foundation
import Testing
@testable import MachinePulseCore

struct HealthEvaluatorTests {
    @Test func explainsCurrentPressureAndServicesWithoutPromotingHistoricalState() {
        let sample = makeSample(
            oomCount: 9,
            ioPressure: PressureMetric(someAverage10: 9.9, fullAverage10: 9.7),
            topIOProcesses: [
                ProcessIOMetric(
                    name: "php",
                    systemdUnit: "example-refresh.service",
                    readBytesPerSecond: 24_000_000,
                    writeBytesPerSecond: 2_000_000
                )
            ],
            failedServices: [ServiceMetric(name: "nginx.service", failedAt: Date(), isEnabled: true)],
            lastOOMKillAt: Date().addingTimeInterval(-60 * 60)
        )
        let report = HealthEvaluator.evaluate(sample: sample)

        #expect(report.state == .warning)
        #expect(report.issues.contains(where: { $0.kind == .diskPressure }))
        #expect(
            report.issues.first(where: { $0.kind == .diskPressure })?.evidence?.contains(
                "example-refresh.service"
            ) == true)
        #expect(
            report.issues.first(where: { $0.kind == .diskPressure })?.evidence?.contains(
                "not proven cause"
            ) == true)
        #expect(report.issues.contains(where: { $0.kind == .service }))
        #expect(!report.issues.contains(where: { $0.kind == .oom }))
    }

    @Test func hostThresholdsGradeCPUDiskAndSwap() {
        func state(of id: String, in sample: MetricSample) -> HealthState? {
            HealthEvaluator.evaluate(sample: sample).issues.first { $0.id == id }?.state
        }
        #expect(HealthEvaluator.evaluate(sample: makeSample()).state == .healthy)
        #expect(state(of: "cpu", in: makeSample(cpuPercent: 80)) == .warning)
        #expect(state(of: "cpu", in: makeSample(cpuPercent: 95)) == .critical)
        #expect(HealthEvaluator.evaluate(sample: makeSample(cpuPercent: 80), thresholds: .quiet).issues.isEmpty)
        #expect(state(of: "disk-capacity", in: makeSample(diskUsedBytes: 76_000_000_000)) == .critical)
        let tightMemoryAndSwap = makeSample(memoryAvailableBytes: 600_000_000, swapUsedBytes: 1_200_000_000)
        #expect(state(of: "memory", in: tightMemoryAndSwap) == .warning)
        #expect(state(of: "swap", in: tightMemoryAndSwap) == .warning)
        #expect(state(of: "swap", in: makeSample(swapUsedBytes: 1_200_000_000)) == nil)
    }

    @Test func ignoresOldTransientServiceFailures() {
        let sample = makeSample(failedServices: [
            ServiceMetric(
                name: "old-healthcheck.service",
                failedAt: Date().addingTimeInterval(-2 * 60 * 60),
                isEnabled: false
            )
        ])
        let report = HealthEvaluator.evaluate(sample: sample)

        #expect(!(report.issues.contains(where: { $0.kind == .service })))
    }

    @Test func keepsEnabledFailedServicesActionable() {
        let sample = makeSample(failedServices: [
            ServiceMetric(
                name: "nginx.service",
                failedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60),
                isEnabled: true
            )
        ])
        let report = HealthEvaluator.evaluate(sample: sample)

        #expect(report.issues.contains(where: { $0.kind == .service }))
    }

    @Test func treatsANewOOMAsCritical() {
        let previous = makeSample(oomCount: 8)
        let current = makeSample(oomCount: 9)
        let report = HealthEvaluator.evaluate(sample: current, previousSample: previous)

        #expect(report.state == .critical)
        #expect(report.issues.first(where: { $0.kind == .oom })?.state == .critical)
    }

    @Test func explainsCgroupOOMWithoutClaimingWholeMachineFailure() throws {
        let event = OOMEventMetric(
            timestamp: Date(),
            victimProcess: "php",
            processID: 42,
            cgroup: "/system.slice/worker.service",
            constraint: .cgroup,
            memoryUsageBytes: 500 * 1_024 * 1_024,
            memoryLimitBytes: 512 * 1_024 * 1_024
        )
        let current = makeSample(oomCount: 10, latestOOMEvent: event, lastOOMKillAt: event.timestamp)
        let previous = makeSample(oomCount: 9, lastOOMKillAt: event.timestamp.addingTimeInterval(-60))
        let issue = try #require(
            HealthEvaluator.evaluate(sample: current, previousSample: previous).issues.first { $0.id == "oom" })

        #expect(issue.explanation.contains("php (PID 42)"))
        #expect(issue.explanation.contains("does not by itself mean the whole machine"))
        #expect(issue.evidence?.contains("worker.service") == true)
        #expect(issue.evidence?.contains("512 MiB") == true)
    }

    @Test func explainsSystemOOMAsSystemWide() throws {
        let event = OOMEventMetric(timestamp: Date(), victimProcess: "postgres", constraint: .system)
        let issue = try #require(
            HealthEvaluator.evaluate(
                sample: makeSample(oomCount: 10, latestOOMEvent: event, lastOOMKillAt: event.timestamp),
                previousSample: makeSample(
                    oomCount: 9, lastOOMKillAt: event.timestamp.addingTimeInterval(-60))
            ).issues.first { $0.id == "oom" })
        #expect(issue.explanation.contains("system memory was exhausted"))
    }

    @Test func restoredJournalAccessDoesNotReplayAnOldOOM() {
        let previous = makeSample(
            oomCollectionStatus: .unavailable
        )
        let current = makeSample(
            oomCount: 4,
            lastOOMKillAt: Date().addingTimeInterval(-24 * 60 * 60),
            oomCollectionStatus: .available
        )

        let report = HealthEvaluator.evaluate(sample: current, previousSample: previous)

        #expect(!(report.issues.contains { $0.id == "oom" }))
    }

    @Test func restoredJournalAccessStillReportsARecentOOM() {
        let now = Date()
        let previous = makeSample(
            oomCollectionStatus: .unavailable
        )
        let current = makeSample(
            oomCount: 1,
            latestOOMEvent: OOMEventMetric(timestamp: now, victimProcess: "worker"),
            lastOOMKillAt: now,
            oomCollectionStatus: .available
        )

        let report = HealthEvaluator.evaluate(sample: current, previousSample: previous)

        #expect(report.issues.contains { $0.id == "oom" })
    }

    @Test func expectedServicesAndTimersAreOptInAndUnitAware() {
        let sample = makeSample(
            expectedUnits: [
                ExpectedUnitMetric(name: "api.service", kind: .service, state: .active, substate: "running"),
                ExpectedUnitMetric(name: "backup.timer", kind: .timer, state: .active, substate: "waiting"),
                ExpectedUnitMetric(name: "worker.service", kind: .service, state: .inactive, substate: "dead"),
                ExpectedUnitMetric(name: "missing.timer", kind: .timer, state: .missing),
            ]
        )
        let issues = HealthEvaluator.evaluate(sample: sample).issues

        #expect(!(issues.contains { $0.id.contains("api.service") || $0.id.contains("backup.timer") }))
        #expect(issues.contains { $0.id == "expected-unit:worker.service" && $0.title.contains("service") })
        #expect(issues.contains { $0.id == "expected-unit:missing.timer" && $0.title.contains("timer") })
    }

    @Test func observedWorkloadStateDoesNotCreateHealthFindings() {
        let sample = makeSample(
            remoteWorkloads: [
                RemoteWorkloadMetric(
                    id: "observed.service",
                    name: "observed.service",
                    state: .failed
                )
            ]
        )
        let report = HealthEvaluator.evaluate(sample: sample)
        #expect(report.state == .healthy)
        #expect(report.issues.isEmpty)
    }

    @Test func resourceControlConfigurationAndHistoricalCountersStayNeutralWithoutADelta() {
        let sample = makeSample(
            workloadResourceControls: [makeWorkloadResourceControl(memoryHighEvents: 99, oomKills: 4)]
        )
        let report = HealthEvaluator.evaluate(sample: sample)
        #expect(report.state == .healthy)
        #expect(report.issues.isEmpty)
    }

    @Test func workloadOOMDoesNotDuplicateTheMatchingJournalFinding() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let previousControl = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            oomEvents: 0,
            oomKills: 0
        )
        let currentControl = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            oomEvents: 1,
            oomKills: 1
        )
        let event = OOMEventMetric(
            timestamp: start.addingTimeInterval(10),
            victimProcess: "api",
            cgroup: "/system.slice/api.service",
            constraint: .cgroup
        )
        let previous = makeSample(
            oomCount: 4,
            workloadResourceControls: [previousControl],
            lastOOMKillAt: start,
            timestamp: start
        )
        let current = makeSample(
            oomCount: 5,
            workloadResourceControls: [currentControl],
            latestOOMEvent: event,
            lastOOMKillAt: event.timestamp,
            timestamp: event.timestamp
        )
        let issues = HealthEvaluator.evaluate(sample: current, previousSample: previous).issues

        #expect(issues.filter { $0.kind == .oom }.count == 1)
        let oomIssue = try #require(issues.first { $0.kind == .oom })
        #expect(oomIssue.workload != nil)
    }

    @Test func failedExpectedServiceIsACriticalWorkloadFinding() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let control = makeWorkloadResourceControl()
        let expectedUnits = [
            ExpectedUnitMetric(
                name: "api.service",
                kind: .service,
                state: .failed,
                substate: "failed"
            )
        ]
        let previous = makeSample(
            expectedUnits: expectedUnits,
            workloadResourceControls: [control],
            timestamp: start
        )
        let current = makeSample(
            expectedUnits: expectedUnits,
            workloadResourceControls: [control],
            timestamp: start.addingTimeInterval(10)
        )
        let issue = try #require(
            HealthEvaluator.evaluate(sample: current, previousSample: previous).issues.first {
                $0.id == "expected-unit:api.service"
            })

        #expect(issue.state == .critical)
        #expect(issue.workload?.id == control.id)
    }

    @Test func firstFailedExpectedServiceObservationIsAWarning() throws {
        let issue = try #require(
            HealthEvaluator.evaluate(
                sample: makeSample(
                    expectedUnits: [
                        ExpectedUnitMetric(name: "api.service", kind: .service, state: .failed)
                    ],
                    workloadResourceControls: [makeWorkloadResourceControl()]
                )
            ).issues.first { $0.id == "expected-unit:api.service" })
        #expect(issue.state == .warning)
    }

    @Test func watchedFailedUnitDoesNotDuplicateGenericFailure() {
        let sample = makeSample(
            failedServices: [ServiceMetric(name: "api.service", isEnabled: true)],
            expectedUnits: [ExpectedUnitMetric(name: "api.service", kind: .service, state: .failed)]
        )
        let issues = HealthEvaluator.evaluate(sample: sample).issues.filter { $0.kind == .service }
        #expect(issues.count == 1)
        #expect(issues.first?.id == "expected-unit:api.service")
    }

    @Test func reportsCurrentCPUPressure() {
        let sample = makeSample(
            cpuPressure: PressureMetric(someAverage10: 9, fullAverage10: 0)
        )
        let report = HealthEvaluator.evaluate(sample: sample)

        let issue = report.issues.first(where: { $0.title == "CPU contention" })
        #expect(issue != nil)
        #expect(issue?.explanation.contains("At least one runnable task") == true)
        #expect(issue?.explanation.contains("all runnable tasks") == true)
    }

    @Test func keepsPartialAndFullStoragePressureDistinct() throws {
        let report = HealthEvaluator.evaluate(
            sample: makeSample(
                ioPressure: PressureMetric(someAverage10: 30, fullAverage10: 9)
            ))
        let issue = try #require(report.issues.first(where: { $0.id == "io-pressure" }))

        #expect(issue.state == .critical)
        #expect(issue.measurement == 30)
        #expect(issue.explanation.contains("during 30.0%"))
        #expect(issue.explanation.contains("together during 9.0%"))
    }

    @Test func fullStoragePressureCanDriveCriticalSeverity() throws {
        let report = HealthEvaluator.evaluate(
            sample: makeSample(
                ioPressure: PressureMetric(someAverage10: 12, fullAverage10: 26)
            ))
        let issue = try #require(report.issues.first(where: { $0.id == "io-pressure" }))

        #expect(issue.state == .critical)
        #expect(issue.measurement == 26)
        #expect(issue.explanation.contains("during 12.0%"))
        #expect(issue.explanation.contains("together during 26.0%"))
    }

    @Test func labelsInteractiveSessionIOAsCorrelatedEvidence() throws {
        let report = HealthEvaluator.evaluate(
            sample: makeSample(
                ioPressure: PressureMetric(someAverage10: 9.9, fullAverage10: 9.7),
                topIOProcesses: [
                    ProcessIOMetric(
                        name: "sqlite3",
                        systemdUnit: "session-13.scope",
                        readBytesPerSecond: 34_500_000,
                        writeBytesPerSecond: 34_700_000
                    )
                ]
            ))
        let evidence = try #require(report.issues.first(where: { $0.id == "io-pressure" })?.evidence)

        #expect(evidence.contains("sqlite3 in interactive session 13"))
        #expect(evidence.contains("not proven cause"))
        #expect(!(evidence.contains("Likely contributor")))
    }

    @Test func macRAMUsageDoesNotWarnWithoutPressure() {
        let sample = makeSample(
            memoryAvailableBytes: 200_000_000,
            memoryPressureLevel: .normal
        )
        let report = HealthEvaluator.evaluate(sample: sample)

        #expect(report.state == .healthy)
        #expect(!(report.issues.contains(where: { $0.kind == .memory })))
    }

    @Test func reportsMacMemoryPressureAndActiveSwapOnce() {
        let sample = makeSample(
            memoryPressureLevel: .warning,
            swapOutBytesPerSecond: 12 * 1_024 * 1_024
        )
        let report = HealthEvaluator.evaluate(sample: sample)

        #expect(report.state == .warning)
        #expect(report.issues.filter { $0.id == "mac-memory-pressure" }.count == 1)
    }

    @Test func decodesCollectorContract() throws {
        let url = try #require(Bundle.module.url(forResource: "collector-snapshot", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(CollectorSnapshot.self, from: Data(contentsOf: url))

        #expect(snapshot.logicalCPUCount == 3)
        #expect(snapshot.topCPUProcesses.first?.name == "php")
        #expect(snapshot.ioPressure?.fullAverage10 == 9.7)
        #expect(snapshot.lastOOMKillAt != nil)
    }

    private func makeSample(
        oomCount: Int = 0,
        cpuPercent: Double = 47,
        cpuPressure: PressureMetric? = nil,
        memoryAvailableBytes: UInt64 = 2_500_000_000,
        swapUsedBytes: UInt64 = 200_000_000,
        diskUsedBytes: UInt64 = 50_000_000_000,
        memoryPressureLevel: MemoryPressureLevel? = nil,
        swapOutBytesPerSecond: Double? = nil,
        ioPressure: PressureMetric? = nil,
        topIOProcesses: [ProcessIOMetric]? = nil,
        failedServices: [ServiceMetric] = [],
        expectedUnits: [ExpectedUnitMetric]? = nil,
        remoteWorkloads: [RemoteWorkloadMetric]? = nil,
        workloadResourceControls: [WorkloadResourceControlMetric]? = nil,
        latestOOMEvent: OOMEventMetric? = nil,
        lastOOMKillAt: Date? = nil,
        oomCollectionStatus: OOMCollectionStatus? = nil,
        timestamp: Date = Date()
    ) -> MetricSample {
        MetricSample(
            deviceID: "vps-id",
            timestamp: timestamp,
            hostname: "ubuntu",
            uptimeSeconds: 10_000,
            cpuPercent: cpuPercent,
            logicalCPUCount: 3,
            loadAverage1: 1.2,
            loadAverage5: 1.1,
            loadAverage15: 1.0,
            memoryTotalBytes: 4_000_000_000,
            memoryAvailableBytes: memoryAvailableBytes,
            swapTotalBytes: 2_000_000_000,
            swapUsedBytes: swapUsedBytes,
            diskTotalBytes: 80_000_000_000,
            diskUsedBytes: diskUsedBytes,
            cpuPressure: cpuPressure,
            memoryPressureLevel: memoryPressureLevel,
            ioPressure: ioPressure,
            swapOutBytesPerSecond: swapOutBytesPerSecond,
            topIOProcesses: topIOProcesses,
            failedServices: failedServices,
            expectedUnits: expectedUnits,
            remoteWorkloads: remoteWorkloads,
            workloadResourceControls: workloadResourceControls,
            oomKillCount: oomCount,
            lastOOMKillAt: lastOOMKillAt,
            oomCollectionStatus: oomCollectionStatus,
            latestOOMEvent: latestOOMEvent,
            bootID: "boot-one"
        )
    }
}
