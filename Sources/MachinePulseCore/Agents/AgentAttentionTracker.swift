import Foundation

public enum AgentAttentionKind: Hashable, Sendable {
    case finished(duration: TimeInterval)
    case needsApproval
}

public struct AgentAttention: Hashable, Sendable {
    public let deviceID: String
    public let session: AgentSessionMetric
    public let kind: AgentAttentionKind
}

/// Decides which agent sessions deserve a notification. Each finished turn
/// and each approval request is announced once. The first collection of a
/// machine only sets the baseline, so a launch does not replay old turns.
public struct AgentAttentionTracker: Sendable {
    /// Shorter turns are a conversation at the keyboard, not a task to come
    /// back to.
    public static let minimumTurnDuration: TimeInterval = 30

    private var announced: [String: Set<String>] = [:]

    public init() {}

    public mutating func process(deviceID: String, sessions: [AgentSessionMetric]) -> [AgentAttention] {
        let isBaseline = announced[deviceID] == nil
        let previous = announced[deviceID] ?? []
        var current = Set<String>()
        var attentions: [AgentAttention] = []
        for session in sessions {
            guard let (key, kind) = Self.attention(for: session) else { continue }
            current.insert(key)
            if !isBaseline, !previous.contains(key) {
                attentions.append(AgentAttention(deviceID: deviceID, session: session, kind: kind))
            }
        }
        announced[deviceID] = current
        return attentions
    }

    public mutating func forget(deviceID: String) {
        announced[deviceID] = nil
    }

    static func attention(for session: AgentSessionMetric) -> (String, AgentAttentionKind)? {
        switch session.state {
        case .waiting:
            guard
                let turnStartedAt = session.turnStartedAt,
                let duration = session.finishedTurnDuration,
                duration >= minimumTurnDuration
            else { return nil }
            return ("\(session.id)@\(Int(turnStartedAt.timeIntervalSince1970))", .finished(duration: duration))
        case .approval:
            return ("\(session.id)@approval@\(Int(session.since.timeIntervalSince1970))", .needsApproval)
        case .idle, .working:
            return nil
        }
    }
}
