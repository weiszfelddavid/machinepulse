import MachinePulseCore
import ServiceManagement
import SwiftUI

@main
struct MachinePulseApp: App {
    @State private var model = AppModel()

    init() {
        if ProcessInfo.processInfo.environment["MACHINEPULSE_UNREGISTER_LOGIN_ITEM"] == "1" {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PulsePopover(model: model)
                #if DEBUG
                    .preferredColorScheme(previewColorScheme)
                    .environment(\.dynamicTypeSize, previewDynamicTypeSize)
                #endif
        } label: {
            MenuBarStatusIcon(
                state: model.aggregateState,
                reduceMotionOverride: previewReduceMotionOverride
            )
            .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    #if DEBUG
        private var previewColorScheme: ColorScheme? {
            switch ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_APPEARANCE"] {
            case "light": .light
            case "dark": .dark
            default: nil
            }
        }

        private var previewDynamicTypeSize: DynamicTypeSize {
            ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_LARGE_TEXT"] == "1"
                ? .accessibility1
                : .large
        }

        private var previewReduceMotionOverride: Bool? {
            ProcessInfo.processInfo.environment["MACHINEPULSE_PREVIEW_REDUCE_MOTION"] == "1" ? true : nil
        }
    #else
        private var previewReduceMotionOverride: Bool? { nil }
    #endif
}

private struct MenuBarStatusIcon: View {
    let state: HealthState
    let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var badgeFrames: [NSImage] = []
    @State private var badgeFrameIndex = 0

    private var needsAttention: Bool { state != .healthy }
    private var motionIsReduced: Bool { reduceMotionOverride ?? reduceMotion }
    private var animationKey: String {
        "\(state.rawValue)-\(motionIsReduced)-\(colorScheme == .dark)-\(displayScale)"
    }

    private var badgeColor: Color? {
        switch state {
        case .healthy: nil
        case .warning: .orange
        case .unreachable, .critical: .red
        }
    }

    var body: some View {
        Image(nsImage: displayedImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("MachinePulse — \(state.title)")
            .help("MachinePulse — \(state.title)")
            .task(id: animationKey) { await runBadgeAnimation() }
    }

    private func runBadgeAnimation() async {
        badgeFrames = renderedFrames
        badgeFrameIndex = 0
        guard needsAttention, !motionIsReduced, badgeFrames.count > 1 else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(67))
            } catch {
                return
            }
            badgeFrameIndex = (badgeFrameIndex + 1) % badgeFrames.count
        }
    }

    private var displayedImage: NSImage {
        guard badgeFrames.indices.contains(badgeFrameIndex) else {
            return renderImage(badgePulse: 1)
        }
        return badgeFrames[badgeFrameIndex]
    }

    private var renderedFrames: [NSImage] {
        guard needsAttention, !motionIsReduced else { return [renderImage(badgePulse: 1)] }
        return (0..<30).map { frameIndex in
            let phase = (2 * Double.pi * Double(frameIndex)) / 30
            return renderImage(badgePulse: (cos(phase) + 1) / 2)
        }
    }

    private func renderImage(badgePulse: Double) -> NSImage {
        let artwork = MenuBarStatusArtwork(badgeColor: badgeColor, badgePulse: badgePulse)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = displayScale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 24, height: 18))
        image.isTemplate = false
        return image
    }
}

private struct MenuBarStatusArtwork: View {
    let badgeColor: Color?
    let badgePulse: Double

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 17, height: 18)
            if let badgeColor {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                    .scaleEffect(0.86 + (0.14 * badgePulse))
                    .opacity(0.72 + (0.28 * badgePulse))
                    .padding(.top, 1)
            }
        }
        .frame(width: 24, height: 18, alignment: .leading)
    }
}
