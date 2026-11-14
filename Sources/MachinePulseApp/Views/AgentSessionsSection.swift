import MachinePulseCore
import SwiftUI

struct AgentSessionsSection: View {
    @Bindable var model: AppModel
    let device: MachineDevice

    private var sessions: [AgentSessionMetric] { model.agentSessions[device.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Agents", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(countLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            ForEach(sessions) { session in
                AgentSessionRow(session: session) {
                    Task { await model.focus(session, on: device) }
                }
                if let message = model.agentFocusMessages[device.id]?[session.id] {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .warningBox()
                }
            }
        }
    }

    private var countLabel: String {
        let waiting = sessions.filter { $0.state == .waiting || $0.state == .approval }.count
        return waiting > 0 ? "\(waiting) waiting for you" : "\(sessions.count) running"
    }
}

private struct AgentSessionRow: View {
    let session: AgentSessionMetric
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(session.agent.displayName) · \(stateText)")
                        .font(.caption2)
                        .foregroundStyle(session.state == .approval ? .orange : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome(tint: tint)
        .help(session.cwd ?? session.projectName)
        .accessibilityLabel("\(session.projectName), \(session.agent.displayName), \(stateText)")
        .accessibilityHint("Opens the terminal of this session")
    }

    private var stateText: String {
        switch session.state {
        case .waiting:
            if let duration = session.finishedTurnDuration {
                return "Finished \(RelativeTime.phrase(since: session.since)) after \(MetricFormat.duration(duration))"
            }
            return "Waiting for you since \(RelativeTime.phrase(since: session.since))"
        case .approval:
            return "Needs approval"
        case .working:
            let startedAt = session.turnStartedAt ?? session.since
            return "Working for \(MetricFormat.duration(Date().timeIntervalSince(startedAt)))"
        case .idle:
            return "Idle"
        }
    }

    private var symbol: String {
        switch session.state {
        case .waiting: "checkmark.circle.fill"
        case .approval: "hand.raised.fill"
        case .working: "ellipsis.circle"
        case .idle: "moon.zzz"
        }
    }

    private var tint: Color {
        switch session.state {
        case .waiting: .green
        case .approval: .orange
        case .working: .blue
        case .idle: .secondary
        }
    }
}
