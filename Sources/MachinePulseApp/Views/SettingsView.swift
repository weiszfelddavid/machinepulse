import MachinePulseCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            machines
                .tabItem { Label("Machines", systemImage: "server.rack") }
            thresholds
                .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }
            localControls
                .tabItem { Label("Local Controls", systemImage: "display") }
        }
        .frame(width: 620, height: 470)
        .padding(16)
    }

    private var general: some View {
        Form {
            Section("Behavior") {
                Toggle(
                    "Launch MachinePulse at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                if let loginItemError = model.loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                }
                Toggle(
                    "Notify me when machine health changes",
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotificationsEnabled($0) }
                    ))
                LabeledContent("Refresh interval", value: "10 seconds")
                LabeledContent("Failure retry backoff", value: "Up to 60 seconds")
            }
            Section("History") {
                LabeledContent("Detailed metrics", value: "\(MetricsStore.sampleRetentionDays) days")
                LabeledContent(
                    "Hourly capacity summaries",
                    value: "\(MetricsStore.capacityRollupRetentionDays) days"
                )
                LabeledContent(
                    "Capacity-summary budget",
                    value: "64 MiB"
                )
                LabeledContent("Incidents", value: "\(MetricsStore.incidentRetentionDays) days")
                LabeledContent("Storage") {
                    Text("~/Library/Application Support/MachinePulse/machinepulse.sqlite3")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let storageError = model.storageError {
                    Text(storageError).foregroundStyle(.red)
                }
            }
            Section("Access") {
                Text(
                    "MachinePulse uses your Mac’s Tailscale connection and existing SSH configuration. It stores no passwords, private keys, or app accounts."
                )
                .foregroundStyle(.secondary)
            }
            Section("Project") {
                Button {
                    model.open(AppModel.repositoryURL)
                } label: {
                    Label("View source on GitHub…", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button {
                    model.open(AppModel.issueFormURL)
                } label: {
                    Label("Report an issue…", systemImage: "exclamationmark.bubble")
                }
                LabeledContent("Made by") {
                    Button("@weiszfeld on X ↗") { model.open(AppModel.creatorProfileURL) }
                }
                Text(
                    "MachinePulse is distributed as source. Pull the repository and rebuild to update this installation. Review copied diagnostics before attaching them to an issue."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailnet machines").font(.headline)
                    Text("Only enabled machines affect the menu-bar health indicator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Label("Discover", systemImage: "arrow.clockwise")
                }
            }
            List(model.devices) { device in
                MachineSettingRow(model: model, device: device)
            }
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView(
                        "No machines discovered",
                        systemImage: "network.slash",
                        description: Text(model.discoveryError ?? "Connect Tailscale, then try again.")
                    )
                }
            }
        }
        .padding()
    }

    private var thresholds: some View {
        Form {
            Section {
                Picker(
                    "Sensitivity",
                    selection: Binding(
                        get: { model.thresholdPreset },
                        set: { model.setThresholdPreset($0) }
                    )
                ) {
                    Text("Quiet").tag(HealthSensitivityPreset.quiet)
                    Text("Balanced").tag(HealthSensitivityPreset.balanced)
                    Text("Sensitive").tag(HealthSensitivityPreset.sensitive)
                    if model.thresholdPreset == .custom {
                        Text("Custom").tag(HealthSensitivityPreset.custom)
                    }
                }
                .pickerStyle(.segmented)
                Text(sensitivityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Alert sensitivity")
            } footer: {
                Text(
                    "Balanced uses the recommended defaults. Editing an advanced value switches to Custom. Changes apply to the next sample."
                )
            }

            Section {
                ThresholdField(
                    title: "CPU warning",
                    value: Binding(
                        get: { model.thresholds.cpuWarningPercent },
                        set: { model.updateThreshold(\.cpuWarningPercent, value: $0) }
                    ),
                    range: 1...100
                )
                ThresholdField(
                    title: "CPU critical",
                    value: Binding(
                        get: { model.thresholds.cpuCriticalPercent },
                        set: { model.updateThreshold(\.cpuCriticalPercent, value: $0) }
                    ),
                    range: 1...100
                )
                ThresholdField(
                    title: "Linux RAM warning",
                    value: Binding(
                        get: { model.thresholds.memoryWarningFraction * 100 },
                        set: { model.updateThreshold(\.memoryWarningFraction, value: $0 / 100) }
                    ),
                    range: 1...100
                )
                ThresholdField(
                    title: "Linux RAM critical",
                    value: Binding(
                        get: { model.thresholds.memoryCriticalFraction * 100 },
                        set: { model.updateThreshold(\.memoryCriticalFraction, value: $0 / 100) }
                    ),
                    range: 1...100
                )
                ThresholdField(
                    title: "Disk warning",
                    value: Binding(
                        get: { model.thresholds.diskWarningFraction * 100 },
                        set: { model.updateThreshold(\.diskWarningFraction, value: $0 / 100) }
                    ),
                    range: 1...100
                )
                ThresholdField(
                    title: "Disk critical",
                    value: Binding(
                        get: { model.thresholds.diskCriticalFraction * 100 },
                        set: { model.updateThreshold(\.diskCriticalFraction, value: $0 / 100) }
                    ),
                    range: 1...100
                )
            } header: {
                Text("Advanced thresholds")
            } footer: {
                Text(
                    "Mac memory pressure, swap activity, failed-service, and OOM rules are automatically managed."
                )
            }
            HStack {
                Spacer()
                Button("Restore smart defaults") { model.setThresholdPreset(.balanced) }
            }
        }
        .formStyle(.grouped)
    }

    private var localControls: some View {
        Form {
            Section {
                Toggle(
                    "Show local display controls in MachinePulse",
                    isOn: Binding(
                        get: { model.localDisplayControls.preferences.showsControls },
                        set: { model.localDisplayControls.setControlsShown($0) }
                    )
                )
            } footer: {
                Text(
                    "Off by default. This local-only module is separate from machine health and never controls remote devices."
                )
            }

            if model.localDisplayControls.preferences.showsControls {
                Section("XDR safety") {
                    Picker(
                        "Auto-off",
                        selection: Binding(
                            get: { model.localDisplayControls.preferences.timeoutMinutes },
                            set: { model.localDisplayControls.setTimeoutMinutes($0) }
                        )
                    ) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                        Text("120 minutes").tag(120)
                    }
                    Toggle(
                        "Allow XDR Boost on battery",
                        isOn: Binding(
                            get: { model.localDisplayControls.preferences.allowsBoostOnBattery },
                            set: { model.localDisplayControls.setAllowsBoostOnBattery($0) }
                        )
                    )
                    Toggle(
                        "Restore after sleep or lid close",
                        isOn: Binding(
                            get: { model.localDisplayControls.preferences.restoresAfterSleep },
                            set: { model.localDisplayControls.setRestoresAfterSleep($0) }
                        )
                    )
                    if model.localDisplayControls.displayStates.contains(where: \.isBoostActive) {
                        Button("Turn off all XDR Boosts", role: .destructive) {
                            model.localDisplayControls.turnOffAllBoosts()
                        }
                    }
                }

                Section("Compatibility") {
                    Text(
                        "Brightness is managed by macOS; use Displays Settings to change it. MachinePulse does not use private brightness APIs or DDC."
                    )
                    Text(
                        "XDR Boost is experimental, capped at 2×, and limited by macOS, battery, and thermal conditions. Turn it off before screenshots or recordings because captures can include the overlay."
                    )
                    Text("An active boost is never restored after quitting or relaunching MachinePulse.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var sensitivityDescription: String {
        switch model.thresholdPreset {
        case .quiet:
            "Fewer alerts: CPU 85/97%, Linux RAM and disk 88/97%, swap 65%, pressure 12/35%."
        case .balanced:
            "Recommended: CPU 75/92%, Linux RAM and disk 80/93%, swap 50%, pressure 8/25%."
        case .sensitive:
            "Earlier alerts: CPU 65/85%, Linux RAM and disk 72/88%, swap 40%, pressure 5/18%."
        case .custom:
            "Custom thresholds are active. Warning values always remain below critical values."
        }
    }
}

private struct MachineSettingRow: View {
    @Bindable var model: AppModel
    let device: MachineDevice

    private var preference: DevicePreference {
        model.preferences[device.id] ?? DevicePreference()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: device.platform.symbolName)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text(device.name)
                    Text("\(device.platform.displayName) · \(device.isOnline ? "Online" : "Offline")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Monitor",
                    isOn: Binding(
                        get: { preference.isEnabled },
                        set: { model.setEnabled($0, for: device) }
                    )
                )
                .toggleStyle(.switch)
            }

            if preference.isEnabled {
                HStack {
                    Text("Monitoring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Monitoring",
                        selection: Binding(
                            get: { preference.mode },
                            set: { model.setMode($0, for: device) }
                        )
                    ) {
                        Text("Presence").tag(MonitoringMode.presence)
                        if model.supportsDeepMonitoring(device) {
                            Text("Full metrics").tag(MonitoringMode.deep)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    Spacer()
                }
                if preference.mode == .deep, device.collectsOverSSH {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("SSH target")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(
                                "Host alias or address",
                                text: Binding(
                                    get: { preference.sshTarget ?? "" },
                                    set: { model.setSSHTarget($0, for: device) }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            Text("Uses system SSH")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if device.platform == .linux {
                            ExpectedUnitsEditor(units: preference.expectedUnits) { units in
                                model.setExpectedUnits(units, for: device)
                            }
                        }
                    }
                    .padding(.leading, 32)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ExpectedUnitsEditor: View {
    let units: [ExpectedSystemdUnit]
    let onSave: ([ExpectedSystemdUnit]) -> Void
    @State private var draft: String
    @State private var validationMessage: String?

    init(units: [ExpectedSystemdUnit], onSave: @escaping ([ExpectedSystemdUnit]) -> Void) {
        self.units = units
        self.onSave = onSave
        _draft = State(initialValue: units.map(\.name).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Expected units")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("example.service, backup.timer", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
            }
            Text(
                "Optional and read-only. Up to \(ExpectedSystemdUnit.maxWatchlistCount) explicit .service or .timer names."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: units) { _, newValue in
            let persisted = newValue.map(\.name).joined(separator: ", ")
            if validationMessage == nil { draft = persisted }
        }
    }

    private func save() {
        let names = draft.split { character in
            character == "," || character == "\n" || character == " " || character == "\t"
        }.map(String.init)
        guard names.count <= ExpectedSystemdUnit.maxWatchlistCount else {
            validationMessage = "Keep the watchlist to 12 units or fewer."
            return
        }
        var parsed: [ExpectedSystemdUnit] = []
        var seen = Set<String>()
        for name in names {
            guard let unit = ExpectedSystemdUnit(name: name) else {
                validationMessage = "Use complete systemd names ending in .service or .timer."
                return
            }
            if seen.insert(unit.name).inserted { parsed.append(unit) }
        }
        validationMessage = nil
        draft = parsed.map(\.name).joined(separator: ", ")
        onSave(parsed)
    }
}

private struct ThresholdField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: 1)
                    .frame(width: 210)
                Text("\(Int(value))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}
