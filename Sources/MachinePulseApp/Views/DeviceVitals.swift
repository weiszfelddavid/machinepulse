import AppKit
import MachinePulseCore
import SwiftUI

extension DeviceDetails {
    var vitals: some View {
        Group {
            Text("Vitals")
                .font(.headline)

            stateSummary(showsHealthy: true)
            actions

            if let sample {
                sampleTimestampLabel(sample)
                currentTelemetry(sample)

                if history.count > 1 {
                    HistorySparkline(
                        samples: history,
                        focus: featuredIncident,
                        thresholds: model.thresholds
                    )
                    .frame(minHeight: 112)
                }

                CapacityEvidenceView(
                    rollups: model.capacityRollups[device.id] ?? [],
                    thresholds: model.thresholds
                ) {
                    model.copyCapacitySummary(for: device)
                }

                processDetailsDisclosure(sample)
                expectedUnitDetailsDisclosure(sample)
            } else if let rate = model.trafficRates[device.id] {
                networkLine(receive: rate.receivedBytesPerSecond, transmit: rate.transmittedBytesPerSecond)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            incidentHistory
        }
    }

    func currentTelemetry(_ sample: MetricSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            currentMetricBars(sample)

            Text(
                "Storage \(MetricFormat.bytes(sample.diskUsedBytes)) used · \(MetricFormat.bytes(sample.diskFreeBytes)) free of \(MetricFormat.bytes(sample.diskTotalBytes))"
            )
            .accessibilityLabel(
                "Storage, \(MetricFormat.percent(sample.diskUsedFraction * 100)) used, \(MetricFormat.bytes(sample.diskFreeBytes)) free of \(MetricFormat.bytes(sample.diskTotalBytes))"
            )

            if let diskTrend {
                Text(diskTrendSummary(diskTrend))
            }

            HStack {
                networkLine(
                    receive: sample.networkReceiveBytesPerSecond, transmit: sample.networkTransmitBytesPerSecond)
                Spacer()
                Text("Uptime \(MetricFormat.duration(sample.uptimeSeconds))")
            }
            HStack {
                Text(
                    String(
                        format: "Load %.1f · %.1f · %.1f", sample.loadAverage1, sample.loadAverage5,
                        sample.loadAverage15))
                Spacer()
                if sample.diskReadBytesPerSecond > 0 || sample.diskWriteBytesPerSecond > 0 {
                    Text(
                        "Disk I/O R \(MetricFormat.rate(sample.diskReadBytesPerSecond)) · W \(MetricFormat.rate(sample.diskWriteBytesPerSecond))"
                    )
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    func diskTrendSummary(_ trend: DiskGrowthTrend) -> String {
        let interval = MetricFormat.duration(trend.duration)
        return switch trend.state {
        case .growing, .shrinking:
            "Recent storage \(MetricFormat.signedBytes(trend.changeBytes)) over \(interval)"
        case .temporarySpike:
            "Temporary storage peak +\(MetricFormat.bytes(trend.peakAboveBaselineBytes)); back near baseline"
        case .stable:
            "Recent storage steady over \(interval)"
        }
    }

    @ViewBuilder
    func processDetailsDisclosure(_ sample: MetricSample) -> some View {
        if !sample.topCPUProcesses.isEmpty || !sample.topMemoryProcesses.isEmpty
            || sample.topIOProcesses?.isEmpty == false
        {
            DisclosureGroup(isExpanded: $showsTopProcesses) {
                VStack(alignment: .leading, spacing: 5) {
                    processDetails(sample)
                }
                .padding(.top, 5)
            } label: {
                Label("Top processes", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    func processDetails(_ sample: MetricSample) -> some View {
        if let process = sample.topCPUProcesses.first { ProcessRow.cpu(process) }
        if let process = sample.topMemoryProcesses.first { ProcessRow.memory(process) }
        if let process = sample.topIOProcesses?.first { ProcessRow.io(process) }
    }

    @ViewBuilder
    func expectedUnitDetailsDisclosure(_ sample: MetricSample) -> some View {
        if let units = sample.expectedUnits, !units.isEmpty {
            DisclosureGroup(isExpanded: $showsExpectedUnits) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(units) { unit in
                        HStack {
                            Text(unit.name)
                                .lineLimit(1)
                            Spacer()
                            Text(expectedUnitStatus(unit))
                                .fontWeight(.semibold)
                                .foregroundStyle(unit.state == .active ? .green : .orange)
                        }
                        .font(.caption2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 5)
            } label: {
                HStack {
                    Label("Expected services", systemImage: "checklist")
                    Spacer()
                    Text("\(units.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
            }
        } else if model.preferences[device.id]?.expectedUnits.isEmpty == false {
            Label("Expected systemd unit status unavailable in this sample", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    func expectedUnitStatus(_ unit: ExpectedUnitMetric) -> String {
        switch unit.state {
        case .active:
            if unit.kind == .timer, unit.substate == "waiting" { return "Waiting" }
            return unit.kind == .service ? "Running" : "Active"
        case .inactive: return "Inactive"
        case .failed: return "Failed"
        case .missing: return "Missing"
        }
    }

    @ViewBuilder
    var incidentHistory: some View {
        let incidents = (model.incidents[device.id] ?? [])
            .filter { $0.id != featuredIncident?.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        if !incidents.isEmpty {
            DisclosureGroup(isExpanded: $showsIncidentHistory) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(incidents.prefix(3)) { incident in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(
                                incident.isClearing
                                    ? "Clearing"
                                    : (incident.isActive ? incident.currentState.title : "Recovered")
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(incident.isActive ? incident.currentState.color : .secondary)
                            .frame(width: 62, alignment: .leading)
                            Text(incident.presentationTitle).lineLimit(1)
                            Spacer()
                            Text(RelativeTime.phrase(since: incident.updatedAt))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption2)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 5)
            } label: {
                CountedDisclosureLabel(
                    title: "Recent incidents", systemImage: "clock.arrow.circlepath", count: incidents.count)
            }
        }
    }
}
