import Foundation

/// A typed reason why a metrics collection attempt produced no valid sample.
/// Collection failures describe observability problems on a machine that may
/// still be perfectly reachable through Tailscale; only Tailscale presence
/// decides reachability.
public enum MetricCollectionFailure: Equatable, Sendable {
    case notConfigured(String)
    case sshUnavailable(String)
    case collectorFailed(String)
    case invalidPayload(String)
    case localCollection(String)

    public static let issueID = "metrics-collection"

    public init(error: any Error, isLocalSource: Bool = false) {
        if let sourceError = error as? MetricSourceError {
            self = sourceError.collectionFailure
        } else if isLocalSource {
            self = .localCollection(FailureSanitizer.sanitize(error.localizedDescription))
        } else {
            self = .sshUnavailable(FailureSanitizer.sanitize(error.localizedDescription))
        }
    }

    public var title: String {
        switch self {
        case .notConfigured, .sshUnavailable: "Metrics collection unavailable"
        case .collectorFailed, .invalidPayload, .localCollection: "Metrics collection failed"
        }
    }

    public var explanation: String {
        switch self {
        case let .notConfigured(detail):
            detail
        case let .sshUnavailable(detail):
            "The machine is reachable through Tailscale, but SSH did not connect: \(detail)"
        case let .collectorFailed(detail):
            "The machine is reachable through Tailscale, but the metrics collector failed: \(detail)"
        case let .invalidPayload(detail):
            "The machine is reachable through Tailscale, but returned an invalid metrics payload: \(detail)"
        case let .localCollection(detail):
            "Local metric collection failed: \(detail)"
        }
    }
}

/// Reduces raw failure output—including complete Python tracebacks and ssh
/// stderr—to one concise line safe for health summaries, never longer than
/// `maximumLength`. Tokens that reference SSH key directories or key files
/// are redacted.
public enum FailureSanitizer {
    public static let maximumLength = 200

    public static func sanitize(_ raw: String, limit: Int = maximumLength) -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var summary = lines.last ?? "Unknown failure"
        summary = summary.split(whereSeparator: \.isWhitespace)
            .map { token in referencesKeyMaterial(String(token)) ? "(key path)" : String(token) }
            .joined(separator: " ")
        if summary.count > limit {
            summary = String(summary.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return summary
    }

    private static func referencesKeyMaterial(_ token: String) -> Bool {
        let cleaned = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'\"`:;,.()[]"))
        return cleaned.contains("/.ssh/")
            || cleaned.hasSuffix(".pem")
            || cleaned.hasSuffix(".key")
            || cleaned.hasSuffix("_rsa")
            || cleaned.hasSuffix("_ed25519")
            || cleaned.hasSuffix("_ecdsa")
    }
}

extension HealthEvaluator {
    /// Classifies presence for a device that is not deep-monitored. Offline
    /// mobile devices stay healthy with a quiet summary; offline machines
    /// remain immediately unreachable.
    public static func presenceReport(for device: MachineDevice, evaluatedAt: Date = Date()) -> HealthReport {
        if device.isOnline {
            return HealthReport(
                deviceID: device.id,
                state: .healthy,
                summary: device.connection == .relay ? "Online through a relay" : "Online on your tailnet",
                issues: [],
                evaluatedAt: evaluatedAt
            )
        }
        if device.isMobile {
            let summary =
                device.lastSeen.map { "Offline · last seen \($0.formatted(.relative(presentation: .named)))" }
                ?? "Offline"
            return HealthReport(
                deviceID: device.id,
                state: .healthy,
                summary: summary,
                issues: [],
                evaluatedAt: evaluatedAt
            )
        }
        return unreachable(
            deviceID: device.id,
            message: device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
                ?? "Tailscale reports this device as offline.",
            evaluatedAt: evaluatedAt
        )
    }

    /// Builds the report for a refresh that produced no valid sample. Tailscale
    /// reachability decides between an unreachable report and a metrics
    /// collection warning; a collection problem never becomes "unreachable"
    /// while Tailscale reports the machine online.
    public static func collectionFailure(
        deviceID: String,
        isReachableThroughTailscale: Bool,
        failure: MetricCollectionFailure,
        offlineMessage: String? = nil,
        evaluatedAt: Date = Date()
    ) -> HealthReport {
        guard isReachableThroughTailscale else {
            return unreachable(
                deviceID: deviceID,
                message: offlineMessage ?? "Tailscale reports this device as offline.",
                evaluatedAt: evaluatedAt
            )
        }
        let issue = HealthIssue(
            id: MetricCollectionFailure.issueID,
            kind: .collection,
            state: .warning,
            title: failure.title,
            explanation: failure.explanation
        )
        return HealthReport(
            deviceID: deviceID,
            state: .warning,
            summary: issue.title,
            issues: [issue],
            evaluatedAt: evaluatedAt
        )
    }
}
