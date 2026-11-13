import Foundation
import Testing
@testable import MachinePulseCore

/// The plugin's hook script, run as the agents run it: under `sh`, with the
/// hook input on stdin and `ps` answering for an invented agent process.
/// Serialized: each case starts dozens of short processes, and in parallel
/// they starve the collector tests that bound `ps` to two seconds.
@Suite(.serialized) struct AgentStateHookTests {
    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(arguments: shells) func aTurnMovesFromIdleToWorkingToWaitingAndKeepsItsStart(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }

        try await hook.run("start")
        let started = try #require(try hook.record())
        #expect(started.state == "idle")
        #expect(started.turnStartedAt == 0)
        #expect(started.agent == "claude")
        #expect(started.pid == Int(hook.agentPID))
        #expect(started.tty == "ttys004")
        #expect(started.cwd == "/work/say \"hi\"")
        #expect(started.transcript == "/home/example/.claude/projects/example/session.jsonl")

        try await hook.run("prompt")
        let working = try #require(try hook.record())
        #expect(working.state == "working")
        let turnStartedAt = try #require(working.turnStartedAt)
        #expect(turnStartedAt > 0)

        try await hook.run("stop")
        let waiting = try #require(try hook.record())
        #expect(waiting.state == "waiting")
        #expect(waiting.turnStartedAt == turnStartedAt)

        let session = try #require(
            AgentSessionReader.read(directory: hook.agentsDirectory, processName: { _ in "claude" }).first)
        #expect(session.state == .waiting)
        #expect(session.cwd == "/work/say \"hi\"")
        #expect(session.projectName == "say \"hi\"")
    }

    @Test(arguments: shells) func idleOnlyEndsAnInterruptedTurn(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }

        try await hook.run("prompt")
        try await hook.run("stop")
        try await hook.run("idle")
        #expect(try hook.record()?.state == "waiting")

        try await hook.run("prompt")
        try await hook.run("idle")
        #expect(try hook.record()?.state == "idle")
    }

    @Test(arguments: shells) func compactingMidTurnKeepsTheTurn(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }

        try await hook.run("prompt")
        let turnStartedAt = try #require(try hook.record()?.turnStartedAt)
        try await hook.run("start")
        #expect(try hook.record()?.state == "working")
        #expect(try hook.record()?.turnStartedAt == turnStartedAt)
    }

    @Test(arguments: shells) func approvalAndEnd(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }

        try await hook.run("approval")
        #expect(try hook.record()?.state == "approval")
        try await hook.run("end")
        #expect(try hook.record() == nil)
    }

    @Test(arguments: shells) func aScriptedRunWithoutTerminalLeavesNoFile(shell: String) async throws {
        let hook = try HookFixture(shell: shell, tty: "??")
        defer { hook.remove() }

        try await hook.run("prompt")
        #expect(try hook.record() == nil)
    }

    @Test(arguments: shells) func codexIsRecognizedAndTerminalIdentityIsKept(shell: String) async throws {
        let hook = try HookFixture(
            shell: shell,
            agentName: "/opt/example/bin/codex",
            environment: [
                "SSH_CONNECTION": "100.64.0.2 51234 100.64.0.9 22",
                "TERM_PROGRAM": "Apple_Terminal",
                "TERM_SESSION_ID": "0BADC0DE-0000-4000-8000-000000000002",
                "TMUX_PANE": "%3",
            ]
        )
        defer { hook.remove() }

        try await hook.run("prompt")
        let record = try #require(try hook.record(agent: "codex"))
        #expect(record.agent == "codex")
        #expect(record.sshPort == 51_234)
        #expect(record.terminal == "Apple_Terminal")
        #expect(record.terminalSession == "0BADC0DE-0000-4000-8000-000000000002")
        #expect(record.tmuxPane == "%3")
    }

    @Test(arguments: shells) func startRemovesFilesOfAgentsThatAreGone(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }
        try FileManager.default.createDirectory(at: hook.agentsDirectory, withIntermediateDirectories: true)
        let stale = hook.agentsDirectory.appendingPathComponent("claude-999999.json")
        try Data("{}".utf8).write(to: stale)

        try await hook.run("start")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try hook.record() != nil)
    }

    @Test(arguments: shells) func printsNothingAndSucceedsForAnUnknownEvent(shell: String) async throws {
        let hook = try HookFixture(shell: shell)
        defer { hook.remove() }

        let output = try await hook.run("unknown")
        #expect(output.isEmpty)
        #expect(try hook.record() == nil)
        #expect(try await hook.run("stop").isEmpty)
    }
}

private struct HookFixture {
    let shell: String
    let workspace: URL
    let agentPID = ProcessInfo.processInfo.processIdentifier
    let environment: [String: String]

    var agentsDirectory: URL { workspace.appendingPathComponent("state/machinepulse/agents", isDirectory: true) }

    init(shell: String, tty: String = "ttys004", agentName: String = "claude", environment: [String: String] = [:])
        throws
    {
        self.shell = shell
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseHook-\(UUID().uuidString)", isDirectory: true)
        let bin = workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ps = bin.appendingPathComponent("ps")
        try Self.fakePS.write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
        var values = environment
        values["PATH"] = "\(bin.path):/usr/bin:/bin"
        values["HOME"] = workspace.path
        values["XDG_STATE_HOME"] = workspace.appendingPathComponent("state").path
        values["FAKE_AGENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        values["FAKE_AGENT_NAME"] = agentName
        values["FAKE_TTY"] = tty
        self.environment = values
    }

    @discardableResult
    func run(_ event: String) async throws -> String {
        let input = """
            {"session_id":"example","transcript_path":"/home/example/.claude/projects/example/session.jsonl",\
            "cwd":"/work/say \\"hi\\"","hook_event_name":"Example","prompt":"mention \\"cwd\\": \\"/elsewhere\\""}
            """
        let result = try await CommandRunner.run(
            executable: shell,
            arguments: [Self.scriptURL.path, event],
            standardInput: Data(input.utf8),
            environment: environment,
            timeout: 10
        )
        return result.outputString
    }

    func record(agent: String = "claude") throws -> HookRecord? {
        let url = agentsDirectory.appendingPathComponent("\(agent)-\(agentPID).json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HookRecord.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: workspace)
    }

    static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("plugins/machinepulse-agents/scripts/agent-state")

    /// Answers the two questions the hook asks: the parent and name of a
    /// process, or its terminal. Every other process is a child of the agent.
    static let fakePS = """
        #!/bin/sh
        pid= fields=
        while [ $# -gt 0 ]; do
            case $1 in
                -o) fields="$fields $2"; shift 2 ;;
                -p) pid=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        case $fields in
            *tty=*) [ "$pid" = "$FAKE_AGENT_PID" ] && echo "$FAKE_TTY " ;;
            *)
                if [ "$pid" = "$FAKE_AGENT_PID" ]; then echo "    1 $FAKE_AGENT_NAME"
                else echo " $FAKE_AGENT_PID sh"; fi
                ;;
        esac
        exit 0
        """
}

private struct HookRecord: Decodable {
    let version: Int
    let agent: String
    let pid: Int
    let state: String
    let since: Int
    let turnStartedAt: Int?
    let cwd: String
    let transcript: String
    let tty: String
    let terminal: String
    let terminalSession: String
    let tmuxPane: String
    let sshPort: Int?
}
