import AppKit
import MachinePulseCore
import SwiftUI

struct RemoteWorkloadsSection: View {
    let device: MachineDevice
    let sample: MetricSample?
    let healthIssues: [HealthIssue]
    @State private var showsResourceConsumers = false

    private var workloads: [RemoteWorkloadMetric] { sample?.remoteWorkloads ?? [] }
    private var resourceControls: [WorkloadResourceControlMetric] {
        sample?.workloadResourceControls ?? []
    }

    private var standaloneResourceControls: [WorkloadResourceControlMetric] {
        let workloadUnits = Set(workloads.compactMap(\.systemdUnit))
        return resourceControls.filter { control in
            guard let unit = control.systemdUnit else { return true }
            return !workloadUnits.contains(unit)
        }
    }

    private var displayedStandaloneResourceControls: [WorkloadResourceControlMetric] {
        Array(standaloneResourceControls.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Workloads", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if sample != nil {
                    Text(countLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)

            if sample == nil {
                Label("Collecting the first workload inventory…", systemImage: "hourglass")
                    .emptyStateBox()
            } else if workloads.isEmpty && resourceControls.isEmpty {
                Text("No bounded application workloads were found in the latest sample.")
                    .emptyStateBox()
            } else {
                ForEach(workloads) { workload in
                    RemoteWorkloadCard(
                        device: device,
                        workload: workload,
                        resourceControl: resourceControls.first { $0.systemdUnit == workload.systemdUnit },
                        healthIssue: healthIssue(
                            for: resourceControls.first { $0.systemdUnit == workload.systemdUnit }
                        )
                    )
                }
                if !standaloneResourceControls.isEmpty {
                    DisclosureGroup(isExpanded: $showsResourceConsumers) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(displayedStandaloneResourceControls) { control in
                                StandaloneResourceControlCard(
                                    control: control,
                                    healthIssue: healthIssue(for: control)
                                )
                            }
                            if standaloneResourceControls.count > displayedStandaloneResourceControls.count {
                                Text(
                                    "\(standaloneResourceControls.count - displayedStandaloneResourceControls.count) more records are available in Copy diagnostic."
                                )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Label("Other resource consumers", systemImage: "gauge.with.dots.needle.33percent")
                            Spacer()
                            Text("\(standaloneResourceControls.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .onAppear {
            if standaloneResourceControls.contains(where: { healthIssue(for: $0) != nil }) {
                showsResourceConsumers = true
            }
        }
        .onChange(of: standaloneFindingIDs) { _, findingIDs in
            if !findingIDs.isEmpty { showsResourceConsumers = true }
        }
    }

    private var standaloneFindingIDs: [String] {
        standaloneResourceControls.compactMap { healthIssue(for: $0)?.id }
    }

    private var countLabel: String {
        guard !standaloneResourceControls.isEmpty else { return "\(workloads.count) observed" }
        return "\(workloads.count) workloads · \(standaloneResourceControls.count) other"
    }

    private func healthIssue(for control: WorkloadResourceControlMetric?) -> HealthIssue? {
        guard let control else { return nil }
        return
            healthIssues
            .filter { $0.workload?.id == control.id }
            .sorted {
                if $0.state != $1.state { return $0.state > $1.state }
                return $0.title < $1.title
            }
            .first
    }
}

private struct RemoteWorkloadCard: View {
    let device: MachineDevice
    let workload: RemoteWorkloadMetric
    let resourceControl: WorkloadResourceControlMetric?
    let healthIssue: HealthIssue?
    @State private var isExpanded: Bool
    @State private var showsTechnicalDetails = false

    private var browserURL: URL? { workload.browserURL(for: device) }

    init(
        device: MachineDevice,
        workload: RemoteWorkloadMetric,
        resourceControl: WorkloadResourceControlMetric?,
        healthIssue: HealthIssue?
    ) {
        self.device = device
        self.workload = workload
        self.resourceControl = resourceControl
        self.healthIssue = healthIssue
        _isExpanded = State(initialValue: healthIssue != nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(workload.listeners) { listener in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(listener.displayAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(listener.binding.displayName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let healthIssue {
                    Divider()
                    WorkloadFindingSummary(issue: healthIssue)
                }

                if let resourceControl {
                    Divider()
                    WorkloadResourceSummary(control: resourceControl)
                    DisclosureGroup(isExpanded: $showsTechnicalDetails) {
                        WorkloadResourceControlDetails(control: resourceControl)
                            .padding(.top, 4)
                    } label: {
                        Text("Technical resource details")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if primaryCopyValue != nil {
                    HStack(spacing: 7) {
                        if let browserURL {
                            Button("Open") { NSWorkspace.shared.open(browserURL) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        CopyButton(title: browserURL == nil ? "Copy address" : "Copy URL", action: copyPrimaryValue)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                    systemName: workload.listeners.contains(where: { $0.webProtocol != nil }) ? "globe" : "gearshape.2"
                )
                .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workload.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let compactDetailLine {
                        Text(compactDetailLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let healthIssue {
                    HealthBadge(state: healthIssue.state)
                } else {
                    Text(stateLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(workload.state == .active ? .secondary : stateColor)
                }
            }
        }
        .padding(10)
        .cardChrome(tint: stateColor)
        .onChange(of: healthIssue?.id) { _, issueID in
            if issueID != nil { isExpanded = true }
        }
    }

    private var compactDetailLine: String? {
        if let first = workload.listeners.first {
            return "\(first.displayAddress) · \(first.binding.displayName)"
        }
        return detailLine
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let processName = workload.processName, processName != workload.name {
            parts.append(processName)
        }
        if let uptimeSeconds = workload.uptimeSeconds {
            parts.append("Running for \(MetricFormat.duration(uptimeSeconds))")
        } else if let substate = workload.substate {
            parts.append(substate.capitalized)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stateLabel: String {
        switch workload.state {
        case .active: "Running"
        case .inactive: "Inactive"
        case .failed: "Failed"
        case .missing: "Missing"
        }
    }

    private var stateColor: Color {
        if let healthIssue { return healthIssue.state.color }
        return switch workload.state {
        case .active: .green
        case .inactive: .secondary
        case .failed: .red
        case .missing: .orange
        }
    }

    private var primaryCopyValue: String? {
        browserURL?.absoluteString ?? workload.listeners.first?.displayAddress
    }

    private func copyPrimaryValue() -> Bool {
        guard let primaryCopyValue else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(primaryCopyValue, forType: .string)
        return true
    }
}

private struct StandaloneResourceControlCard: View {
    let control: WorkloadResourceControlMetric
    let healthIssue: HealthIssue?
    @State private var isExpanded: Bool
    @State private var showsTechnicalDetails = false

    init(control: WorkloadResourceControlMetric, healthIssue: HealthIssue?) {
        self.control = control
        self.healthIssue = healthIssue
        _isExpanded = State(initialValue: healthIssue != nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if let healthIssue {
                    WorkloadFindingSummary(issue: healthIssue)
                    Divider()
                }
                WorkloadResourceSummary(control: control)
                DisclosureGroup(isExpanded: $showsTechnicalDetails) {
                    WorkloadResourceControlDetails(control: control)
                        .padding(.top, 4)
                } label: {
                    Text("Technical resource details")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(healthIssue?.state.color ?? .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(resourceConsumerSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let healthIssue {
                    HealthBadge(state: healthIssue.state)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if let healthIssue {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(healthIssue.state.color.opacity(0.22), lineWidth: 1)
            }
        }
        .onChange(of: healthIssue?.id) { _, issueID in
            if issueID != nil { isExpanded = true }
        }
    }

    private var resourceConsumerSummary: String {
        guard control.memoryCurrentBytes.availability == .available,
            let bytes = control.memoryCurrentBytes.value
        else {
            return control.systemdUnit ?? "Resource usage unavailable"
        }
        return "Memory \(SizeFormat.bytes(bytes))"
    }
}

private struct WorkloadResourceSummary: View {
    let control: WorkloadResourceControlMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Limits & usage", systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if control.availability == .available {
                Text(memorySummary)
                if let cpuSummary { Text(cpuSummary) }
                if let taskSummary { Text(taskSummary) }
            } else {
                Text(
                    control.availability == .unsupported
                        ? "Resource limits are unsupported on this host."
                        : "Resource usage is unavailable for this workload."
                )
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var memorySummary: String {
        "Memory \(bytes(control.memoryCurrentBytes)) current · max \(limit(control.memoryMax, bytes: true))"
    }

    private var cpuSummary: String? {
        control.cpuQuota.state == .configured
            ? "CPU quota \(ResourceFormat.cpuQuota(control.cpuQuota, withPeriod: false))" : nil
    }

    private var taskSummary: String? {
        guard control.tasksCurrent.availability == .available,
            let current = control.tasksCurrent.value,
            control.tasksMax.state == .configured,
            let maximum = control.tasksMax.value
        else { return nil }
        return "Tasks \(current.formatted()) of \(maximum.formatted())"
    }

    private func bytes(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.bytes(metric) }

    private func limit(_ metric: WorkloadResourceLimitMetric, bytes: Bool) -> String {
        ResourceFormat.limit(metric, bytes: bytes)
    }
}

private struct WorkloadFindingSummary: View {
    let issue: HealthIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Workload finding", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(issue.state.color)
            Text(issue.title)
                .font(.caption.weight(.semibold))
            Text(issue.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WorkloadResourceControlDetails: View {
    let control: WorkloadResourceControlMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if control.availability == .available {
                resourceLine(memoryDescription)
                resourceLine(cpuDescription)
                resourceLine(ioAndTasksDescription)
                if let eventDescription {
                    resourceLine(eventDescription)
                }
            } else {
                resourceLine(
                    control.availability == .unsupported
                        ? "cgroup v2 resource controls are unsupported."
                        : "Resource-control data is unavailable for this workload."
                )
            }

            if let cgroupPath = control.cgroupPath {
                Text(cgroupPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .help(
            "Limits are configuration context. Weights are relative priorities. Only new harmful pressure, throttling, exhaustion, or hard-limit evidence can create an alert."
        )
    }

    private func resourceLine(_ value: String) -> some View {
        Text(value)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var memoryDescription: String {
        "Memory \(bytes(control.memoryCurrentBytes)) current · \(bytes(control.memoryPeakBytes)) peak · high \(limit(control.memoryHigh, bytes: true)) · max \(limit(control.memoryMax, bytes: true))"
    }

    private var cpuDescription: String {
        let throttled = count(control.cpuStat.throttledPeriods)
        let duration = microseconds(control.cpuStat.throttledMicroseconds)
        return
            "CPU quota \(quota(control.cpuQuota)) · weight \(count(control.cpuWeight)) · throttled \(throttled) / \(duration)"
    }

    private var ioAndTasksDescription: String {
        let pressure: String
        if control.ioPressure.availability == .available,
            let some = control.ioPressure.someAverage10,
            let full = control.ioPressure.fullAverage10
        {
            pressure = String(format: "%.1f%% / %.1f%% wait", some, full)
        } else {
            pressure = control.ioPressure.availability.rawValue
        }
        return
            "I/O weight \(count(control.ioWeight)) · \(pressure) · tasks \(count(control.tasksCurrent)) / \(limit(control.tasksMax, bytes: false))"
    }

    private var eventDescription: String? {
        let values = [
            control.memoryEvents.high.value,
            control.memoryEvents.max.value,
            control.memoryEvents.oom.value,
            control.memoryEvents.oomKill.value,
        ]
        guard values.contains(where: { ($0 ?? 0) > 0 }) else { return nil }
        return
            "Memory events high \(count(control.memoryEvents.high)) · max \(count(control.memoryEvents.max)) · OOM \(count(control.memoryEvents.oom)) · killed \(count(control.memoryEvents.oomKill))"
    }

    private func bytes(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.bytes(metric) }

    private func count(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.count(metric) }

    private func limit(_ metric: WorkloadResourceLimitMetric, bytes: Bool) -> String {
        ResourceFormat.limit(metric, bytes: bytes)
    }

    private func quota(_ metric: WorkloadCPUQuotaMetric) -> String {
        ResourceFormat.cpuQuota(metric, withPeriod: false)
    }

    private func microseconds(_ metric: WorkloadResourceValueMetric) -> String { ResourceFormat.duration(metric) }
}

private extension WorkloadListenerBinding {
    var displayName: String {
        switch self {
        case .loopback: "Loopback only"
        case .tailnet: "Tailnet"
        case .publicAddress: "Public address"
        case .privateNetwork: "Private network"
        case .allInterfaces: "All interfaces"
        case .unknown: "Unknown binding"
        }
    }
}
