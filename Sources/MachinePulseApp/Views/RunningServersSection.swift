import MachinePulseCore
import SwiftUI

struct RunningServersSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Workloads", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(workloadCountLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            if let error = model.runningServerError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .warningBox()
            }

            if model.runningServers.isEmpty {
                Text("No project workloads are listening on this Mac.")
                    .emptyStateBox()
            } else {
                ForEach(model.runningServers) { server in
                    RunningServerCard(model: model, server: server)
                }
            }
        }
    }

    private var workloadCountLabel: String {
        "\(model.runningServers.count) running"
    }
}

private struct RunningServerCard: View {
    @Bindable var model: AppModel
    let server: RunningServer
    @State private var confirmsStop = false
    @State private var isStopping = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text("\(server.processName) · Running for \(runningDuration)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(server.browserURL?.absoluteString ?? server.address)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(server.projectPath)

                if confirmsStop {
                    inlineStopConfirmation
                } else {
                    actionRow
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: server.kind == .web ? "globe" : "server.rack")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.projectName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(server.browserURL?.absoluteString ?? server.address)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Running")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .cardChrome(tint: .green)
    }

    private var actionRow: some View {
        HStack(spacing: 7) {
            if server.browserURL != nil {
                Button("Open") { model.open(server) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isStopping)
            }
            CopyButton(title: server.browserURL == nil ? "Copy address" : "Copy URL") {
                model.copyAddress(for: server)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isStopping)

            Spacer()

            if isStopping {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Stopping…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Stopping \(server.projectName)")
            } else {
                Button("Stop…", role: .destructive) { confirmsStop = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var inlineStopConfirmation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Stop \(server.projectName)?", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(
                "Ask process \(server.processID) at \(server.address) to exit gracefully? MachinePulse will not force-quit it."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Button("Cancel") { confirmsStop = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button("Stop server", role: .destructive) { beginStop() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private func beginStop() {
        confirmsStop = false
        isStopping = true
        Task {
            await model.stop(server)
            isStopping = false
        }
    }

    private var runningDuration: String {
        MetricFormat.duration(Date().timeIntervalSince(server.startedAt))
    }
}
