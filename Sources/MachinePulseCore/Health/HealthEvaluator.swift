import Foundation

public enum HealthEvaluator {
    private static let activeSwapWarningBytesPerSecond = 10 * 1_024 * 1_024.0

    public static func evaluate(
        sample: MetricSample,
        previousSample: MetricSample? = nil,
        thresholds: HealthThresholds = .balanced,
        evaluatedAt: Date = Date()
    ) -> HealthReport {
        var issues: [HealthIssue] = []

        appendThresholdIssue(
            to: &issues,
            id: "cpu",
            kind: .cpu,
            value: sample.cpuPercent,
            warning: thresholds.cpuWarningPercent,
            critical: thresholds.cpuCriticalPercent,
            title: "CPU is busy",
            format: { String(format: "%.0f%% CPU utilization", $0) }
        )
        if sample.memoryPressureLevel != nil {
            appendMacMemoryIssue(to: &issues, sample: sample)
        } else {
            appendThresholdIssue(
                to: &issues,
                id: "memory",
                kind: .memory,
                value: sample.memoryUsedFraction,
                warning: thresholds.memoryWarningFraction,
                critical: thresholds.memoryCriticalFraction,
                title: "Memory is tight",
                format: percentFraction
            )
            let memoryIsCurrentlyTight =
                sample.memoryUsedFraction >= thresholds.memoryWarningFraction
                || (sample.memoryPressure?.someAverage10 ?? 0) >= thresholds.pressureWarningAverage10
                || (sample.memoryPressure?.fullAverage10 ?? 0) >= thresholds.pressureWarningAverage10
            if sample.swapTotalBytes > 0,
                sample.swapUsedFraction >= thresholds.swapWarningFraction,
                memoryIsCurrentlyTight
            {
                issues.append(
                    HealthIssue(
                        id: "swap",
                        kind: .swap,
                        state: .warning,
                        title: "Swap and memory are under pressure",
                        explanation:
                            "\(percentFraction(sample.swapUsedFraction)) of swap is occupied while current memory indicators are elevated.",
                        measurement: sample.swapUsedFraction,
                        threshold: thresholds.swapWarningFraction
                    ))
            }
        }
        appendThresholdIssue(
            to: &issues,
            id: "disk-capacity",
            kind: .diskCapacity,
            value: sample.diskUsedFraction,
            warning: thresholds.diskWarningFraction,
            critical: thresholds.diskCriticalFraction,
            title: "Disk space is running low",
            format: percentFraction
        )

        if let pressure = sample.cpuPressure {
            appendPressureIssue(
                to: &issues,
                id: "cpu-pressure",
                kind: .cpu,
                title: "CPU contention",
                pressure: pressure,
                resource: .cpu,
                thresholds: thresholds
            )
        }
        if let pressure = sample.ioPressure {
            appendPressureIssue(
                to: &issues,
                id: "io-pressure",
                kind: .diskPressure,
                title: "Storage contention",
                pressure: pressure,
                resource: .storage,
                thresholds: thresholds,
                evidence: ioEvidence(in: sample)
            )
        }
        if let pressure = sample.memoryPressure {
            appendPressureIssue(
                to: &issues,
                id: "memory-pressure",
                kind: .memoryPressure,
                title: "Memory contention",
                pressure: pressure,
                resource: .memory,
                thresholds: thresholds
            )
        }

        let workloadIssues = WorkloadHealthEvaluator.evaluate(
            sample: sample,
            previousSample: previousSample,
            thresholds: thresholds
        )
        issues.append(contentsOf: workloadIssues)

        let expectedUnitNames = Set(sample.expectedUnits?.map(\.name) ?? [])
        for unit in sample.expectedUnits ?? [] {
            let kindName = unit.kind.rawValue
            let title: String
            let explanation: String
            let state: HealthState
            switch unit.state {
            case .failed:
                title = "Expected \(kindName) failed"
                explanation = "\(unit.name) is in systemd's failed state."
                let previousUnitWasFailed =
                    previousSample?.bootID == sample.bootID
                    && previousSample?.expectedUnits?.contains {
                        $0.name == unit.name && $0.state == .failed
                    } == true
                    && previousSample.map {
                        let interval = sample.timestamp.timeIntervalSince($0.timestamp)
                        return interval > 0 && interval <= 60
                    } == true
                state = previousUnitWasFailed ? .critical : .warning
            case .missing:
                title = "Expected \(kindName) is missing"
                explanation = "systemd could not find \(unit.name) on this machine."
                state = .warning
            case .inactive:
                title = "Expected \(kindName) is inactive"
                explanation = "\(unit.name) is configured as expected, but systemd reports it inactive."
                state = .warning
            case .active:
                continue
            }
            let control = sample.workloadResourceControls?.first { $0.systemdUnit == unit.name }
            issues.append(
                HealthIssue(
                    id: "expected-unit:\(unit.name)",
                    kind: .service,
                    state: state,
                    title: title,
                    explanation: explanation,
                    evidence: unit.substate.map { "systemd substate: \($0)." },
                    workload: control.map {
                        WorkloadHealthContext(id: $0.id, name: $0.name, systemdUnit: $0.systemdUnit)
                    }
                ))
        }

        let relevantFailedServices = sample.failedServices.filter { service in
            if expectedUnitNames.contains(service.name) { return false }
            if service.isEnabled == true { return true }
            guard let failedAt = service.failedAt else { return true }
            return sample.timestamp.timeIntervalSince(failedAt) <= 60 * 60
        }
        if !relevantFailedServices.isEmpty {
            let names = relevantFailedServices.prefix(3).map(\.name).joined(separator: ", ")
            issues.append(
                HealthIssue(
                    id: "failed-services",
                    kind: .service,
                    state: .warning,
                    title:
                        "\(relevantFailedServices.count) system service\(relevantFailedServices.count == 1 ? "" : "s") failed",
                    explanation: names
                ))
        }

        let previousOOMContextWasAvailable = previousSample?.oomCollectionStatus != .unavailable
        let increasedOOMCount =
            previousSample?.bootID == sample.bootID
            && previousOOMContextWasAvailable
            && sample.oomKillCount > (previousSample?.oomKillCount ?? 0)
        let newerOOMTimestamp =
            previousSample?.bootID == sample.bootID
            && previousOOMContextWasAvailable
            && sample.lastOOMKillAt.map { latest in
                guard let previous = previousSample?.lastOOMKillAt else { return true }
                return latest > previous
            } == true
        let startsNewObservationWindow =
            previousSample == nil
            || previousSample?.bootID != sample.bootID
            || previousSample?.oomCollectionStatus == .unavailable
        let newObservationWindowHasVeryRecentOOM =
            startsNewObservationWindow
            && sample.lastOOMKillAt.map { sample.timestamp.timeIntervalSince($0) <= 15 * 60 } == true
        if increasedOOMCount || newerOOMTimestamp || newObservationWindowHasVeryRecentOOM {
            let event = sample.latestOOMEvent
            let representedByWorkloadFinding =
                event.map { event in
                    guard event.constraint == .cgroup, let cgroup = event.cgroup else { return false }
                    let controlIDs = Set(
                        (sample.workloadResourceControls ?? [])
                            .filter { $0.cgroupPath == cgroup }
                            .map(\.id)
                    )
                    return workloadIssues.contains {
                        $0.kind == .oom && $0.workload.map { controlIDs.contains($0.id) } == true
                    }
                } == true
            if !representedByWorkloadFinding {
                issues.append(
                    HealthIssue(
                        id: "oom",
                        kind: .oom,
                        state: .critical,
                        title: "A new out-of-memory kill occurred",
                        explanation: oomExplanation(event),
                        evidence: oomEvidence(event)
                    ))
            }
        }

        issues.sort { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state > rhs.state }
            return lhs.title < rhs.title
        }
        let state = issues.map(\.state).max() ?? .healthy
        let summary = issues.first?.title ?? "Everything looks steady"
        return HealthReport(
            deviceID: sample.deviceID,
            state: state,
            summary: summary,
            issues: issues,
            evaluatedAt: evaluatedAt
        )
    }

    public static func unreachable(
        deviceID: String,
        message: String,
        evaluatedAt: Date = Date()
    ) -> HealthReport {
        let issue = HealthIssue(
            id: "connectivity",
            kind: .connectivity,
            state: .unreachable,
            title: "Machine is unreachable",
            explanation: message
        )
        return HealthReport(
            deviceID: deviceID,
            state: .unreachable,
            summary: issue.title,
            issues: [issue],
            evaluatedAt: evaluatedAt
        )
    }

    public static func aggregate(_ reports: some Sequence<HealthReport>) -> HealthState {
        reports.map(\.state).max() ?? .healthy
    }

    private static func appendThresholdIssue(
        to issues: inout [HealthIssue],
        id: String,
        kind: HealthIssueKind,
        value: Double,
        warning: Double,
        critical: Double,
        title: String,
        format: (Double) -> String
    ) {
        guard value >= warning else { return }
        let state: HealthState = value >= critical ? .critical : .warning
        issues.append(
            HealthIssue(
                id: id,
                kind: kind,
                state: state,
                title: title,
                explanation:
                    "\(format(value)); the \(state.title.lowercased()) threshold is \(format(state == .critical ? critical : warning)).",
                measurement: value,
                threshold: state == .critical ? critical : warning
            ))
    }

    private static func appendMacMemoryIssue(to issues: inout [HealthIssue], sample: MetricSample) {
        guard let pressure = sample.memoryPressureLevel else { return }
        let swapIn = sample.swapInBytesPerSecond ?? 0
        let swapOut = sample.swapOutBytesPerSecond ?? 0
        let swapActivity = max(swapIn, swapOut)
        let isActivelySwapping = swapActivity >= activeSwapWarningBytesPerSecond
        guard pressure != .normal || isActivelySwapping else { return }

        let state: HealthState = pressure == .critical ? .critical : .warning
        let title: String
        if pressure == .critical {
            title = "Memory pressure is critical"
        } else if pressure == .warning {
            title = "Memory pressure is elevated"
        } else {
            title = "Memory is actively swapping"
        }

        var details: [String] = []
        if pressure != .normal {
            details.append("macOS reports \(pressure.rawValue) memory pressure.")
        }
        if isActivelySwapping {
            details.append("Swap activity is in \(formatRate(swapIn)), out \(formatRate(swapOut)).")
        }
        issues.append(
            HealthIssue(
                id: "mac-memory-pressure",
                kind: pressure == .normal ? .swap : .memoryPressure,
                state: state,
                title: title,
                explanation: details.joined(separator: " "),
                measurement: isActivelySwapping ? swapActivity : nil,
                threshold: isActivelySwapping ? activeSwapWarningBytesPerSecond : nil
            ))
    }

    private static func appendPressureIssue(
        to issues: inout [HealthIssue],
        id: String,
        kind: HealthIssueKind,
        title: String,
        pressure: PressureMetric,
        resource: PressureResource,
        thresholds: HealthThresholds,
        evidence: String? = nil
    ) {
        let someState = pressureState(for: pressure.someAverage10, thresholds: thresholds)
        let fullState = pressureState(for: pressure.fullAverage10, thresholds: thresholds)
        let state = max(someState, fullState)
        guard state != .healthy else { return }

        let fullDrivesSeverity = fullState > someState || (fullState == someState && fullState != .healthy)
        let measurement = fullDrivesSeverity ? pressure.fullAverage10 : pressure.someAverage10
        let explanation = pressureExplanation(pressure, resource: resource)
        issues.append(
            HealthIssue(
                id: id,
                kind: kind,
                state: state,
                title: title,
                explanation: explanation,
                measurement: measurement,
                threshold: state == .critical
                    ? thresholds.pressureCriticalAverage10 : thresholds.pressureWarningAverage10,
                evidence: evidence
            ))
    }

    private static func pressureState(
        for value: Double,
        thresholds: HealthThresholds
    ) -> HealthState {
        if value >= thresholds.pressureCriticalAverage10 { return .critical }
        if value >= thresholds.pressureWarningAverage10 { return .warning }
        return .healthy
    }

    private static func pressureExplanation(
        _ pressure: PressureMetric,
        resource: PressureResource
    ) -> String {
        String(
            format:
                "At least one %@ waited %@ during %.1f%% of the latest 10-second window; all %@ waited together during %.1f%%.",
            resource.singularTaskDescription,
            resource.waitDescription,
            pressure.someAverage10,
            resource.pluralTaskDescription,
            pressure.fullAverage10
        )
    }

    private static func ioEvidence(in sample: MetricSample) -> String? {
        guard let process = sample.topIOProcesses?.first, process.totalBytesPerSecond > 0 else { return nil }
        let source: String
        if let unit = process.systemdUnit,
            unit.hasPrefix("session-"),
            unit.hasSuffix(".scope")
        {
            let identifier = unit.dropFirst("session-".count).dropLast(".scope".count)
            source = "\(process.name) in interactive session \(identifier)"
        } else if let unit = process.systemdUnit, unit.hasSuffix(".scope") {
            source = "\(process.name) in \(unit)"
        } else {
            source = process.systemdUnit.map { "\($0) (\(process.name))" } ?? process.name
        }
        return
            "Same-sample I/O leader: \(source), reading \(formatRate(process.readBytesPerSecond)) and writing \(formatRate(process.writeBytesPerSecond)). This is correlated activity, not proven cause."
    }

    private static func oomExplanation(_ event: OOMEventMetric?) -> String {
        let victim: String
        if let process = event?.victimProcess, let processID = event?.processID {
            victim = "\(process) (PID \(processID))"
        } else if let process = event?.victimProcess {
            victim = process
        } else {
            victim = "a process"
        }
        switch event?.constraint ?? .unknown {
        case .cgroup:
            return
                "The kernel killed \(victim) inside a memory-limited workload. This does not by itself mean the whole machine ran out of memory."
        case .system:
            return "The kernel killed \(victim) because system memory was exhausted."
        case .unknown:
            return
                "The kernel killed \(victim), but the available journal context does not identify whether the exhausted limit was system-wide or workload-specific."
        }
    }

    private static func oomEvidence(_ event: OOMEventMetric?) -> String? {
        guard let event else { return nil }
        var parts: [String] = []
        if let cgroup = event.cgroup {
            parts.append("Memory cgroup: \(cgroup)")
        }
        if let usage = event.memoryUsageBytes, let limit = event.memoryLimitBytes {
            parts.append("Memory usage \(formatBytes(usage)) of \(formatBytes(limit)) limit")
        } else if let limit = event.memoryLimitBytes {
            parts.append("Memory limit \(formatBytes(limit))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ") + "."
    }

    private static func percentFraction(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func formatRate(_ value: Double) -> String { SizeFormat.rate(value) }

    private static func formatBytes(_ value: UInt64) -> String { SizeFormat.bytes(value) }
}

private enum PressureResource {
    case cpu
    case storage
    case memory

    var singularTaskDescription: String {
        switch self {
        case .cpu: "runnable task"
        case .storage, .memory: "non-idle task"
        }
    }

    var pluralTaskDescription: String {
        switch self {
        case .cpu: "runnable tasks"
        case .storage, .memory: "non-idle tasks"
        }
    }

    var waitDescription: String {
        switch self {
        case .cpu: "for CPU"
        case .storage: "on storage"
        case .memory: "on memory"
        }
    }
}
