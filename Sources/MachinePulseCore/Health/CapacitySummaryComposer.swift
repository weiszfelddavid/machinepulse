import Foundation

public enum CapacitySummaryComposer {
    public static func compose(
        device: MachineDevice,
        rollups: [CapacityHourlyRollup]
    ) -> String {
        guard let evidence = CapacityWindowEvidence.summarize(rollups) else {
            return """
                MachinePulse capacity summary
                Machine: \(device.name)
                Observation window: unavailable

                Evidence limitations:
                - No hourly capacity rollups are available yet.
                - MachinePulse does not forecast demand or recommend a machine size.
                """
        }

        var lines = [
            "MachinePulse capacity summary",
            "Machine: \(device.name)",
            "Observation window: \(date(evidence.observedFrom)) through \(date(evidence.observedThrough))",
            "Observed samples: \(evidence.sampleCount) of approximately \(evidence.expectedSampleCount) (\(percent(evidence.coverageFraction * 100)) coverage)",
            "Hourly segments: \(evidence.rollupCount); recorded boundaries: \(evidence.totalBreakCount)",
            "",
            "Host utilization — typical-hour P50 / P95 / P99:",
            "- CPU: \(triplet(evidence.host.cpuPercent, unit: "%"))",
            "- Memory: \(triplet(evidence.host.memoryUsedPercent, unit: "%"))",
            "- Swap: \(triplet(evidence.host.swapUsedPercent, unit: "%"))",
            "- Disk used: \(triplet(evidence.host.diskUsedPercent, unit: "%"))",
            "- Disk read: \(triplet(evidence.host.diskReadBytesPerSecond, unit: " B/s"))",
            "- Disk write: \(triplet(evidence.host.diskWriteBytesPerSecond, unit: " B/s"))",
            "- Network receive: \(triplet(evidence.host.networkReceiveBytesPerSecond, unit: " B/s"))",
            "- Network transmit: \(triplet(evidence.host.networkTransmitBytesPerSecond, unit: " B/s"))",
            "",
            "Host saturation — typical-hour P50 / P95 / P99:",
            "- CPU wait (some): \(triplet(evidence.host.cpuPressure.some, unit: "%"))",
            "- Memory wait (full): \(triplet(evidence.host.memoryPressure.full, unit: "%"))",
            "- Storage wait (full): \(triplet(evidence.host.ioPressure.full, unit: "%"))",
            "- OOM kills observed between compatible samples: \(evidence.host.oomKillCount)",
            "",
            "Workload limits:",
            "- CPU throttled periods: \(triplet(evidence.workload.cpuThrottledPeriodPercent, unit: "%"))",
            "- Workload storage wait (full): \(triplet(evidence.workload.ioPressure.full, unit: "%"))",
            "- Memory high / max / OOM / OOM-kill events: \(evidence.workload.memoryHighEvents) / \(evidence.workload.memoryMaxEvents) / \(evidence.workload.oomEvents) / \(evidence.workload.oomKillEvents)",
            "- Samples at TasksMax: \(evidence.workload.tasksAtLimitSampleCount)",
            "- Configured / unlimited limit observations: \(evidence.workload.configuredLimitObservationCount) / \(evidence.workload.unlimitedLimitObservationCount)",
        ]
        if let freshness = evidence.expectedServiceFreshnessPercent {
            lines.append("- Expected-unit freshness: \(percent(freshness)) active observations")
        } else {
            lines.append("- Expected-unit freshness: unavailable")
        }
        if evidence.host.failedServiceSampleCount > 0 {
            lines.append("- Samples with failed services: \(evidence.host.failedServiceSampleCount)")
        }

        lines.append("")
        lines.append("Recorded boundaries:")
        if evidence.breakCounts.isEmpty {
            lines.append("- None in the retained rollups.")
        } else {
            for reason in CapacityHistoryBreakReason.allCases {
                guard let count = evidence.breakCounts[reason], count > 0 else { continue }
                lines.append("- \(reason.title): \(count)")
            }
        }
        lines += [
            "",
            "Evidence limitations:",
            "- Detailed samples remain available for seven days; this longer view uses compact hourly summaries.",
            "- P50, P95, and P99 are sample-weighted typical-hour values. Raw 90-day percentiles cannot be reconstructed from rollups.",
            "- Missing samples and incompatible periods reduce continuity; compare stable periods after workload or policy changes.",
            "- Compare quiet, scheduled, and one-time work separately; combined periods can hide different causes.",
            "- Correlation does not prove which workload caused host pressure.",
            "- MachinePulse does not forecast demand or recommend a machine size.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func date(_ value: Date) -> String {
        ISO8601DateFormatter().string(from: value)
    }

    private static func triplet(_ value: CapacityDistribution?, unit: String) -> String {
        guard let value else { return "unavailable" }
        return "\(number(value.p50))\(unit) / \(number(value.p95))\(unit) / \(number(value.p99))\(unit)"
    }

    private static func percent(_ value: Double) -> String { "\(number(value))%" }

    private static func number(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }
}
