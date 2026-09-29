import AppKit
import MachinePulseCore
import SwiftUI

struct PulsePopover: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var selectedSection: MachineSectionFilter = .overview
    @State private var expansionState = MachineCardExpansionState()

    init(model: AppModel) {
        self.model = model
        #if DEBUG
            if let previewSection = ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_SECTION"]
                .flatMap(MachineSectionFilter.init(rawValue:))
            {
                _selectedSection = State(initialValue: previewSection)
            }
            if model.previewScenarioName != nil {
                _expansionState = State(
                    initialValue: MachineCardExpansionState(expandedDeviceIDs: Set(model.devices.map(\.id))))
            }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error = model.discoveryError {
                        InlineMessage(
                            symbol: "network.slash",
                            title: "Tailnet unavailable",
                            detail: error,
                            color: .orange
                        )
                    } else if model.devices.isEmpty {
                        InlineMessage(
                            symbol: "hourglass",
                            title: "Looking for machines",
                            detail: "MachinePulse is waiting for Tailscale discovery.",
                            color: .secondary
                        )
                    }
                    if model.enabledDevices.isEmpty,
                        selectedSection == .overview || selectedSection == .vitals
                    {
                        onboarding
                    }
                    if visibleDevices.isEmpty, !model.devices.isEmpty {
                        emptyFilterState
                    }
                    ForEach(visibleDevices) { device in
                        DeviceCard(
                            model: model,
                            device: device,
                            selectedSection: $selectedSection,
                            isExpanded: expansionBinding(for: device)
                        )
                    }
                }
                .padding(12)
            }
            // Legacy (inset) scroll bars would shrink every card exactly when
            // expansion makes the content overflow; hiding the indicator keeps
            // collapsed and expanded cards the same width.
            .scrollIndicators(.hidden)
            Divider()
            footer
        }
        .frame(width: 400, height: panelHeight)
        .background(.regularMaterial)
        .animation(reduceMotion ? nil : .snappy, value: panelHeight)
        .onAppear {
            reconcileExpansionState()
            Task { await model.refreshNow() }
        }
        .onChange(of: model.devices.map(\.id)) { _, _ in reconcileExpansionState() }
        .onChange(of: activeIncidentIDs) { _, _ in reconcileExpansionState() }
        .onChange(of: selectedSection) { _, _ in reconcileExpansionState() }
    }

    private var panelHeight: CGFloat {
        if expansionState.expandedDeviceIDs.isEmpty { return min(560, availablePanelHeight) }
        switch selectedSection {
        case .overview:
            return min(760, availablePanelHeight)
        case .vitals:
            return min(880, availablePanelHeight)
        case .displays:
            return min(680, availablePanelHeight)
        case .workloads:
            return min(700, availablePanelHeight)
        case .storage:
            return min(860, availablePanelHeight)
        }
    }

    private var availablePanelHeight: CGFloat {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        return max(320, (screen?.visibleFrame.height ?? 720) - 20)
    }

    private var activeIncidentIDs: [String: UUID] {
        Dictionary(
            uniqueKeysWithValues: model.enabledDevices.compactMap { device in
                model.activeIncidents(for: device.id).first.map { (device.id, $0.id) }
            })
    }

    private func reconcileExpansionState() {
        expansionState.reconcile(deviceIDs: Set(model.devices.map(\.id)), activeIncidentIDs: activeIncidentIDs)
    }

    private func expansionBinding(for device: MachineDevice) -> Binding<Bool> {
        Binding(
            get: { expansionState.isExpanded(device.id) },
            set: { expanded in
                expansionState.setExpanded(
                    expanded,
                    deviceID: device.id,
                    activeIncidentID: activeIncidentIDs[device.id]
                )
            }
        )
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(model.aggregateState.color.opacity(0.15))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(model.aggregateState.color)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MachinePulse")
                        .font(.headline)
                    Text(model.aggregateSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing machine status")
                } else {
                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }
            }

            Picker("Machine section", selection: $selectedSection) {
                ForEach(MachineSectionFilter.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityLabel("Show \(section.title)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Machine sections")
            .accessibilityValue(selectedSection.title)
        }
        .padding(12)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Choose what matters", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
            Text(
                model.devices.isEmpty
                    ? "Connect Tailscale to discover machines, then choose which ones affect health."
                    : "Enable a machine below. Presence checks or full metrics use your existing system access."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        switch selectedSection {
        case .displays:
            InlineMessage(
                symbol: "display",
                title: "No monitored displays",
                detail: "Enable This Mac in Overview to view its display controls.",
                color: .secondary
            )
        case .workloads:
            InlineMessage(
                symbol: "network",
                title: "No monitored workloads",
                detail: "Enable This Mac or deep monitoring for a Linux machine in Overview.",
                color: .secondary
            )
        case .storage:
            InlineMessage(
                symbol: "internaldrive",
                title: "No scannable machines",
                detail: "Enable This Mac, or full metrics with an SSH target for another machine, in Overview.",
                color: .secondary
            )
        case .overview, .vitals:
            EmptyView()
        }
    }

    private var visibleDevices: [MachineDevice] {
        switch selectedSection {
        case .overview, .vitals:
            sortedDevices
        case .displays:
            sortedDevices.filter {
                $0.isLocal
                    && model.preferences[$0.id]?.isEnabled == true
                    && model.localDisplayControls.preferences.showsControls
            }
        case .workloads:
            sortedDevices.filter { model.preferences[$0.id]?.isEnabled == true && model.supportsWorkloads($0) }
        case .storage:
            sortedDevices.filter {
                model.preferences[$0.id]?.isEnabled == true && model.supportsStorage($0)
            }
        }
    }

    private var visibleExpandableDeviceIDs: [String] {
        visibleDevices.compactMap { device in
            model.preferences[device.id]?.isEnabled == true ? device.id : nil
        }
    }

    private var sortedDevices: [MachineDevice] {
        model.devices.sorted { lhs, rhs in
            let leftGroup = sortGroup(for: lhs)
            let rightGroup = sortGroup(for: rhs)
            if leftGroup != rightGroup { return leftGroup < rightGroup }

            if leftGroup < 2 {
                let leftProblem = latestProblemDate(for: lhs)
                let rightProblem = latestProblemDate(for: rhs)
                if leftProblem != rightProblem {
                    if let leftProblem, let rightProblem { return leftProblem > rightProblem }
                    return leftProblem != nil
                }
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func sortGroup(for device: MachineDevice) -> Int {
        guard let preference = model.preferences[device.id], preference.isEnabled else { return 2 }
        return preference.mode == .deep ? 0 : 1
    }

    private func latestProblemDate(for device: MachineDevice) -> Date? {
        if let report = model.reports[device.id], report.state != .healthy {
            return report.evaluatedAt
        }
        return model.incidents[device.id]?.first?.updatedAt
    }

    private var footer: some View {
        HStack {
            if let lastRefresh = model.lastRefresh {
                Text("Updated \(RelativeTime.phrase(since: lastRefresh))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if hasExpandedVisibleDevice {
                Button("Collapse All") { collapseAllVisibleDevices() }
                    .buttonStyle(.plain)
                    .help("Collapses every machine visible in the \(selectedSection.title) view.")
                    .accessibilityLabel("Collapse All")
            }
            Spacer()
            Button("Settings…") { openSettings() }
                .buttonStyle(.plain)
            Divider().frame(height: 12)
            Button("Quit") {
                model.prepareToQuit()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var hasExpandedVisibleDevice: Bool {
        visibleExpandableDeviceIDs.contains { expansionState.isExpanded($0) }
    }

    private func collapseAllVisibleDevices() {
        withAnimation(reduceMotion ? nil : .snappy) {
            expansionState.setAllExpanded(
                false,
                deviceIDs: visibleExpandableDeviceIDs,
                activeIncidentIDs: activeIncidentIDs
            )
        }
    }
}

private struct InlineMessage: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
