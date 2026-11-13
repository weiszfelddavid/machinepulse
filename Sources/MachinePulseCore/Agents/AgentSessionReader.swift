import Darwin
import Foundation

/// Reads the agent session files on this Mac with the same rules that the
/// remote collector applies to them.
public enum AgentSessionReader {
    static let stateVersion = 1
    static let maximumSessions = 16
    static let maximumStateBytes = 4_096
    static let resumedMargin: TimeInterval = 2

    public static var defaultDirectory: URL {
        let base =
            ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state", isDirectory: true)
        return base.appendingPathComponent("machinepulse/agents", isDirectory: true)
    }

    public static func read(
        directory: URL = defaultDirectory,
        processName: (Int32) -> String? = processName(of:),
        modificationDate: (String) -> Date? = modificationDate(ofPath:)
    ) -> [AgentSessionMetric] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let sessions = names.filter { $0.hasSuffix(".json") }.compactMap { name -> AgentSessionMetric? in
            let path = directory.appendingPathComponent(name).path
            guard
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                size <= maximumStateBytes,
                let data = FileManager.default.contents(atPath: path),
                let record = try? JSONDecoder().decode(AgentStateRecord.self, from: data)
            else { return nil }
            return session(from: record, processName: processName, modificationDate: modificationDate)
        }
        return Array(
            sessions.sorted {
                $0.since != $1.since ? $0.since > $1.since : $0.id < $1.id
            }.prefix(maximumSessions))
    }

    static func session(
        from record: AgentStateRecord,
        processName: (Int32) -> String?,
        modificationDate: (String) -> Date?
    ) -> AgentSessionMetric? {
        guard
            record.version == stateVersion,
            let agent = record.agent.flatMap(AgentKind.init(rawValue:)),
            let pid = record.pid.flatMap(Int32.init(exactly:)), pid > 0,
            var state = record.state.flatMap(AgentSessionState.init(rawValue:)),
            let since = record.since, since > 0,
            let name = processName(pid).map({ ($0 as NSString).lastPathComponent }),
            acceptedProcessNames(for: agent).contains(name)
        else { return nil }
        let sinceDate = Date(timeIntervalSince1970: TimeInterval(since))
        // A session blocked on approval writes nothing; a transcript that
        // moved after the request means the answer came and the agent works.
        if state == .approval, let transcript = text(record.transcript, maximum: 1_024),
            let modified = modificationDate(transcript),
            modified.timeIntervalSince(sinceDate) > resumedMargin
        {
            state = .working
        }
        return AgentSessionMetric(
            agent: agent,
            pid: pid,
            state: state,
            since: sinceDate,
            turnStartedAt: record.turnStartedAt.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            cwd: text(record.cwd, maximum: 1_024),
            tty: text(record.tty, maximum: 64),
            terminal: text(record.terminal, maximum: 64),
            terminalSession: text(record.terminalSession, maximum: 128),
            tmuxPane: text(record.tmuxPane, maximum: 32),
            sshPort: record.sshPort.flatMap { (1...65_535).contains($0) ? $0 : nil }
        )
    }

    /// Claude Code installed with npm runs as node.
    static func acceptedProcessNames(for agent: AgentKind) -> Set<String> {
        switch agent {
        case .claude: ["claude", "node"]
        case .codex: ["codex"]
        }
    }

    public static func processName(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    public static func modificationDate(ofPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func text(_ value: String?, maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= maximum else { return nil }
        return value
    }
}

/// The file the plugin writes. A field of the wrong type reads as missing, so
/// one odd value never hides the whole session.
struct AgentStateRecord: Decodable {
    var version: Int?
    var agent: String?
    var pid: Int?
    var state: String?
    var since: Int?
    var turnStartedAt: Int?
    var cwd: String?
    var transcript: String?
    var tty: String?
    var terminal: String?
    var terminalSession: String?
    var tmuxPane: String?
    var sshPort: Int?

    private enum CodingKeys: String, CodingKey {
        case version, agent, pid, state, since, turnStartedAt, cwd, transcript, tty, terminal, terminalSession,
            tmuxPane, sshPort
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try? container.decode(Int.self, forKey: .version)
        agent = try? container.decode(String.self, forKey: .agent)
        pid = try? container.decode(Int.self, forKey: .pid)
        state = try? container.decode(String.self, forKey: .state)
        since = try? container.decode(Int.self, forKey: .since)
        turnStartedAt = try? container.decode(Int.self, forKey: .turnStartedAt)
        cwd = try? container.decode(String.self, forKey: .cwd)
        transcript = try? container.decode(String.self, forKey: .transcript)
        tty = try? container.decode(String.self, forKey: .tty)
        terminal = try? container.decode(String.self, forKey: .terminal)
        terminalSession = try? container.decode(String.self, forKey: .terminalSession)
        tmuxPane = try? container.decode(String.self, forKey: .tmuxPane)
        sshPort = try? container.decode(Int.self, forKey: .sshPort)
    }
}
