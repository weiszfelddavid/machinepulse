import AppKit
import MachinePulseCore
import SwiftUI

/// The card that rises from the bottom center of every display while an
/// agent waits for you, so the top center stays free for other apps' cards.
@MainActor
final class AgentBubble {
    private var panels: [AgentBubblePanel] = []
    private let visibility = AgentBubbleVisibility()

    /// `attentions` come oldest first; the oldest leads the card and sets its size.
    /// `failures` holds, by attention, why its terminal could not be shown.
    func show(
        _ attentions: [AgentAttention],
        machineNames: [String: String],
        failures: [String: String],
        open: @escaping (AgentAttention) -> Void,
        dismiss: @escaping () -> Void
    ) {
        guard !attentions.isEmpty else { return hide() }
        let screens = NSScreen.screens
        while panels.count < screens.count { panels.append(AgentBubblePanel()) }
        while panels.count > screens.count { panels.removeLast().orderOut(nil) }
        for (panel, screen) in zip(panels, screens) {
            panel.place(
                AgentBubbleView(
                    attentions: attentions,
                    machineNames: machineNames,
                    failures: failures,
                    visibility: visibility,
                    open: open,
                    dismiss: dismiss
                ),
                on: screen
            )
        }
        guard !visibility.isShown else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.35)) { visibility.isShown = true }
    }

    func hide() {
        guard visibility.isShown else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            visibility.isShown = false
        } completion: { [weak self] in
            guard let self, !visibility.isShown else { return }
            panels.forEach { $0.orderOut(nil) }
        }
    }
}

@MainActor
@Observable
private final class AgentBubbleVisibility {
    var isShown = false
}

private final class AgentBubblePanel: NSPanel {
    private let host = FirstMouseHostingView<AgentBubbleView?>(rootView: nil)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    func place(_ view: AgentBubbleView, on screen: NSScreen) {
        host.rootView = view
        let size = host.fittingSize
        let area = screen.visibleFrame
        setFrame(
            NSRect(x: area.midX - size.width / 2, y: area.minY, width: size.width, height: size.height),
            display: true
        )
        orderFrontRegardless()
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AgentBubbleView: View {
    // The card is laid out at its peak size and scaled down, because scaling
    // text up blurs it.
    private static let peak = AgentAttention.bubblePeakScale
    private static let listedOthers = 5

    let attentions: [AgentAttention]
    let machineNames: [String: String]
    let failures: [String: String]
    let visibility: AgentBubbleVisibility
    let open: (AgentAttention) -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var systemScheme
    @State private var isHovered = false

    private var scheme: ColorScheme { systemScheme == .dark ? .light : .dark }
    private var lead: AgentAttention { attentions[0] }

    var body: some View {
        ZStack(alignment: .bottom) {
            card(expanded: true, at: Date()).hidden()
            TimelineView(.periodic(from: lead.session.since, by: 60)) { context in
                let scale = AgentAttention.bubbleScale(waitingFor: context.date.timeIntervalSince(lead.session.since))
                card(expanded: isHovered, at: context.date)
                    .onHover { hovering in withAnimation(.spring(duration: 0.35)) { isHovered = hovering } }
                    .scaleEffect(x: visibility.isShown ? 1 : 0.5, y: visibility.isShown ? 1 : 0.01, anchor: .bottom)
                    .scaleEffect(scale / Self.peak, anchor: .bottom)
                    .animation(.spring(duration: 0.6, bounce: 0.45), value: scale)
            }
        }
        .padding(.bottom, 20)
        .padding([.horizontal, .top], 40)
    }

    private func card(expanded: Bool, at date: Date) -> some View {
        let k = Self.peak
        return VStack(alignment: .leading, spacing: 10 * k) {
            if expanded {
                details(at: date).transition(.opacity)
            }
            content(at: date)
        }
        .opacity(visibility.isShown ? 1 : 0)
        .padding(.horizontal, 18 * k)
        .padding(.vertical, 12 * k)
        .background(
            RoundedRectangle(cornerRadius: 18 * k, style: .continuous)
                .fill(scheme == .dark ? .black : .white)
                .shadow(color: .black.opacity(0.3), radius: 10 * k, y: 3 * k)
        )
        .environment(\.colorScheme, scheme)
        .fixedSize()
    }

    private func content(at date: Date) -> some View {
        let k = Self.peak
        return HStack(spacing: 12 * k) {
            Button {
                open(lead)
            } label: {
                HStack(spacing: 10 * k) {
                    Image(systemName: lead.symbol)
                        .font(.system(size: 20 * k, weight: .semibold))
                        .foregroundStyle(lead.tint)
                    VStack(alignment: .leading, spacing: 2 * k) {
                        Text(lead.title)
                            .font(.system(size: 16 * k, weight: .semibold))
                            .lineLimit(1)
                        if let failure = failures[lead.id] {
                            failureText(failure)
                                .font(.system(size: 13 * k))
                        } else {
                            Text(status(at: date))
                                .font(.system(size: 13 * k))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: 300 * k, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the terminal of this session")

            Button {
                open(lead)
            } label: {
                Text("Open")
                    .font(.system(size: 13 * k, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14 * k)
                    .padding(.vertical, 6 * k)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12 * k, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide until another agent waits")
        }
    }

    private func details(at date: Date) -> some View {
        let k = Self.peak
        let others = attentions.dropFirst()
        return VStack(alignment: .leading, spacing: 6 * k) {
            if let cwd = lead.session.cwd {
                detail("folder") { Text(cwd).lineLimit(1).truncationMode(.head) }
            }
            detail(lead.kind == .needsApproval ? "hand.raised" : "clock") { Text(lead.summary) }
            if !others.isEmpty {
                Divider()
                ForEach(Array(others.prefix(Self.listedOthers))) { attention in
                    Button {
                        open(attention)
                    } label: {
                        detail(attention.symbol, tint: attention.tint) {
                            VStack(alignment: .leading, spacing: 2 * k) {
                                Text("\(place(of: attention)) · \(attention.title)")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let failure = failures[attention.id] {
                                    failureText(failure)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if others.count > Self.listedOthers {
                    Text("+\(others.count - Self.listedOthers) more")
                }
            }
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 13 * k))
        .foregroundStyle(.secondary)
    }

    /// A fixed width, because the card's ideal size measures a wrapping text
    /// on one line under a maximum width.
    private func failureText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300 * Self.peak, alignment: .leading)
    }

    private func detail(_ symbol: String, tint: Color? = nil, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * Self.peak) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 18 * Self.peak)
            text()
        }
    }

    private func status(at date: Date) -> String {
        let interval = date.timeIntervalSince(lead.session.since)
        let waited =
            interval < 60
            ? "just now"
            : "waiting \(Duration.seconds(interval).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"
        let others = attentions.count - 1
        let parts: [String?] = [place(of: lead), waited, others > 0 ? "+\(others) more" : nil]
        return parts.compactMap(\.self)
            .joined(separator: " · ")
    }

    private func place(of attention: AgentAttention) -> String {
        let parts: [String?] = [attention.session.projectName, machineNames[attention.deviceID]]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}

extension AgentAttention {
    fileprivate var title: String {
        switch kind {
        case .finished: "\(session.agent.displayName) finished"
        case .needsApproval: "\(session.agent.displayName) needs approval"
        }
    }

    fileprivate var summary: String {
        switch kind {
        case let .finished(duration):
            "The task took \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))"
        case .needsApproval:
            "Blocked until you answer"
        }
    }

    fileprivate var symbol: String {
        kind == .needsApproval ? "hand.raised.fill" : "checkmark.circle.fill"
    }

    fileprivate var tint: Color {
        kind == .needsApproval ? .orange : .green
    }
}
