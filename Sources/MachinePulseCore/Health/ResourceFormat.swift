import Foundation

/// One spelling for cgroup values in explanations and diagnostics: a value
/// that was not read says why instead of pretending to be a number.
public enum ResourceFormat {
    public static func bytes(_ metric: WorkloadResourceValueMetric) -> String {
        guard metric.availability == .available, let value = metric.value else {
            return metric.availability.rawValue
        }
        return SizeFormat.bytes(value)
    }

    public static func count(_ metric: WorkloadResourceValueMetric) -> String {
        guard metric.availability == .available, let value = metric.value else {
            return metric.availability.rawValue
        }
        return value.formatted()
    }

    public static func limit(_ metric: WorkloadResourceLimitMetric, bytes: Bool) -> String {
        switch metric.state {
        case .configured:
            guard let value = metric.value else { return "unavailable" }
            return bytes ? SizeFormat.bytes(value) : value.formatted()
        case .unlimited, .unavailable, .unsupported:
            return metric.state.rawValue
        }
    }

    public static func cpuQuota(_ metric: WorkloadCPUQuotaMetric, withPeriod: Bool) -> String {
        switch metric.state {
        case .configured:
            guard let quota = metric.quotaMicroseconds, let period = metric.periodMicroseconds, period > 0 else {
                return "unavailable"
            }
            let share = String(format: "%.0f%%", Double(quota) / Double(period) * 100)
            return withPeriod ? "\(share) (\(microseconds(quota)) / \(microseconds(period)))" : share
        case .unlimited:
            guard withPeriod, let period = metric.periodMicroseconds else { return metric.state.rawValue }
            return "unlimited (period \(microseconds(period)))"
        case .unavailable, .unsupported:
            return metric.state.rawValue
        }
    }

    public static func duration(_ metric: WorkloadResourceValueMetric) -> String {
        guard metric.availability == .available, let value = metric.value else {
            return metric.availability.rawValue
        }
        return microseconds(value)
    }

    public static func microseconds(_ value: UInt64) -> String {
        if value < 1_000 { return "\(value) µs" }
        if value < 1_000_000 { return String(format: "%.1f ms", Double(value) / 1_000) }
        return String(format: "%.1f s", Double(value) / 1_000_000)
    }

    public static func pressure(_ metric: WorkloadPressureMetric) -> String {
        guard metric.availability == .available, let some = metric.someAverage10, let full = metric.fullAverage10
        else { return metric.availability.rawValue }
        return String(format: "some %.1f%% / full %.1f%% avg10", some, full)
    }
}
