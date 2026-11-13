import Foundation

public enum AgentKind: String, Codable, Hashable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

public enum AgentSessionState: String, Codable, Hashable, Sendable {
    case idle
    case working
    case approval
    case waiting
}

/// One interactive agent session, as the machinepulse-agents plugin records
/// it on the machine where the agent runs.
public struct AgentSessionMetric: Codable, Hashable, Sendable, Identifiable {
    public let agent: AgentKind
    public let pid: Int32
    public let state: AgentSessionState
    public let since: Date
    public let turnStartedAt: Date?
    public let cwd: String?
    public let tty: String?
    public let terminal: String?
    public let terminalSession: String?
    public let tmuxPane: String?
    public let sshPort: Int?

    public var id: String { "\(agent.rawValue)-\(pid)" }

    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return agent.displayName }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }

    /// The length of the turn that ended when the session started to wait.
    public var finishedTurnDuration: TimeInterval? {
        guard state == .waiting, let turnStartedAt, since >= turnStartedAt else { return nil }
        return since.timeIntervalSince(turnStartedAt)
    }

    public init(
        agent: AgentKind,
        pid: Int32,
        state: AgentSessionState,
        since: Date,
        turnStartedAt: Date? = nil,
        cwd: String? = nil,
        tty: String? = nil,
        terminal: String? = nil,
        terminalSession: String? = nil,
        tmuxPane: String? = nil,
        sshPort: Int? = nil
    ) {
        self.agent = agent
        self.pid = pid
        self.state = state
        self.since = since
        self.turnStartedAt = turnStartedAt
        self.cwd = cwd
        self.tty = tty
        self.terminal = terminal
        self.terminalSession = terminalSession
        self.tmuxPane = tmuxPane
        self.sshPort = sshPort
    }
}

/// What one collection returns: the sample that health and history use, and
/// the agent sessions, which are never stored and never change health.
public struct MetricCollection: Sendable {
    public let sample: MetricSample
    public let agentSessions: [AgentSessionMetric]

    public init(sample: MetricSample, agentSessions: [AgentSessionMetric] = []) {
        self.sample = sample
        self.agentSessions = agentSessions
    }
}
