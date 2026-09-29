import Foundation

/// Builds the copied diagnostic text. Tailscale reachability is always stated
/// independently of health, and telemetry from a machine whose collection is
/// currently failing is labeled as the last successful sample.
public enum DiagnosticComposer {
    public static func compose(
        device: MachineDevice,
        report: HealthReport?,
        sample: MetricSample?,
        diskTrend: DiskGrowthTrend? = nil,
        thresholds: HealthThresholds? = nil,
        activeIncidents: [HealthIncident],
        recentRecoveredIncidents: [HealthIncident]
    ) -> String {
        var lines = [
            "MachinePulse diagnostic",
            "Machine: \(device.name)",
            "Platform: \(device.platform.rawValue)",
            "Reachable through Tailscale: \(device.isOnline ? "yes" : "no")",
            "Health: \(report?.state.title ?? "Awaiting sample")",
            "Summary: \(report?.summary ?? "—")",
        ]
        if let sample {
            let sampleIsStale =
                !device.isOnline
                || report?.issues.contains { $0.kind == .collection || $0.kind == .connectivity } == true
            if sampleIsStale {
                lines.append(
                    "Last successful sample: \(sample.timestamp.formatted(date: .abbreviated, time: .standard))"
                )
            } else {
                lines.append(
                    "Current sample: \(sample.timestamp.formatted(date: .abbreviated, time: .standard))"
                )
            }
            lines += [
                "Current readings:",
                String(format: "CPU: %.1f%%", sample.cpuPercent),
                String(format: "Memory: %.1f%%", sample.memoryUsedFraction * 100),
                String(
                    format: "Disk: %.1f%% used · %@ used · %@ free · %@ total", sample.diskUsedFraction * 100,
                    formatBytes(sample.diskUsedBytes), formatBytes(sample.diskFreeBytes),
                    formatBytes(sample.diskTotalBytes)),
                String(
                    format: "Network: ↓ %.0f B/s  ↑ %.0f B/s", sample.networkReceiveBytesPerSecond,
                    sample.networkTransmitBytesPerSecond),
            ]
            if let diskTrend {
                lines.append("Recent storage trend: \(diskTrendDescription(diskTrend))")
            }
            if sample.oomCollectionStatus == .unavailable {
                lines.append("OOM journal context: unavailable; check journal permissions on the monitored machine.")
            } else {
                lines.append("OOM kills observed in the bounded boot journal: \(sample.oomKillCount)")
                if let event = sample.latestOOMEvent {
                    lines.append("Newest OOM event: \(oomDescription(event))")
                }
            }
            if let expectedUnits = sample.expectedUnits, !expectedUnits.isEmpty {
                lines.append("Expected systemd units:")
                lines.append(
                    contentsOf: expectedUnits.map { unit in
                        let substate = unit.substate.map { " · \($0)" } ?? ""
                        return "- \(unit.name): \(unit.state.rawValue)\(substate)"
                    })
            }
            if let workloads = sample.remoteWorkloads, !workloads.isEmpty {
                lines.append("Observed remote workloads:")
                lines.append(contentsOf: workloads.map { "- \(workloadDescription($0))" })
            }
            if let controls = sample.workloadResourceControls, !controls.isEmpty {
                lines.append("Workload resource controls (current values and cumulative counters at sample time):")
                lines.append(contentsOf: controls.map { "- \(resourceControlDescription($0))" })
            }
        }
        if let report, !report.issues.isEmpty {
            lines.append("Current health findings:")
            lines.append(
                contentsOf: report.issues.map { issue in
                    let scope = issue.workload.map { "Workload \($0.name)" } ?? "Host"
                    return "- [\(scope)] \(issue.title): \(issue.explanation)"
                })
        }
        let recoveredByRecency = recentRecoveredIncidents.sorted { $0.updatedAt > $1.updatedAt }
        let diagnosticIncidents = Array(activeIncidents.prefix(4)) + Array(recoveredByRecency.prefix(2))
        if !diagnosticIncidents.isEmpty {
            lines.append("Incidents:")
            for incident in diagnosticIncidents {
                lines.append(contentsOf: incidentLines(incident))
            }
        }
        let recoveredIncidents = Array(recoveredByRecency.prefix(3))
        if let snapshot = structuredSnapshot(
            device: device,
            report: report,
            sample: sample,
            diskTrend: diskTrend,
            thresholds: thresholds,
            activeIncidents: activeIncidents,
            recentRecoveredIncidents: recoveredIncidents
        ) {
            lines += ["", "All captured data (JSON):", snapshot]
        }
        return lines.joined(separator: "\n")
    }

    private static func structuredSnapshot(
        device: MachineDevice,
        report: HealthReport?,
        sample: MetricSample?,
        diskTrend: DiskGrowthTrend?,
        thresholds: HealthThresholds?,
        activeIncidents: [HealthIncident],
        recentRecoveredIncidents: [HealthIncident]
    ) -> String? {
        let payload = CompleteDiagnosticPayload(
            formatVersion: 3,
            generatedAt: Date(),
            device: device,
            report: report,
            sample: sample,
            diskGrowthTrend: diskTrend,
            thresholds: thresholds,
            activeIncidents: activeIncidents,
            recentRecoveredIncidents: recentRecoveredIncidents
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func incidentLines(_ incident: HealthIncident) -> [String] {
        let status: String
        if incident.isClearing {
            status = "Clearing after \(incident.peakSeverity.title)"
        } else {
            status = incident.isActive ? incident.currentState.title : "Recovered"
        }

        let scope = incident.workload.map { " · Workload \($0.name)" } ?? " · Host"
        var lines = ["- \(incident.presentationTitle) [\(status)\(scope)]"]
        if !incident.isActive, incident.duration < 1 {
            lines.append(
                "  Historical recovery-only record captured at \(formatted(incident.updatedAt)); no duration is available."
            )
        } else if incident.isClearing {
            lines.append(
                "  Current status: not observed in the latest sample; \(incident.remainingClearSampleCount) more clear sample\(incident.remainingClearSampleCount == 1 ? "" : "s") required."
            )
            lines.append(
                "  Latest incident observation at \(formatted(incident.lastObservedAt)): \(incident.latestExplanation)"
            )
        } else {
            lines.append(
                "  Latest incident observation at \(formatted(incident.lastObservedAt)): \(incident.latestExplanation)"
            )
        }
        if let peakMeasurement = incident.peakMeasurement {
            lines.append(
                "  Peak at \(formatted(incident.peakObservedAt)): \(formatIncidentMeasurement(peakMeasurement, kind: incident.kind))."
            )
        }
        if let evidence = incident.retainedEvidence {
            lines.append("  Evidence captured at peak: \(evidence)")
        }
        return lines
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static func diskTrendDescription(_ trend: DiskGrowthTrend) -> String {
        let duration = formatDuration(trend.duration)
        switch trend.state {
        case .growing:
            return
                "grew by \(formatBytes(UInt64(clamping: trend.changeBytes))) over \(duration); no time-to-full estimate is made."
        case .shrinking:
            return "decreased by \(formatBytes(trend.changeBytes.magnitude)) over \(duration)."
        case .temporarySpike:
            return
                "temporary peak \(formatBytes(trend.peakAboveBaselineBytes)) above baseline, then returned near baseline."
        case .stable:
            return "steady over \(duration)."
        }
    }

    private static func oomDescription(_ event: OOMEventMetric) -> String {
        var parts = [event.timestamp.formatted(date: .abbreviated, time: .standard)]
        if let victim = event.victimProcess {
            parts.append(event.processID.map { "\(victim) (PID \($0))" } ?? victim)
        }
        switch event.constraint {
        case .system: parts.append("system-wide memory constraint")
        case .cgroup: parts.append("workload/cgroup memory constraint")
        case .unknown: parts.append("constraint scope unknown")
        }
        if let cgroup = event.cgroup { parts.append("cgroup \(cgroup)") }
        if let usage = event.memoryUsageBytes, let limit = event.memoryLimitBytes {
            parts.append("\(formatBytes(usage)) used of \(formatBytes(limit)) limit")
        }
        return parts.joined(separator: " · ")
    }

    private static func workloadDescription(_ workload: RemoteWorkloadMetric) -> String {
        var details = [workload.state.rawValue]
        if let uptime = workload.uptimeSeconds {
            details.append("up \(formatDuration(uptime))")
        }
        if !workload.listeners.isEmpty {
            details.append(
                workload.listeners.map { listener in
                    var listenerDetails = [listener.binding.rawValue]
                    if let webProtocol = listener.webProtocol {
                        listenerDetails.append(webProtocol.rawValue)
                    }
                    return "\(listener.displayAddress) (\(listenerDetails.joined(separator: ", ")))"
                }.joined(separator: "; ")
            )
        }
        return "\(workload.name): \(details.joined(separator: " · "))"
    }

    private static func resourceControlDescription(_ control: WorkloadResourceControlMetric) -> String {
        var details: [String] = []
        if let cgroupPath = control.cgroupPath {
            details.append("cgroup \(cgroupPath)")
        }
        guard control.availability == .available else {
            details.append(
                control.availability == .unsupported
                    ? "cgroup v2 unsupported"
                    : "resource context unavailable"
            )
            return "\(control.name): \(details.joined(separator: " · "))"
        }

        details.append(
            "memory \(resourceBytes(control.memoryCurrentBytes)) current / \(resourceBytes(control.memoryPeakBytes)) peak / high \(resourceLimit(control.memoryHigh, bytes: true)) / max \(resourceLimit(control.memoryMax, bytes: true))"
        )
        details.append(
            "memory events high \(resourceCount(control.memoryEvents.high)), max \(resourceCount(control.memoryEvents.max)), OOM \(resourceCount(control.memoryEvents.oom)), OOM-kill \(resourceCount(control.memoryEvents.oomKill))"
        )
        details.append(
            "CPU quota \(cpuQuota(control.cpuQuota)), weight \(resourceCount(control.cpuWeight)), throttled \(resourceCount(control.cpuStat.throttledPeriods)) periods / \(resourceDuration(control.cpuStat.throttledMicroseconds))"
        )
        details.append(
            "I/O weight \(resourceCount(control.ioWeight)), pressure \(resourcePressure(control.ioPressure))"
        )
        details.append(
            "tasks \(resourceCount(control.tasksCurrent)) / \(resourceLimit(control.tasksMax, bytes: false))"
        )
        return "\(control.name): \(details.joined(separator: " · "))"
    }

    private static func resourceBytes(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.bytes(metric) }
    private static func resourceCount(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.count(metric) }
    private static func resourceLimit(_ metric: WorkloadResourceLimitMetric, bytes: Bool) -> String {
        ResourceFormat.limit(metric, bytes: bytes)
    }
    private static func cpuQuota(_ metric: WorkloadCPUQuotaMetric) -> String {
        ResourceFormat.cpuQuota(metric, withPeriod: true)
    }
    private static func resourceDuration(_ metric: WorkloadResourceValueMetric) -> String {
        ResourceFormat.duration(metric)
    }
    private static func resourceMicroseconds(_ value: UInt64) -> String { ResourceFormat.microseconds(value) }
    private static func resourcePressure(_ metric: WorkloadPressureMetric) -> String { ResourceFormat.pressure(metric) }
    private static func formatBytes(_ value: UInt64) -> String { SizeFormat.bytes(value) }

    private static func formatDuration(_ value: TimeInterval) -> String {
        if value < 60 * 60 { return "\(Int((value / 60).rounded())) minutes" }
        return String(format: "%.1f hours", value / (60 * 60))
    }

    private static func formatIncidentMeasurement(_ value: Double, kind: HealthIssueKind) -> String {
        switch kind {
        case .memory, .swap, .diskCapacity:
            String(format: "%.0f%%", value * 100)
        case .diskPressure, .memoryPressure:
            String(format: "%.1f%% stall time", value)
        case .cpu:
            String(format: "%.1f%%", value)
        case .connectivity, .collection, .service, .oom:
            String(format: "%.1f", value)
        }
    }
}

private struct CompleteDiagnosticPayload: Encodable {
    let formatVersion: Int
    let generatedAt: Date
    let device: MachineDevice
    let report: HealthReport?
    let sample: MetricSample?
    let diskGrowthTrend: DiskGrowthTrend?
    let thresholds: HealthThresholds?
    let activeIncidents: [HealthIncident]
    let recentRecoveredIncidents: [HealthIncident]
}
