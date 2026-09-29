import MachinePulseCore
import SwiftUI

struct CapacityEvidenceView: View {
    let rollups: [CapacityHourlyRollup]
    let thresholds: HealthThresholds
    let copySummary: () -> Void
    @State private var isExpanded = false
    @State private var showsEvidenceQuality = false

    private var evidence: CapacityWindowEvidence? {
        CapacityWindowEvidence.summarize(rollups)
    }

    var body: some View {
        if let evidence {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    Text("Typical hour · P50 / P95 / P99")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    evidenceGroup("Host utilization") {
                        percentileRow("CPU", evidence.host.cpuPercent)
                        percentileRow("Memory", evidence.host.memoryUsedPercent)
                        percentileRow("Disk used", evidence.host.diskUsedPercent)
                        if evidence.host.swapUsedPercent != nil {
                            percentileRow("Swap", evidence.host.swapUsedPercent)
                        }
                    }

                    evidenceGroup("Host saturation") {
                        percentileRow("CPU wait", evidence.host.cpuPressure.some)
                        percentileRow("Memory wait", evidence.host.memoryPressure.full)
                        percentileRow("Storage wait", evidence.host.ioPressure.full)
                        row("OOM kills in window", "\(evidence.host.oomKillCount)")
                        if evidence.host.failedServiceSampleCount > 0 {
                            row("Failed service present", approximateFailedServiceDuration(evidence))
                        }
                    }

                    evidenceGroup("Throughput") {
                        percentileRow("Disk read", evidence.host.diskReadBytesPerSecond, format: MetricFormat.rate)
                        percentileRow("Disk write", evidence.host.diskWriteBytesPerSecond, format: MetricFormat.rate)
                        percentileRow(
                            "Network receive", evidence.host.networkReceiveBytesPerSecond, format: MetricFormat.rate)
                        percentileRow(
                            "Network transmit", evidence.host.networkTransmitBytesPerSecond, format: MetricFormat.rate)
                    }

                    evidenceGroup("Workload consequences") {
                        if evidence.workload.cpuThrottledPeriodPercent != nil {
                            percentileRow("CPU throttled", evidence.workload.cpuThrottledPeriodPercent)
                        }
                        if evidence.workload.ioPressure.full != nil {
                            percentileRow("Storage wait", evidence.workload.ioPressure.full)
                        }
                        HStack {
                            Text("High / max / OOM / kills")
                            Spacer()
                            Text(
                                "\(evidence.workload.memoryHighEvents) / \(evidence.workload.memoryMaxEvents) / \(evidence.workload.oomEvents) / \(evidence.workload.oomKillEvents)"
                            )
                            .monospacedDigit()
                        }
                        row("TasksMax observations", "\(evidence.workload.tasksAtLimitSampleCount)")
                    }

                    DisclosureGroup(isExpanded: $showsEvidenceQuality) {
                        evidenceGroup("Collection detail") {
                            row("Observed samples", "\(evidence.sampleCount.formatted())")
                            row(
                                "Missing samples",
                                "\(max(0, evidence.expectedSampleCount - evidence.sampleCount).formatted())")
                            row("History boundaries", "\(evidence.totalBreakCount)")
                            if evidence.totalBreakCount > 0 {
                                Text(boundarySummary(evidence))
                                    .foregroundStyle(.secondary)
                            }
                            if let freshness = evidence.expectedServiceFreshnessPercent {
                                row("Expected-service freshness", MetricFormat.percent(freshness))
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Label("Evidence quality", systemImage: "checkmark.shield")
                            .font(.caption2.weight(.semibold))
                    }

                    HStack {
                        Label("Local hourly history", systemImage: "internaldrive")
                        Spacer()
                        CopyButton(title: "Copy full summary") {
                            copySummary()
                            return true
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Copy full capacity summary")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Text(
                        "Compare quiet, scheduled, and one-time work separately. This history does not forecast demand or recommend a machine size."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(.top, 5)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Capacity history", systemImage: "chart.xyaxis.line")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(windowLabel(evidence))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(summaryLine(evidence))
                        .font(.caption2.weight(notableSignals(evidence).isEmpty ? .regular : .semibold))
                        .foregroundStyle(notableSignals(evidence).isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Evidence \(evidenceConfidence(evidence)) · \(MetricFormat.percent(evidence.coverageFraction * 100)) coverage"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func evidenceGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .font(.caption2)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func percentileRow(
        _ label: String,
        _ distribution: CapacityDistribution?,
        format: (Double) -> String = MetricFormat.percent
    ) -> some View {
        row(
            label,
            distribution.map { "\(format($0.p50)) / \(format($0.p95)) / \(format($0.p99))" } ?? "Unavailable")
    }

    private func windowLabel(_ evidence: CapacityWindowEvidence) -> String {
        let duration = max(0, evidence.observedThrough.timeIntervalSince(evidence.observedFrom))
        return "\(MetricFormat.duration(duration)) observed"
    }

    private func summaryLine(_ evidence: CapacityWindowEvidence) -> String {
        let signals = notableSignals(evidence)
        guard !signals.isEmpty else { return "No notable longer-term pressure in recorded samples" }
        let visible = signals.prefix(2).joined(separator: " · ")
        let remaining = signals.count - min(2, signals.count)
        return remaining > 0 ? "\(visible) · +\(remaining) more" : visible
    }

    private func notableSignals(_ evidence: CapacityWindowEvidence) -> [String] {
        var signals: [String] = []
        if evidence.host.oomKillCount > 0 {
            signals.append(
                "\(evidence.host.oomKillCount) OOM kill\(evidence.host.oomKillCount == 1 ? "" : "s")"
            )
        }
        if let storageWait = evidence.host.ioPressure.full?.p95,
            storageWait >= thresholds.pressureWarningAverage10
        {
            signals.append("Storage wait P95 \(MetricFormat.percent(storageWait))")
        }
        if let memoryWait = evidence.host.memoryPressure.full?.p95,
            memoryWait >= thresholds.pressureWarningAverage10
        {
            signals.append("Memory wait P95 \(MetricFormat.percent(memoryWait))")
        }
        if let cpuWait = evidence.host.cpuPressure.some?.p95,
            cpuWait >= thresholds.pressureWarningAverage10
        {
            signals.append("CPU wait P95 \(MetricFormat.percent(cpuWait))")
        }
        if evidence.workload.oomKillEvents > 0, evidence.host.oomKillCount == 0 {
            signals.append(
                "\(evidence.workload.oomKillEvents) workload OOM kill\(evidence.workload.oomKillEvents == 1 ? "" : "s")"
            )
        }
        if evidence.workload.tasksAtLimitSampleCount > 0 {
            signals.append("Task limit reached")
        }
        if evidence.host.failedServiceSampleCount > 0 {
            signals.append("Failed service observed")
        }
        return signals
    }

    private func evidenceConfidence(_ evidence: CapacityWindowEvidence) -> String {
        switch evidence.coverageFraction {
        case 0.9...: "strong"
        case 0.7..<0.9: "good"
        case 0.5..<0.7: "limited"
        default: "sparse"
        }
    }

    private func approximateFailedServiceDuration(_ evidence: CapacityWindowEvidence) -> String {
        let seconds =
            Double(evidence.host.failedServiceSampleCount)
            * CapacityRollupBuilder.expectedSampleInterval
        return "~\(MetricFormat.duration(seconds)) observed"
    }

    private func boundarySummary(_ evidence: CapacityWindowEvidence) -> String {
        CapacityHistoryBreakReason.allCases.compactMap { reason in
            guard let count = evidence.breakCounts[reason], count > 0 else { return nil }
            return "\(reason.title) \(count)"
        }.joined(separator: " · ")
    }
}
