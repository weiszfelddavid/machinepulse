import AppKit
import MachinePulseCore
import SwiftUI

struct HistorySparkline: View {
    let samples: [MetricSample]
    let focus: HealthIncident?
    let thresholds: HealthThresholds

    private var chartStart: Date { (samples.last?.timestamp ?? Date()).addingTimeInterval(-15 * 60) }
    private var chartEnd: Date { samples.last?.timestamp ?? Date() }
    private var pressureResource: PressureHistoryResource? {
        if let resource = PressureHistoryResource(issueID: focus?.issueID) {
            return resource
        }
        return samples.contains { $0.ioPressure != nil } ? .storage : nil
    }
    private var focusedSignal: HistorySignal? {
        if PressureHistoryResource(issueID: focus?.issueID) != nil {
            return .pressureSome
        }
        return HistorySignal(issueKind: focus?.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 15 min")
                    .font(.caption2.weight(.semibold))
                Spacer()
                if let pressureResource {
                    Text("\(pressureResource.label) wait · some / full")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack {
                    thresholdLines(in: geometry.size)
                    linePath(in: geometry.size, values: samples.map { ($0.timestamp, $0.cpuPercent) })
                        .stroke(.blue.opacity(opacity(for: .cpu)), style: lineStyle(for: .cpu))
                    linePath(in: geometry.size, values: samples.map { ($0.timestamp, $0.memoryUsedFraction * 100) })
                        .stroke(.purple.opacity(opacity(for: .memory)), style: lineStyle(for: .memory))
                    if pressureResource != nil {
                        linePath(
                            in: geometry.size,
                            values: samples.map { ($0.timestamp, pressureMetric(for: $0)?.someAverage10 ?? 0) }
                        )
                        .stroke(.orange.opacity(opacity(for: .pressureSome)), style: lineStyle(for: .pressureSome))
                        linePath(
                            in: geometry.size,
                            values: samples.map { ($0.timestamp, pressureMetric(for: $0)?.fullAverage10 ?? 0) }
                        )
                        .stroke(.pink.opacity(opacity(for: .pressureFull)), style: lineStyle(for: .pressureFull))
                    }
                }
            }
            .frame(height: 58)
            HStack(spacing: 10) {
                ChartLegendItem(label: "CPU", value: currentValue(for: .cpu), color: .blue)
                ChartLegendItem(label: "RAM", value: currentValue(for: .memory), color: .purple)
                if pressureResource != nil {
                    ChartLegendItem(label: "Wait some", value: currentValue(for: .pressureSome), color: .orange)
                    ChartLegendItem(label: "Wait full", value: currentValue(for: .pressureFull), color: .pink)
                }
            }
            if let thresholdDescription {
                Text(thresholdDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if gapCount > 0 {
                Text("\(gapCount) sampling gap\(gapCount == 1 ? "" : "s") shown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(accessibilitySummary)
    }

    @ViewBuilder
    private func thresholdLines(in size: CGSize) -> some View {
        if let pair = focusedThresholds {
            Path { path in
                let warningY = size.height * (1 - min(max(pair.warning, 0), 100) / 100)
                path.move(to: CGPoint(x: 0, y: warningY))
                path.addLine(to: CGPoint(x: size.width, y: warningY))
            }
            .stroke(.orange.opacity(0.42), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            Path { path in
                let criticalY = size.height * (1 - min(max(pair.critical, 0), 100) / 100)
                path.move(to: CGPoint(x: 0, y: criticalY))
                path.addLine(to: CGPoint(x: size.width, y: criticalY))
            }
            .stroke(.red.opacity(0.42), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
    }

    private func lineStyle(for signal: HistorySignal) -> StrokeStyle {
        StrokeStyle(
            lineWidth: isFocused(signal) ? 2 : 1,
            lineCap: .round,
            lineJoin: .round
        )
    }

    private func opacity(for signal: HistorySignal) -> Double {
        isFocused(signal) ? 0.95 : 0.28
    }

    private func isFocused(_ signal: HistorySignal) -> Bool {
        guard let focusedSignal else { return true }
        if focusedSignal == .pressureSome {
            return signal == .pressureSome || signal == .pressureFull
        }
        return focusedSignal == signal
    }

    private func linePath(in size: CGSize, values: [(Date, Double)]) -> Path {
        guard values.count > 1, size.width > 0, size.height > 0 else { return Path() }
        let duration = max(chartEnd.timeIntervalSince(chartStart), 1)
        var path = Path()
        var previousDate: Date?
        for (date, value) in values where date >= chartStart && date <= chartEnd {
            let x = size.width * date.timeIntervalSince(chartStart) / duration
            let y = size.height * (1 - min(max(value, 0), 100) / 100)
            let point = CGPoint(x: x, y: y)
            if previousDate == nil || date.timeIntervalSince(previousDate ?? date) > 25 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
            previousDate = date
        }
        return path
    }

    private func values(for signal: HistorySignal) -> [Double] {
        switch signal {
        case .cpu: samples.map(\.cpuPercent)
        case .memory: samples.map { $0.memoryUsedFraction * 100 }
        case .pressureSome: samples.map { pressureMetric(for: $0)?.someAverage10 ?? 0 }
        case .pressureFull: samples.map { pressureMetric(for: $0)?.fullAverage10 ?? 0 }
        }
    }

    private func pressureMetric(for sample: MetricSample) -> PressureMetric? {
        pressureResource?.metric(from: sample)
    }

    private func currentValue(for signal: HistorySignal) -> String {
        MetricFormat.percent(values(for: signal).last ?? 0)
    }

    private var focusedThresholds: (warning: Double, critical: Double)? {
        if PressureHistoryResource(issueID: focus?.issueID) != nil {
            return (thresholds.pressureWarningAverage10, thresholds.pressureCriticalAverage10)
        }
        return switch focus?.kind {
        case .cpu:
            (thresholds.cpuWarningPercent, thresholds.cpuCriticalPercent)
        case .memory, .swap:
            (thresholds.memoryWarningFraction * 100, thresholds.memoryCriticalFraction * 100)
        case .connectivity, .collection, .diskCapacity, .diskPressure, .memoryPressure, .service, .oom, nil:
            nil
        }
    }

    private var thresholdDescription: String? {
        guard let focusedThresholds else { return nil }
        let label = PressureHistoryResource(issueID: focus?.issueID)?.waitLabel ?? focusedSignal?.label ?? "Signal"
        return
            "\(label) context: warning \(MetricFormat.percent(focusedThresholds.warning)) · critical \(MetricFormat.percent(focusedThresholds.critical))"
    }

    private var gapCount: Int {
        zip(samples, samples.dropFirst()).count { next in
            next.1.timestamp.timeIntervalSince(next.0.timestamp) > 25
        }
    }

    private var accessibilitySummary: String {
        let visibleSignals: [HistorySignal] =
            pressureResource == nil
            ? [.cpu, .memory]
            : [.cpu, .memory, .pressureSome, .pressureFull]
        let details = visibleSignals.map { signal in
            let signalValues = values(for: signal)
            return
                "\(label(for: signal)), current \(MetricFormat.percent(signalValues.last ?? 0)), peak \(MetricFormat.percent(signalValues.max() ?? 0))"
        }
        return (["Last 15 minutes"] + details + (gapCount > 0 ? ["\(gapCount) sampling gaps"] : [])).joined(
            separator: ". "
        )
    }

    private func label(for signal: HistorySignal) -> String {
        switch signal {
        case .pressureSome: "\(pressureResource?.waitLabel ?? "Pressure") some"
        case .pressureFull: "\(pressureResource?.waitLabel ?? "Pressure") full"
        default: signal.label
        }
    }
}

private enum HistorySignal: Equatable {
    case cpu
    case memory
    case pressureSome
    case pressureFull

    init?(issueKind: HealthIssueKind?) {
        switch issueKind {
        case .cpu: self = .cpu
        case .memory, .swap: self = .memory
        case .connectivity, .collection, .diskCapacity, .diskPressure, .memoryPressure, .service, .oom, nil:
            return nil
        }
    }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .pressureSome: "Pressure some"
        case .pressureFull: "Pressure full"
        }
    }
}

private enum PressureHistoryResource {
    case cpu
    case memory
    case storage

    init?(issueID: String?) {
        switch issueID {
        case "cpu-pressure": self = .cpu
        case "memory-pressure": self = .memory
        case "io-pressure": self = .storage
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        }
    }

    var waitLabel: String { "\(label) wait" }

    func metric(from sample: MetricSample) -> PressureMetric? {
        switch self {
        case .cpu: sample.cpuPressure
        case .memory: sample.memoryPressure
        case .storage: sample.ioPressure
        }
    }
}

private struct ChartLegendItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(label) \(value)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
