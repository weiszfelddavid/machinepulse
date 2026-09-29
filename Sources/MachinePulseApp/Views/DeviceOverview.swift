import AppKit
import MachinePulseCore
import SwiftUI

extension DeviceDetails {
    var overview: some View {
        Group {
            Text("Overview")
                .font(.headline)

            stateSummary(showsHealthy: false)
            actions

            if let sample {
                sampleTimestampLabel(sample)
                currentMetricBars(sample)
                HStack {
                    networkLine(
                        receive: sample.networkReceiveBytesPerSecond, transmit: sample.networkTransmitBytesPerSecond)
                    Spacer()
                    Text("Uptime \(MetricFormat.duration(sample.uptimeSeconds))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                relevantProcess(for: sample)

                CapacityEvidenceView(
                    rollups: model.capacityRollups[device.id] ?? [],
                    thresholds: model.thresholds
                ) {
                    model.copyCapacitySummary(for: device)
                }
            } else if let rate = model.trafficRates[device.id] {
                networkLine(receive: rate.receivedBytesPerSecond, transmit: rate.transmittedBytesPerSecond)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.supportsWorkloads(device) { workloadOverview }
            if model.supportsStorage(device) { storageOverview }
        }
    }

    @ViewBuilder
    func relevantProcess(for sample: MetricSample) -> some View {
        if let incident = featuredIncident {
            switch incident.kind {
            case .cpu:
                if let process = sample.topCPUProcesses.first { ProcessRow.cpu(process) }
            case .memory, .memoryPressure, .swap, .oom:
                if let process = sample.topMemoryProcesses.first { ProcessRow.memory(process) }
            case .diskPressure:
                if let process = sample.topIOProcesses?.first { ProcessRow.io(process) }
            case .connectivity, .collection, .diskCapacity, .service:
                EmptyView()
            }
        }
    }

    // A clicked button keeps keyboard focus on macOS 15. These two are the only
    // buttons whose own action removes them from the popover; a focus left on
    // a view that no longer exists closes the popover at the next section
    // change, so they never take focus.
    var workloadOverview: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Workloads", systemImage: "network")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(workloadCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(workloadFindingLabel)
                .font(.caption2)
                .foregroundStyle(workloadFindingCount > 0 ? .orange : .secondary)
            Button {
                selectedSection = .workloads
            } label: {
                HStack(spacing: 4) {
                    Text("View Workloads")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    var storageOverview: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let scan = model.diskScans[device.id] {
                    Text("\(SizeFormat.bytes(scan.totalBytes)) scanned")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(storageSummaryLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                selectedSection = .storage
            } label: {
                HStack(spacing: 4) {
                    Text(model.diskScans[device.id] == nil ? "Scan storage" : "View Storage")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    var storageSummaryLabel: String {
        guard let scan = model.diskScans[device.id] else {
            return "Not scanned yet · a scan runs only when you ask"
        }
        if scan.findings.isEmpty { return "Nothing worth a look in the last scan" }
        return
            "\(SizeFormat.bytes(scan.worthALookBytes)) worth a look in \(scan.findings.count) place\(scan.findings.count == 1 ? "" : "s")"
    }

    var workloadCountLabel: String {
        if device.isLocal { return "\(model.runningServers.count) running" }
        return "\(sample?.remoteWorkloads?.count ?? 0) observed"
    }

    var workloadFindingCount: Int {
        model.reports[device.id]?.issues.count { $0.workload != nil } ?? 0
    }

    var workloadFindingLabel: String {
        if workloadFindingCount == 0 { return "No current workload findings" }
        return "\(workloadFindingCount) current finding\(workloadFindingCount == 1 ? "" : "s")"
    }
}
