import Foundation

/// Converts bounded cgroup observations into workload-scoped findings. The
/// evaluator is pure: it changes no controls and uses only two adjacent samples.
public enum WorkloadHealthEvaluator {
    static let repeatedMemoryHighEventCount: UInt64 = 2
    static let cpuWarningThrottledFraction = 0.20
    static let cpuCriticalThrottledFraction = 0.50
    static let minimumCPUPeriods: UInt64 = 10
    static let memoryLimitWarningFraction = 0.90
    static let maximumComparisonInterval: TimeInterval = 60

    public static func evaluate(
        sample: MetricSample,
        previousSample: MetricSample?,
        thresholds: HealthThresholds
    ) -> [HealthIssue] {
        guard let controls = sample.workloadResourceControls else { return [] }
        var previousByID: [String: WorkloadResourceControlMetric] = [:]
        for control in previousSample?.workloadResourceControls ?? [] where previousByID[control.id] == nil {
            previousByID[control.id] = control
        }
        let canCompareSamples = canCompare(sample, with: previousSample)
        var issues: [HealthIssue] = []

        for control in controls where control.availability == .available {
            let previous = canCompareSamples ? previousByID[control.id] : nil
            let comparablePrevious = isSameWorkload(control, previous) ? previous : nil

            if let issue = memoryIssue(
                control: control,
                previous: comparablePrevious,
                sample: sample,
                thresholds: thresholds
            ) {
                issues.append(issue)
            }
            if let issue = cpuIssue(control: control, previous: comparablePrevious) {
                issues.append(issue)
            }
            if let issue = ioIssue(control: control, sample: sample, thresholds: thresholds) {
                issues.append(issue)
            }
            if let issue = taskIssue(control: control) {
                issues.append(issue)
            }
        }

        return issues
    }

    private static func memoryIssue(
        control: WorkloadResourceControlMetric,
        previous: WorkloadResourceControlMetric?,
        sample: MetricSample,
        thresholds: HealthThresholds
    ) -> HealthIssue? {
        let highEvents = delta(control.memoryEvents.high, previous?.memoryEvents.high)
        let maxEvents = delta(control.memoryEvents.max, previous?.memoryEvents.max)
        let oomEvents = delta(control.memoryEvents.oom, previous?.memoryEvents.oom)
        let oomKills = delta(control.memoryEvents.oomKill, previous?.memoryEvents.oomKill)
        let context = workloadContext(control)

        if let oomKills, oomKills > 0 {
            return HealthIssue(
                id: issueID(control, signal: "memory-events"),
                kind: .oom,
                state: .critical,
                title: "\(control.name) had an OOM kill",
                explanation:
                    "The workload reported \(oomKills) new out-of-memory kill\(oomKills == 1 ? "" : "s") since the previous sample.",
                evidence: memoryEvidence(
                    control, highEvents: highEvents, maxEvents: maxEvents, oomEvents: oomEvents,
                    oomKills: oomKills),
                workload: context
            )
        }
        if let maxEvents, maxEvents > 0 {
            return HealthIssue(
                id: issueID(control, signal: "memory-events"),
                kind: .memory,
                state: .critical,
                title: "\(control.name) reached its memory limit",
                explanation:
                    "The workload reported \(maxEvents) new memory maximum event\(maxEvents == 1 ? "" : "s") since the previous sample.",
                evidence: memoryEvidence(
                    control, highEvents: highEvents, maxEvents: maxEvents, oomEvents: oomEvents,
                    oomKills: oomKills),
                workload: context
            )
        }
        if let oomEvents, oomEvents > 0 {
            return HealthIssue(
                id: issueID(control, signal: "memory-events"),
                kind: .oom,
                state: .critical,
                title: "\(control.name) could not allocate memory",
                explanation:
                    "The workload reported \(oomEvents) new out-of-memory event\(oomEvents == 1 ? "" : "s") since the previous sample.",
                evidence: memoryEvidence(
                    control, highEvents: highEvents, maxEvents: maxEvents, oomEvents: oomEvents,
                    oomKills: oomKills),
                workload: context
            )
        }
        if let highEvents, highEvents >= repeatedMemoryHighEventCount {
            return HealthIssue(
                id: issueID(control, signal: "memory-events"),
                kind: .memory,
                state: .warning,
                title: "\(control.name) is under memory pressure",
                explanation:
                    "The workload reported \(highEvents) new memory high events since the previous sample.",
                evidence: memoryEvidence(
                    control, highEvents: highEvents, maxEvents: maxEvents, oomEvents: oomEvents,
                    oomKills: oomKills),
                workload: context
            )
        }

        guard let usage = memoryUsageFraction(control), usage >= memoryLimitWarningFraction else {
            return nil
        }
        let hostPressure = max(
            sample.memoryPressure?.someAverage10 ?? 0,
            sample.memoryPressure?.fullAverage10 ?? 0
        )
        guard hostPressure >= thresholds.pressureWarningAverage10 else { return nil }
        return HealthIssue(
            id: issueID(control, signal: "memory-pressure"),
            kind: .memory,
            state: .warning,
            title: "\(control.name) is close to its memory limit",
            explanation:
                "The workload uses \(percent(usage)) of its effective memory limit while the machine reports memory pressure.",
            measurement: usage,
            threshold: memoryLimitWarningFraction,
            evidence: memoryEvidence(
                control, highEvents: highEvents, maxEvents: maxEvents, oomEvents: oomEvents,
                oomKills: oomKills),
            workload: context
        )
    }

    private static func cpuIssue(
        control: WorkloadResourceControlMetric,
        previous: WorkloadResourceControlMetric?
    ) -> HealthIssue? {
        guard control.cpuQuota.state == .configured,
            let periods = delta(control.cpuStat.periods, previous?.cpuStat.periods),
            let throttled = delta(control.cpuStat.throttledPeriods, previous?.cpuStat.throttledPeriods),
            periods >= minimumCPUPeriods,
            throttled > 0
        else { return nil }

        let fraction = Double(throttled) / Double(periods)
        guard fraction >= cpuWarningThrottledFraction else { return nil }
        let state: HealthState =
            fraction >= cpuCriticalThrottledFraction ? .critical : .warning
        let duration = delta(
            control.cpuStat.throttledMicroseconds,
            previous?.cpuStat.throttledMicroseconds
        )
        var evidence = "CPU quota \(cpuQuota(control.cpuQuota)); \(throttled) of \(periods) periods were throttled."
        if let duration {
            evidence += " The cumulative throttled time increased by \(formatDuration(duration))."
        }
        return HealthIssue(
            id: issueID(control, signal: "cpu-throttling"),
            kind: .cpu,
            state: state,
            title: "\(control.name) is CPU throttled",
            explanation:
                "The workload was throttled during \(percent(fraction)) of CPU periods since the previous sample.",
            measurement: fraction * 100,
            threshold: (state == .critical ? cpuCriticalThrottledFraction : cpuWarningThrottledFraction) * 100,
            evidence: evidence,
            workload: workloadContext(control)
        )
    }

    private static func ioIssue(
        control: WorkloadResourceControlMetric,
        sample: MetricSample,
        thresholds: HealthThresholds
    ) -> HealthIssue? {
        guard control.ioPressure.availability == .available,
            let some = control.ioPressure.someAverage10,
            let full = control.ioPressure.fullAverage10
        else { return nil }
        let measurement = max(some, full)
        let state: HealthState
        if measurement >= thresholds.pressureCriticalAverage10 {
            state = .critical
        } else if measurement >= thresholds.pressureWarningAverage10 {
            state = .warning
        } else {
            return nil
        }

        // The host finding already names same-sample I/O evidence. Do not open a
        // second incident for the same pressure window.
        let hostPressure = max(sample.ioPressure?.someAverage10 ?? 0, sample.ioPressure?.fullAverage10 ?? 0)
        let hostThreshold =
            state == .critical
            ? thresholds.pressureCriticalAverage10 : thresholds.pressureWarningAverage10
        guard hostPressure < hostThreshold else { return nil }

        return HealthIssue(
            id: issueID(control, signal: "io-pressure"),
            kind: .diskPressure,
            state: state,
            title: "\(control.name) has storage contention",
            explanation:
                "The workload waited for storage during \(percent(some / 100)) of the latest 10-second window; all its tasks waited together during \(percent(full / 100)).",
            measurement: measurement,
            threshold: hostThreshold,
            evidence: "Workload I/O weight \(resourceValue(control.ioWeight)).",
            workload: workloadContext(control)
        )
    }

    private static func taskIssue(control: WorkloadResourceControlMetric) -> HealthIssue? {
        guard control.tasksMax.state == .configured,
            let maximum = control.tasksMax.value,
            maximum > 0,
            control.tasksCurrent.availability == .available,
            let current = control.tasksCurrent.value,
            current >= maximum
        else { return nil }
        return HealthIssue(
            id: issueID(control, signal: "tasks"),
            kind: .service,
            state: .warning,
            title: "\(control.name) exhausted its task limit",
            explanation: "The workload uses all \(maximum) available tasks.",
            evidence: "Tasks current \(current); tasks maximum \(maximum).",
            workload: workloadContext(control)
        )
    }

    private static func canCompare(_ sample: MetricSample, with previous: MetricSample?) -> Bool {
        guard let previous,
            let bootID = sample.bootID,
            bootID == previous.bootID
        else { return false }
        let interval = sample.timestamp.timeIntervalSince(previous.timestamp)
        return interval > 0 && interval <= maximumComparisonInterval
    }

    private static func isSameWorkload(
        _ current: WorkloadResourceControlMetric,
        _ previous: WorkloadResourceControlMetric?
    ) -> Bool {
        guard let previous else { return false }
        return current.id == previous.id && current.cgroupPath == previous.cgroupPath
    }

    private static func delta(
        _ current: WorkloadResourceValueMetric,
        _ previous: WorkloadResourceValueMetric?
    ) -> UInt64? {
        guard current.availability == .available,
            previous?.availability == .available,
            let currentValue = current.value,
            let previousValue = previous?.value,
            currentValue >= previousValue
        else { return nil }
        return currentValue - previousValue
    }

    private static func memoryUsageFraction(_ control: WorkloadResourceControlMetric) -> Double? {
        guard control.memoryCurrentBytes.availability == .available,
            let current = control.memoryCurrentBytes.value
        else { return nil }
        let limit = [control.memoryHigh, control.memoryMax]
            .compactMap { metric -> UInt64? in
                guard metric.state == .configured else { return nil }
                return metric.value
            }
            .filter { $0 > 0 }
            .min()
        guard let limit else { return nil }
        return Double(current) / Double(limit)
    }

    private static func memoryEvidence(
        _ control: WorkloadResourceControlMetric,
        highEvents: UInt64?,
        maxEvents: UInt64?,
        oomEvents: UInt64?,
        oomKills: UInt64?
    ) -> String {
        let deltas = [
            "high +\(highEvents ?? 0)",
            "max +\(maxEvents ?? 0)",
            "OOM +\(oomEvents ?? 0)",
            "OOM-kill +\(oomKills ?? 0)",
        ].joined(separator: ", ")
        return
            "Memory current \(resourceBytes(control.memoryCurrentBytes)); high \(resourceLimit(control.memoryHigh)); max \(resourceLimit(control.memoryMax)). Event changes: \(deltas)."
    }

    private static func workloadContext(_ control: WorkloadResourceControlMetric) -> WorkloadHealthContext {
        WorkloadHealthContext(id: control.id, name: control.name, systemdUnit: control.systemdUnit)
    }

    private static func issueID(_ control: WorkloadResourceControlMetric, signal: String) -> String {
        "workload:\(control.id):\(signal)"
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    private static func resourceBytes(_ metric: WorkloadResourceValueMetric) -> String {
        ResourceFormat.bytes(metric)
    }

    private static func resourceLimit(_ metric: WorkloadResourceLimitMetric) -> String {
        ResourceFormat.limit(metric, bytes: true)
    }

    private static func resourceValue(_ metric: WorkloadResourceValueMetric) -> String {
        ResourceFormat.count(metric)
    }

    private static func cpuQuota(_ quota: WorkloadCPUQuotaMetric) -> String {
        ResourceFormat.cpuQuota(quota, withPeriod: false)
    }

    private static func formatDuration(_ microseconds: UInt64) -> String {
        let seconds = Double(microseconds) / 1_000_000
        return seconds < 1
            ? String(format: "%.0f ms", seconds * 1_000)
            : String(format: "%.1f s", seconds)
    }
}
