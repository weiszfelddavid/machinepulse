import Foundation
import Testing
@testable import MachinePulseCore

struct WorkloadHealthEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func unlimitedControlsDoNotCreateFindings() {
        let previous = makeWorkloadResourceControl(
            memoryHighState: .unlimited,
            memoryMaxState: .unlimited,
            memoryHighEvents: 4,
            memoryMaxEvents: 0,
            cpuQuotaState: .unlimited,
            cpuPeriods: 100,
            cpuThrottledPeriods: 0,
            tasksMaxState: .unlimited
        )
        let current = makeWorkloadResourceControl(
            memoryCurrentBytes: 999_000_000,
            memoryHighState: .unlimited,
            memoryMaxState: .unlimited,
            memoryHighEvents: 5,
            memoryMaxEvents: 0,
            cpuQuotaState: .unlimited,
            cpuPeriods: 200,
            cpuThrottledPeriods: 90,
            tasksCurrent: 10_000,
            tasksMaxState: .unlimited
        )
        #expect(evaluate(current: current, previous: previous).isEmpty)
    }

    @Test func repeatedMemoryHighEventsCreateAWorkloadWarning() throws {
        let previous = makeWorkloadResourceControl(memoryHighEvents: 8, memoryMaxEvents: 0)
        let current = makeWorkloadResourceControl(memoryHighEvents: 10, memoryMaxEvents: 0)
        let issue = try #require(evaluate(current: current, previous: previous).first)

        #expect(issue.state == .warning)
        #expect(issue.workload?.id == current.id)
        #expect(issue.id.hasSuffix(":memory-events"))
        #expect(issue.explanation.contains("2 new memory high events"))
    }

    @Test func aMemoryMaximumEventIsCritical() throws {
        let previous = makeWorkloadResourceControl(memoryHighEvents: 8, memoryMaxEvents: 2)
        let current = makeWorkloadResourceControl(memoryHighEvents: 8, memoryMaxEvents: 3)
        let issue = try #require(evaluate(current: current, previous: previous).first)

        #expect(issue.state == .critical)
        #expect(issue.title.contains("reached its memory limit"))
    }

    @Test func anOOMKillIsCriticalAndKeepsLimitEvidence() throws {
        let previous = makeWorkloadResourceControl(memoryMaxEvents: 0, oomEvents: 0, oomKills: 0)
        let current = makeWorkloadResourceControl(memoryMaxEvents: 0, oomEvents: 1, oomKills: 1)
        let issue = try #require(evaluate(current: current, previous: previous).first)

        #expect(issue.kind == .oom)
        #expect(issue.state == .critical)
        #expect(issue.evidence?.contains("OOM-kill +1") == true)
        #expect(issue.evidence?.contains("max") == true)
    }

    @Test func nearLimitUsageNeedsCurrentHostPressure() {
        let control = makeWorkloadResourceControl(
            memoryCurrentBytes: 760_000_000,
            memoryHighEvents: 0,
            memoryMaxEvents: 0
        )
        #expect(evaluate(current: control, previous: control).isEmpty)

        let issues = evaluate(
            current: control,
            previous: control,
            memoryPressure: PressureMetric(someAverage10: 12, fullAverage10: 3)
        )
        #expect(issues.contains { $0.id.hasSuffix(":memory-pressure") })
    }

    @Test func materialCPUThrottlingCreatesAWarning() throws {
        let previous = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            cpuPeriods: 100,
            cpuThrottledPeriods: 10,
            cpuThrottledMicroseconds: 1_000_000
        )
        let current = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            cpuPeriods: 200,
            cpuThrottledPeriods: 40,
            cpuThrottledMicroseconds: 2_000_000
        )
        let issue = try #require(evaluate(current: current, previous: previous).first)

        #expect(issue.state == .warning)
        #expect(issue.measurement == 30)
        #expect(issue.evidence?.contains("30 of 100 periods") == true)
    }

    @Test func severeCPUThrottlingIsCritical() throws {
        let previous = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            cpuPeriods: 100,
            cpuThrottledPeriods: 10
        )
        let current = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            cpuPeriods: 200,
            cpuThrottledPeriods: 70
        )
        let issue = try #require(evaluate(current: current, previous: previous).first)

        #expect(issue.state == .critical)
        #expect(issue.measurement == 60)
    }

    @Test func taskExhaustionCreatesAWarningButNearUsageDoesNot() {
        let near = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            tasksCurrent: 99,
            tasksMax: 100
        )
        #expect(evaluate(current: near, previous: near).isEmpty)

        let exhausted = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            tasksCurrent: 100,
            tasksMax: 100
        )
        #expect(
            evaluate(current: exhausted, previous: near).contains {
                $0.id.hasSuffix(":tasks") && $0.state == .warning
            })
    }

    @Test func workloadIOPressureDoesNotDuplicateTheMatchingHostFinding() {
        let control = makeWorkloadResourceControl(
            memoryHighEvents: 0,
            memoryMaxEvents: 0,
            ioSomeAverage10: 12,
            ioFullAverage10: 9
        )
        let workloadOnly = evaluate(current: control, previous: control)
        #expect(workloadOnly.contains { $0.id.hasSuffix(":io-pressure") })

        let hostAndWorkload = evaluate(
            current: control,
            previous: control,
            ioPressure: PressureMetric(someAverage10: 12, fullAverage10: 9)
        )
        #expect(!(hostAndWorkload.contains { $0.id.hasSuffix(":io-pressure") }))
    }

    @Test func resetRebootMigrationAndLargeGapsDoNotCreateCounterFindings() {
        let previous = makeWorkloadResourceControl(memoryHighEvents: 20, memoryMaxEvents: 5)
        let reset = makeWorkloadResourceControl(memoryHighEvents: 0, memoryMaxEvents: 0)
        #expect(evaluate(current: reset, previous: previous).isEmpty)

        let migrated = makeWorkloadResourceControl(
            id: "/user.slice/api.service",
            cgroupPath: "/user.slice/api.service",
            memoryHighEvents: 22,
            memoryMaxEvents: 5
        )
        #expect(evaluate(current: migrated, previous: previous).isEmpty)

        #expect(evaluate(current: migrated, previous: previous, bootID: "boot-two").isEmpty)
        #expect(evaluate(current: migrated, previous: migrated, interval: 61).isEmpty)
    }

    private func evaluate(
        current: WorkloadResourceControlMetric,
        previous: WorkloadResourceControlMetric?,
        bootID: String = "boot-one",
        interval: TimeInterval = 10,
        memoryPressure: PressureMetric? = nil,
        ioPressure: PressureMetric? = nil
    ) -> [HealthIssue] {
        let currentSample = sample(
            control: current,
            timestamp: start.addingTimeInterval(interval),
            bootID: bootID,
            memoryPressure: memoryPressure,
            ioPressure: ioPressure
        )
        let previousSample = previous.map {
            sample(control: $0, timestamp: start, bootID: "boot-one")
        }
        return WorkloadHealthEvaluator.evaluate(
            sample: currentSample,
            previousSample: previousSample,
            thresholds: .balanced
        )
    }

    private func sample(
        control: WorkloadResourceControlMetric,
        timestamp: Date,
        bootID: String,
        memoryPressure: PressureMetric? = nil,
        ioPressure: PressureMetric? = nil
    ) -> MetricSample {
        MetricSample(
            deviceID: "device",
            timestamp: timestamp,
            hostname: "example",
            uptimeSeconds: 1_000,
            cpuPercent: 10,
            logicalCPUCount: 2,
            loadAverage1: 0.2,
            loadAverage5: 0.2,
            loadAverage15: 0.2,
            memoryTotalBytes: 4_000_000_000,
            memoryAvailableBytes: 3_000_000_000,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            diskTotalBytes: 80_000_000_000,
            diskUsedBytes: 20_000_000_000,
            memoryPressure: memoryPressure,
            ioPressure: ioPressure,
            workloadResourceControls: [control],
            bootID: bootID
        )
    }
}
