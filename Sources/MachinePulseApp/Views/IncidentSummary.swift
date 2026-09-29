import AppKit
import MachinePulseCore
import SwiftUI

struct IncidentSummary: View {
    let incident: HealthIncident
    var isLocalMachine = false
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let workload = incident.workload {
                Label("Workload · \(workload.name)", systemImage: "shippingbox")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(incident.presentationTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Text(contextLine)
                .font(.caption2)
                .foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(primaryExplanation)
                        .font(.caption)
                    if let evidence = incident.retainedEvidence {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Evidence captured at peak")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(evidence)
                                .font(.caption.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(nextAction)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text("Incident details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            statusColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .onChange(of: incident.id) { _, _ in showsDetails = false }
    }

    private var statusTitle: String {
        if incident.isClearing { return "Clearing" }
        return incident.isActive ? incident.currentState.title : "Recovered"
    }

    private var statusColor: Color {
        if incident.isClearing { return .orange }
        return incident.isActive ? incident.currentState.color : .green
    }

    private var primaryExplanation: String {
        if incident.isClearing {
            let remaining = incident.remainingClearSampleCount
            return
                "No longer observed in the current sample. Waiting for \(remaining) more clear reading\(remaining == 1 ? "" : "s") before recovery."
        }
        return incident.latestExplanation
    }

    private var contextLine: String {
        var parts: [String]
        if !incident.isActive, incident.duration < 1 {
            parts = ["Historical event"]
        } else {
            parts = [
                incident.isActive
                    ? "Active for \(MetricFormat.duration(Date().timeIntervalSince(incident.startedAt)))"
                    : "Lasted \(MetricFormat.duration(incident.duration))"
            ]
        }
        if incident.isActive {
            parts.append("Observed \(RelativeTime.phrase(since: incident.lastObservedAt))")
        }
        if let peakMeasurement = incident.peakMeasurement {
            parts.append(
                "Peak \(MetricFormat.incidentMeasurement(peakMeasurement, kind: incident.kind)) \(RelativeTime.phrase(since: incident.peakObservedAt))"
            )
        }
        if !incident.isActive, let endedAt = incident.endedAt {
            parts.append("Recovered \(RelativeTime.phrase(since: endedAt))")
        }
        return parts.joined(separator: " · ")
    }

    private var nextAction: String {
        if incident.workload != nil {
            return "Next: inspect this workload's limits and logs before changing its service or the machine."
        }
        return switch incident.kind {
        case .diskPressure:
            "Next: compare the same-sample I/O leader with workload logs before changing services."
        case .cpu:
            "Next: inspect the top CPU process and confirm whether the load is expected."
        case .memory, .memoryPressure, .swap:
            "Next: inspect memory-heavy processes and current swap activity."
        case .diskCapacity:
            "Next: review storage use before deleting or moving data."
        case .service:
            if incident.issueID.hasPrefix("expected-unit:") {
                "Next: inspect the watched unit's systemd status and logs over SSH."
            } else {
                "Next: inspect the failed service over SSH before restarting it."
            }
        case .oom:
            "Next: inspect memory limits and logs for the killed workload."
        case .connectivity:
            "Next: confirm the machine is powered on and connected to Tailscale."
        case .collection:
            isLocalMachine
                ? "Next: check local system load and relaunch MachinePulse if collection keeps failing."
                : "Next: test the SSH target and remote Python 3 in a terminal; Tailscale still reports the machine online."
        }
    }
}
