import MachinePulseCore
import SwiftUI

struct LocalDisplayControlsSection: View {
    @Bindable var controller: SystemLocalDisplayController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Display")
                    .font(.headline)
                Spacer()
                if controller.displayStates.contains(where: \.isBoostActive) {
                    Button("Turn off XDR Boost") { controller.turnOffAllBoosts() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if controller.displayStates.isEmpty {
                Text("No local displays are currently available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.displayStates) { state in
                    LocalDisplayRow(controller: controller, state: state)
                    if state.id != controller.displayStates.last?.id { Divider() }
                }
            }

            if let error = controller.controllerError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                CopyButton(title: "Copy XDR diagnostic", copiedTitle: "XDR diagnostic copied") {
                    controller.copyXDRDiagnostic()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Copies bounded overlay lifecycle data without screen content")
            }
        }
    }
}

private struct LocalDisplayRow: View {
    @Bindable var controller: SystemLocalDisplayController
    let state: LocalDisplayControlState

    private var display: LocalDisplayDescriptor { state.display }
    private var unavailableReason: XDRStopReason? {
        LocalDisplaySessionManager.unavailableReason(
            for: display,
            preferences: controller.preferences,
            environment: controller.environment
        )
    }

    var body: some View {
        if display.supportsXDR {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    displayIcon
                    Text(display.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("XDR available")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                brightnessStage
                xdrStage
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                displayIcon
                Text(display.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("Standard display · XDR Boost not available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var displayIcon: some View {
        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private var brightnessStage: some View {
        HStack {
            Text("Brightness")
                .font(.caption)
            Spacer()
            Button("Open Displays Settings…") { controller.openDisplaysSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var xdrStage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("XDR Boost")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let session = state.session {
                    Text("Active · auto-off \(session.expiresAt.formatted(.relative(presentation: .numeric)))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("Inactive")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Boost level")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { state.session?.requestedMultiplier ?? 1.0 },
                        set: { controller.setBoostLevel($0, for: display.id) }
                    ),
                    in: 1.0...display.maximumProductBoost,
                    step: 0.05
                )
                .disabled(!state.isBoostActive && unavailableReason != nil)
                .accessibilityLabel("XDR boost level for \(display.name)")
                .accessibilityValue(
                    state.session.map {
                        $0.requestedMultiplier.formatted(.percent.precision(.fractionLength(0)))
                    } ?? "Inactive"
                )
                .accessibilityHint("Minimum is off; dragging above the minimum turns the boost on at that level.")
                Text(
                    state.session?.requestedMultiplier ?? 1.0,
                    format: .percent.precision(.fractionLength(0))
                )
                .font(.caption.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
            }

            if state.session == nil, let reason = unavailableReason ?? actionableStopReason {
                Text(reason.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(
                "Experimental: turn boost off before screenshots or screen recordings; captures can include the overlay."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionableStopReason: XDRStopReason? {
        switch state.lastStopReason {
        case .batteryPolicy, .thermalProtection, .currentHeadroomUnavailable, .timeout, .sleep, .inactiveSession:
            state.lastStopReason
        case .displayRemoved, .featureDisabled, .unsupportedDisplay, .user, nil:
            nil
        }
    }
}
