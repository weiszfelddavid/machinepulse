import Foundation

/// What a deep-monitored device should collect with, derived purely from its
/// identity and configuration.
public enum DesiredMetricSource: Equatable, Sendable {
    case localMac
    case ssh(target: String)
    case presenceOnly
    case unavailable(MetricCollectionFailure)
}

/// The deterministic scheduling decisions of the refresh loop: retry backoff,
/// due gating, and when an offline deep device still needs an explicit
/// unreachable report.
public struct MonitoringScheduler: Sendable {
    private var failureCounts: [String: Int] = [:]
    private var nextAttempts: [String: Date] = [:]

    public init() {}

    public static func desiredSource(
        platform: DevicePlatform,
        isLocal: Bool,
        mode: MonitoringMode,
        sshTarget: String?,
        hasCollectorScript: Bool
    ) -> DesiredMetricSource {
        guard mode == .deep else { return .presenceOnly }
        if platform == .macOS, isLocal { return .localMac }
        guard platform.supportsFullMetrics else {
            return .unavailable(.notConfigured("Deep monitoring is not available for this machine."))
        }
        guard let target = sshTarget?.trimmingCharacters(in: .whitespaces), !target.isEmpty else {
            return .unavailable(.notConfigured("Choose an SSH target in Settings to collect metrics over SSH."))
        }
        guard hasCollectorScript else {
            return .unavailable(.notConfigured("The bundled collector script is missing."))
        }
        return .ssh(target: target)
    }

    public func isDue(deviceID: String, now: Date) -> Bool {
        (nextAttempts[deviceID] ?? .distantPast) <= now
    }

    /// A deep device whose collection attempt is deferred by backoff must
    /// still report unreachable on a refresh where Tailscale says it is
    /// offline; due devices reach the same report through their collection
    /// failure.
    public func needsOfflineReport(deviceID: String, isOnline: Bool, hasSource: Bool, now: Date) -> Bool {
        hasSource && !isOnline && !isDue(deviceID: deviceID, now: now)
    }

    @discardableResult
    public mutating func recordFailure(deviceID: String, now: Date) -> Date {
        let count = (failureCounts[deviceID] ?? 0) + 1
        failureCounts[deviceID] = count
        let next = now.addingTimeInterval(RetryBackoff.delay(afterConsecutiveFailures: count))
        nextAttempts[deviceID] = next
        return next
    }

    public mutating func reset(deviceID: String) {
        failureCounts[deviceID] = nil
        nextAttempts[deviceID] = nil
    }
}

/// 10, 20, 40, then 60 seconds between attempts after consecutive failures.
public enum RetryBackoff {
    public static let maximumDelay: TimeInterval = 60

    public static func delay(afterConsecutiveFailures count: Int) -> TimeInterval {
        min(maximumDelay, 10 * pow(2, Double(max(0, count - 1))))
    }
}
