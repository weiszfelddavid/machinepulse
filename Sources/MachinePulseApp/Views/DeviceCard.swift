import AppKit
import MachinePulseCore
import SwiftUI

struct DeviceCard: View {
    @Bindable var model: AppModel
    let device: MachineDevice
    @Binding var selectedSection: MachineSectionFilter
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var preference: DevicePreference {
        model.preferences[device.id] ?? DevicePreference()
    }

    var report: HealthReport? { model.reports[device.id] }
    var state: HealthState {
        if !device.isOnline, !device.isMobile { return .unreachable }
        return report?.state ?? .healthy
    }

    var showsNeutralOfflineBadge: Bool {
        device.isMobile && !device.isOnline
    }

    var body: some View {
        VStack(spacing: 0) {
            if preference.isEnabled {
                Button(action: toggleExpansion) {
                    header
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(device.name)" : "Expand \(device.name)")
                .help(isExpanded ? "Collapse \(device.name)" : "Expand \(device.name)")
            } else {
                header
            }

            if preference.isEnabled, isExpanded {
                Divider()
                DeviceDetails(model: model, device: device, selectedSection: $selectedSection)
                    .padding(10)
            }
        }
        .cardChrome(tint: state.color, strength: preference.isEnabled ? 0.22 : 0.06)
        .onChange(of: preference.isEnabled) { _, isEnabled in
            if !isEnabled { isExpanded = false }
        }
    }

    var header: some View {
        HStack(spacing: 9) {
            Image(systemName: device.platform.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(preference.isEnabled ? state.color : .secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(device.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if device.isLocal {
                        Text("This Mac")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if preference.isEnabled {
                if report == nil, preference.mode == .deep {
                    Text("Loading")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if showsNeutralOfflineBadge {
                    Text("Offline")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                } else {
                    HealthBadge(state: state)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Button("Monitor") { model.setEnabled(true, for: device) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
    }

    func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
    }

    var statusLine: String {
        if !preference.isEnabled {
            return "\(device.platform.displayName) · \(device.isOnline ? "Online" : "Offline")"
        }
        if !device.isOnline {
            if device.isMobile {
                return report?.summary ?? "Offline"
            }
            return "Unreachable · Check Tailscale connectivity"
        }
        guard let report else {
            return preference.mode == .deep ? "Waiting for first sample" : "Checking presence"
        }
        switch report.state {
        case .healthy: return "Healthy now"
        case .unreachable: return "Unreachable · \(report.summary)"
        case .warning, .critical: return "Needs attention · \(report.summary)"
        }
    }
}

struct DeviceDetails: View {
    @Bindable var model: AppModel

    let device: MachineDevice

    @Binding var selectedSection: MachineSectionFilter

    @State var confirmsStopMonitoring = false

    @State var showsTopProcesses = false

    @State var showsExpectedUnits = false

    @State var showsIncidentHistory = false

    var sample: MetricSample? { model.samples[device.id] }

    var history: [MetricSample] {
        guard let last = model.histories[device.id]?.last else { return [] }
        return (model.histories[device.id] ?? []).filter {
            $0.timestamp >= last.timestamp.addingTimeInterval(-15 * 60)
        }
    }

    var diskTrend: DiskGrowthTrend? {
        DiskGrowthAnalyzer.analyze(samples: model.histories[device.id] ?? [])
    }

    var featuredIncident: HealthIncident? { model.currentOrRecentIncident(for: device.id) }

    var telemetryIsFromLastSuccessfulSample: Bool {
        !device.isOnline
            || model.reports[device.id]?.issues.contains {
                $0.kind == .collection || $0.kind == .connectivity
            } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedSection == .overview {
                overview
            } else if selectedSection == .vitals {
                vitals
            } else if model.supportsWorkloads(device), selectedSection == .workloads {
                if device.isLocal {
                    RunningServersSection(model: model)
                } else {
                    RemoteWorkloadsSection(
                        device: device,
                        sample: sample,
                        healthIssues: model.reports[device.id]?.issues ?? []
                    )
                }
            } else if selectedSection == .storage, model.supportsStorage(device) {
                StorageSection(model: model, device: device)
            }
            if device.isLocal,
                selectedSection == .displays,
                model.localDisplayControls.preferences.showsControls
            {
                LocalDisplayControlsSection(controller: model.localDisplayControls)
            }
        }
        .confirmationDialog(
            "Stop monitoring \(device.name)?",
            isPresented: $confirmsStopMonitoring,
            titleVisibility: .visible
        ) {
            Button("Stop monitoring", role: .destructive) { model.setEnabled(false, for: device) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The machine will no longer affect menu-bar health. Stored history is preserved.")
        }
    }

    @ViewBuilder
    func stateSummary(showsHealthy: Bool) -> some View {
        if let incident = featuredIncident {
            IncidentSummary(incident: incident, isLocalMachine: device.isLocal)
        } else if model.reports[device.id] == nil {
            Label("Collecting the first sample…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if showsHealthy {
            Label("Healthy now", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    func sampleTimestampLabel(_ sample: MetricSample) -> some View {
        if telemetryIsFromLastSuccessfulSample {
            Label(
                "Last successful sample \(RelativeTime.phrase(since: sample.timestamp))",
                systemImage: "clock"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Label(
                "Current readings · sampled \(RelativeTime.phrase(since: sample.timestamp))",
                systemImage: "waveform.path.ecg"
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    var actions: some View {
        HStack(spacing: 14) {
            if device.collectsOverSSH, model.preferences[device.id]?.mode == .deep {
                Button("Open SSH") { model.openSSH(for: device) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.vertical, 4)
            }
            CopyButton(title: "Copy diagnostic", systemImage: nil) {
                model.copyDiagnostic(for: device)
                return true
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.vertical, 4)
            Spacer()
            Menu {
                Button("Refresh now") { Task { await model.refreshNow() } }
                Divider()
                Button("Stop monitoring…", role: .destructive) { confirmsStopMonitoring = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Machine actions")
            .accessibilityLabel("More actions for \(device.name)")
        }
    }

    func currentMetricBars(_ sample: MetricSample) -> some View {
        HStack(spacing: 12) {
            MetricBar(
                label: "CPU",
                value: sample.cpuPercent,
                tint: meterColor(
                    sample.cpuPercent,
                    warning: model.thresholds.cpuWarningPercent,
                    critical: model.thresholds.cpuCriticalPercent
                )
            )
            MetricBar(
                label: "RAM",
                value: sample.memoryUsedFraction * 100,
                tint: memoryMeterColor(for: sample)
            )
            MetricBar(
                label: "Disk",
                value: sample.diskUsedFraction * 100,
                tint: meterColor(
                    sample.diskUsedFraction,
                    warning: model.thresholds.diskWarningFraction,
                    critical: model.thresholds.diskCriticalFraction
                )
            )
        }
    }

    func meterColor(_ value: Double, warning: Double, critical: Double) -> Color {
        if value >= critical { return .red }
        if value >= warning { return .orange }
        return .accentColor
    }

    func memoryMeterColor(for sample: MetricSample) -> Color {
        guard sample.memoryPressureLevel != nil else {
            return meterColor(
                sample.memoryUsedFraction,
                warning: model.thresholds.memoryWarningFraction,
                critical: model.thresholds.memoryCriticalFraction
            )
        }
        guard let state = model.reports[device.id]?.issues.first(where: { $0.id == "mac-memory-pressure" })?.state
        else {
            return .accentColor
        }
        return state == .critical ? .red : .orange
    }
}

struct ProcessRow: View {
    let label: String
    let name: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(name)
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}

extension ProcessRow {
    static func cpu(_ process: ProcessMetric) -> ProcessRow {
        ProcessRow(label: "Top CPU", name: process.name, value: MetricFormat.percent(process.cpuPercent))
    }

    static func memory(_ process: ProcessMetric) -> ProcessRow {
        ProcessRow(label: "Top RAM", name: process.name, value: MetricFormat.bytes(process.residentBytes))
    }

    static func io(_ process: ProcessIOMetric) -> ProcessRow {
        ProcessRow(
            label: "Top I/O",
            name: process.systemdUnit.map { "\($0) (\(process.name))" } ?? process.name,
            value: MetricFormat.rate(process.totalBytesPerSecond))
    }
}
