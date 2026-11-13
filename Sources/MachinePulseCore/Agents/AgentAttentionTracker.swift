import Foundation

public enum AgentAttentionKind: Hashable, Sendable {
    case finished(duration: TimeInterval)
    case needsApproval
}

/// A session that waits for you: a long turn that finished, or a request for
/// approval. One finished turn or one request is one attention.
public struct AgentAttention: Hashable, Sendable, Identifiable {
    /// Shorter turns are a conversation at the keyboard, not a task to come
    /// back to.
    public static let minimumTurnDuration: TimeInterval = 30
    /// The bubble grows one step a minute for ten minutes, to twice its size.
    public static let bubblePeakScale = 2.0
    static let bubbleGrowthSteps = 10.0

    public let deviceID: String
    public let session: AgentSessionMetric
    public let kind: AgentAttentionKind
    let key: String

    public var id: String { "\(deviceID)/\(key)" }

    public init?(deviceID: String, session: AgentSessionMetric) {
        switch session.state {
        case .waiting:
            guard
                let turnStartedAt = session.turnStartedAt,
                let duration = session.finishedTurnDuration,
                duration >= Self.minimumTurnDuration
            else { return nil }
            kind = .finished(duration: duration)
            key = "\(session.id)@\(Int(turnStartedAt.timeIntervalSince1970))"
        case .approval:
            kind = .needsApproval
            key = "\(session.id)@approval@\(Int(session.since.timeIntervalSince1970))"
        case .idle, .working:
            return nil
        }
        self.deviceID = deviceID
        self.session = session
    }

    public static func bubbleScale(waitingFor interval: TimeInterval) -> Double {
        let steps = min(bubbleGrowthSteps, max(0, (interval / 60).rounded(.down)))
        return 1 + steps * (bubblePeakScale - 1) / bubbleGrowthSteps
    }
}

/// Decides which attentions are new. Each is announced once, and the first
/// collection of a machine only sets the baseline, so a launch does not
/// replay old turns.
public struct AgentAttentionTracker: Sendable {
    private var announced: [String: Set<String>] = [:]

    public init() {}

    public mutating func process(deviceID: String, sessions: [AgentSessionMetric]) -> [AgentAttention] {
        let isBaseline = announced[deviceID] == nil
        let previous = announced[deviceID] ?? []
        let current = sessions.compactMap { AgentAttention(deviceID: deviceID, session: $0) }
        announced[deviceID] = Set(current.map(\.key))
        return isBaseline ? [] : current.filter { !previous.contains($0.key) }
    }

    public mutating func forget(deviceID: String) {
        announced[deviceID] = nil
    }

    /// The attentions whose session still waits for the same reason, with the
    /// session as it is now. A new prompt, an answered approval, or an ended
    /// session resolves them.
    public static func stillWaiting(
        _ attentions: [AgentAttention],
        sessions: [AgentSessionMetric]
    ) -> [AgentAttention] {
        attentions.compactMap { attention in
            guard
                let session = sessions.first(where: { $0.id == attention.session.id }),
                let current = AgentAttention(deviceID: attention.deviceID, session: session),
                current.key == attention.key
            else { return nil }
            return current
        }
    }
}
