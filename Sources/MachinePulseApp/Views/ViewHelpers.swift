import MachinePulseCore
import SwiftUI

extension HealthState {
    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .unreachable: .secondary
        case .critical: .red
        }
    }
}

extension DevicePlatform {
    var displayName: String {
        switch self {
        case .linux: "Linux"
        case .macOS: "Mac"
        case .iOS: "iPhone / iPad"
        case .android: "Android"
        case .windows: "Windows"
        case .unknown: "Device"
        }
    }

    var symbolName: String {
        switch self {
        case .linux: "server.rack"
        case .macOS: "laptopcomputer"
        case .iOS: "iphone"
        case .android: "smartphone"
        case .windows: "desktopcomputer"
        case .unknown: "network"
        }
    }
}

extension MachineSectionFilter {
    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .vitals: "waveform.path.ecg"
        case .displays: "display"
        case .workloads: "network"
        case .storage: "internaldrive"
        }
    }
}

enum MetricFormat {
    static func bytes(_ value: UInt64) -> String { SizeFormat.bytes(value) }

    static func signedBytes(_ value: Int64) -> String {
        let magnitude = value == .min ? UInt64(Int64.max) + 1 : UInt64(abs(value))
        return "\(value < 0 ? "−" : "+")\(bytes(magnitude))"
    }

    static func rate(_ value: Double) -> String { SizeFormat.rate(value) }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let bounded = max(0, seconds)
        if bounded < 60 { return "\(Int(bounded.rounded()))s" }
        if bounded < 60 * 60 { return "\(Int((bounded / 60).rounded()))m" }
        if bounded < 24 * 60 * 60 {
            let hours = Int(bounded / (60 * 60))
            let minutes = Int((bounded.truncatingRemainder(dividingBy: 60 * 60)) / 60)
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        let days = Int(bounded / (24 * 60 * 60))
        let hours = Int((bounded.truncatingRemainder(dividingBy: 24 * 60 * 60)) / (60 * 60))
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    static func incidentMeasurement(_ value: Double, kind: HealthIssueKind) -> String {
        switch kind {
        case .memory, .swap, .diskCapacity: percent(value * 100)
        case .diskPressure, .memoryPressure: "\(percent(value)) stall time"
        default: percent(value)
        }
    }
}

enum RelativeTime {
    static func phrase(since date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if abs(interval) < 5 { return "just now" }
        return date.formatted(.relative(presentation: .numeric))
    }
}

func networkLine(receive: Double, transmit: Double) -> Text {
    Text("Network ↓ \(MetricFormat.rate(receive)) · ↑ \(MetricFormat.rate(transmit))")
}

struct HealthBadge: View {
    let state: HealthState

    var body: some View {
        Text(state.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.12), in: Capsule())
    }
}

struct MetricBar: View {
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(MetricFormat.percent(value))
                    .monospacedDigit()
            }
            .font(.caption2)
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(tint)
        }
    }
}

/// A button that writes something to the pasteboard and says "Copied" for
/// two seconds. The action returns false when there was nothing to copy.
struct CopyButton: View {
    let title: String
    var copiedTitle = "Copied"
    var systemImage: String? = "doc.on.doc"
    let action: () -> Bool
    @State private var copied = false

    var body: some View {
        Button {
            guard action() else { return }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            if let systemImage {
                Label(copied ? copiedTitle : title, systemImage: copied ? "checkmark" : systemImage)
            } else {
                Text(copied ? copiedTitle : title)
            }
        }
    }
}

struct CountedDisclosureLabel: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
    }
}

extension View {
    func cardChrome(tint: Color, strength: Double = 0.22) -> some View {
        background(.background.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(tint.opacity(strength), lineWidth: 1)
            }
    }

    func emptyStateBox() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    func warningBox() -> some View {
        font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
