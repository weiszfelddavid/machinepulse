import Foundation
import Testing
@testable import MachinePulseCore

struct AgentSessionReaderTests {
    @Test func keepsOnlySessionsWhoseProcessStillRunsUnderTheRecordedName() async throws {
        let directory = try temporaryAgentsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(record(agent: "claude", pid: 101, state: "working", since: 1_000), to: directory)
        try write(record(agent: "codex", pid: 102, state: "waiting", since: 2_000, turnStartedAt: 1_900), to: directory)
        try write(record(agent: "claude", pid: 103, state: "idle", since: 3_000), to: directory)
        try write(record(agent: "claude", pid: 104, state: "idle", since: 4_000), to: directory)
        try write(record(agent: "claude", pid: 105, state: "idle", since: 5_000, process: "2.1.323"), to: directory)

        let names: [Int32: String] = [101: "claude", 102: "/opt/example/bin/codex", 103: "python3", 105: "2.1.323"]
        let sessions = await AgentSessionReader.read(directory: directory, processNames: { _ in names })

        #expect(sessions.map(\.id) == ["claude-105", "codex-102", "claude-101"])
        #expect(sessions.map(\.state) == [.idle, .waiting, .working])
        #expect(sessions[1].finishedTurnDuration == 100)
    }

    @Test func skipsUnknownVersionsStatesAgentsOversizedAndMalformedFiles() async throws {
        let directory = try temporaryAgentsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var future = record(agent: "claude", pid: 201, state: "working", since: 1_000)
        future["version"] = 2
        try write(future, to: directory)
        try write(record(agent: "claude", pid: 202, state: "thinking", since: 1_000), to: directory)
        try write(record(agent: "gemini", pid: 203, state: "working", since: 1_000), to: directory)
        var oversized = record(agent: "claude", pid: 204, state: "working", since: 1_000)
        oversized["cwd"] = String(repeating: "a", count: 5_000)
        try write(oversized, to: directory)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("claude-205.json"))
        var odd = record(agent: "claude", pid: 206, state: "working", since: 1_000)
        odd["cwd"] = 42
        odd["tty"] = ""
        try write(odd, to: directory)
        var unnamed = record(agent: "claude", pid: 207, state: "working", since: 1_000)
        unnamed["process"] = nil
        try write(unnamed, to: directory)

        let sessions = await AgentSessionReader.read(directory: directory, processNames: named("claude"))

        #expect(sessions.map(\.id) == ["claude-206"])
        #expect(sessions.first?.cwd == nil)
        #expect(sessions.first?.tty == nil)
    }

    @Test func approvalTurnsBackToWorkingOnceTheTranscriptMoves() async throws {
        let directory = try temporaryAgentsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var answered = record(agent: "claude", pid: 301, state: "approval", since: 1_000)
        answered["transcript"] = "/transcripts/answered.jsonl"
        var pending = record(agent: "claude", pid: 302, state: "approval", since: 1_000)
        pending["transcript"] = "/transcripts/pending.jsonl"
        try write(answered, to: directory)
        try write(pending, to: directory)

        let modified: [String: Date] = [
            "/transcripts/answered.jsonl": Date(timeIntervalSince1970: 1_010),
            "/transcripts/pending.jsonl": Date(timeIntervalSince1970: 1_001),
        ]
        let sessions = await AgentSessionReader.read(
            directory: directory,
            processNames: named("claude"),
            modificationDate: { modified[$0] }
        )

        #expect(sessions.first { $0.pid == 301 }?.state == .working)
        #expect(sessions.first { $0.pid == 302 }?.state == .approval)
    }

    @Test func aSessionInHerdrKeepsItsPaneAndSocket() async throws {
        let directory = try temporaryAgentsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var inHerdr = record(agent: "claude", pid: 401, state: "working", since: 1_000)
        inHerdr["herdrPane"] = "w1:p3"
        inHerdr["herdrSocket"] = "/home/example/.config/herdr/herdr.sock"
        inHerdr["terminal"] = "herdr"
        try write(inHerdr, to: directory)
        try write(record(agent: "claude", pid: 402, state: "working", since: 2_000), to: directory)

        let sessions = await AgentSessionReader.read(directory: directory, processNames: named("claude"))
        let herdr = try #require(sessions.first { $0.pid == 401 })
        #expect(herdr.herdrPane == "w1:p3")
        #expect(herdr.herdrSocket == "/home/example/.config/herdr/herdr.sock")
        #expect(herdr.runsInHerdr)
        #expect(sessions.first { $0.pid == 402 }?.runsInHerdr == false)
    }

    @Test func aMissingDirectoryMeansNoSessions() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("MachinePulseMissing-\(UUID())")
        #expect(await AgentSessionReader.read(directory: missing).isEmpty)
    }

    @Test func runningProcessNamesComeFromPS() async {
        let me = ProcessInfo.processInfo.processIdentifier
        let names = await AgentSessionReader.processNames(of: [me, 999_999])
        #expect(names[me] != nil)
        #expect(names[999_999] == nil)
    }

    @Test func theCollectorsSessionShapeDecodes() throws {
        let json = """
            {"agent":"codex","pid":7,"state":"waiting","since":1700000100,"turnStartedAt":1700000000,
             "cwd":"/home/example/code/storefront","tty":"pts/2","terminal":null,"terminalSession":null,
             "tmuxPane":"%1","sshPort":50002}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let session = try decoder.decode(AgentSessionMetric.self, from: Data(json.utf8))
        #expect(session.id == "codex-7")
        #expect(session.projectName == "storefront")
        #expect(session.finishedTurnDuration == 100)
        #expect(session.sshPort == 50_002)
    }
}

struct AgentAttentionTrackerTests {
    @Test func theFirstCollectionOnlySetsTheBaseline() {
        var tracker = AgentAttentionTracker()
        let finished = session(pid: 1, state: .waiting, since: 1_100, turnStartedAt: 1_000)
        #expect(tracker.process(deviceID: "vps", sessions: [finished]).isEmpty)
        #expect(tracker.process(deviceID: "vps", sessions: [finished]).isEmpty)
    }

    @Test func aLongTurnIsAnnouncedOnceAndAShortOneNever() {
        var tracker = AgentAttentionTracker()
        _ = tracker.process(deviceID: "vps", sessions: [])

        let short = session(pid: 1, state: .waiting, since: 1_020, turnStartedAt: 1_000)
        #expect(tracker.process(deviceID: "vps", sessions: [short]).isEmpty)

        let long = session(pid: 2, state: .waiting, since: 1_300, turnStartedAt: 1_000)
        let attentions = tracker.process(deviceID: "vps", sessions: [short, long])
        #expect(attentions.map(\.session.id) == ["claude-2"])
        #expect(attentions.first?.kind == .finished(duration: 300))
        #expect(tracker.process(deviceID: "vps", sessions: [short, long]).isEmpty)

        let nextTurn = session(pid: 2, state: .waiting, since: 2_000, turnStartedAt: 1_500)
        #expect(tracker.process(deviceID: "vps", sessions: [nextTurn]).count == 1)
    }

    @Test func eachApprovalRequestIsAnnouncedOnce() {
        var tracker = AgentAttentionTracker()
        _ = tracker.process(deviceID: "mac", sessions: [session(pid: 3, state: .working, since: 1_000)])

        let blocked = session(pid: 3, state: .approval, since: 1_050, turnStartedAt: 1_000)
        #expect(tracker.process(deviceID: "mac", sessions: [blocked]).map(\.kind) == [.needsApproval])
        #expect(tracker.process(deviceID: "mac", sessions: [blocked]).isEmpty)

        let blockedAgain = session(pid: 3, state: .approval, since: 1_090, turnStartedAt: 1_000)
        #expect(tracker.process(deviceID: "mac", sessions: [blockedAgain]).count == 1)
    }

    @Test func machinesAreTrackedSeparatelyAndForgettingResetsTheBaseline() {
        var tracker = AgentAttentionTracker()
        _ = tracker.process(deviceID: "a", sessions: [])
        let finished = session(pid: 4, state: .waiting, since: 1_100, turnStartedAt: 1_000)
        #expect(tracker.process(deviceID: "b", sessions: [finished]).isEmpty)
        #expect(tracker.process(deviceID: "a", sessions: [finished]).count == 1)

        tracker.forget(deviceID: "a")
        let later = session(pid: 4, state: .waiting, since: 2_100, turnStartedAt: 2_000)
        #expect(tracker.process(deviceID: "a", sessions: [later]).isEmpty)
    }

    @Test func anAttentionLastsUntilANewPromptAnAnswerOrTheEnd() throws {
        let finished = try #require(
            AgentAttention(
                deviceID: "vps", session: session(pid: 5, state: .waiting, since: 1_100, turnStartedAt: 1_000)))
        let blocked = try #require(
            AgentAttention(deviceID: "vps", session: session(pid: 6, state: .approval, since: 1_050)))
        let waiting = [finished, blocked]

        #expect(
            AgentAttentionTracker.stillWaiting(
                waiting,
                sessions: [
                    session(pid: 5, state: .waiting, since: 1_100, turnStartedAt: 1_000),
                    session(pid: 6, state: .approval, since: 1_050),
                ]
            ).map(\.id) == waiting.map(\.id))
        #expect(
            AgentAttentionTracker.stillWaiting(
                waiting,
                sessions: [
                    session(pid: 5, state: .working, since: 1_200, turnStartedAt: 1_200),
                    session(pid: 6, state: .working, since: 1_050),
                ]
            ).isEmpty)
        #expect(AgentAttentionTracker.stillWaiting(waiting, sessions: []).isEmpty)
    }

    @Test func theBubbleGrowsOneStepAMinuteForTenMinutes() {
        #expect(AgentAttention.bubbleScale(waitingFor: 0) == 1)
        #expect(AgentAttention.bubbleScale(waitingFor: 59) == 1)
        #expect(AgentAttention.bubbleScale(waitingFor: 60) == 1.1)
        #expect(abs(AgentAttention.bubbleScale(waitingFor: 5 * 60 + 30) - 1.5) < 1e-9)
        #expect(AgentAttention.bubbleScale(waitingFor: 10 * 60) == 2)
        #expect(AgentAttention.bubbleScale(waitingFor: 3 * 60 * 60) == 2)
        #expect(AgentAttention.bubbleScale(waitingFor: -30) == 1)
    }

    private func session(
        pid: Int32,
        state: AgentSessionState,
        since: TimeInterval,
        turnStartedAt: TimeInterval? = nil
    ) -> AgentSessionMetric {
        AgentSessionMetric(
            agent: .claude,
            pid: pid,
            state: state,
            since: Date(timeIntervalSince1970: since),
            turnStartedAt: turnStartedAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}

func record(
    agent: String, pid: Int, state: String, since: Int, turnStartedAt: Int = 0, process: String? = nil
) -> [String: Any] {
    [
        "version": 1, "agent": agent, "pid": pid, "process": process ?? agent, "state": state, "since": since,
        "turnStartedAt": turnStartedAt, "cwd": "/home/example/code/project-\(pid)",
        "transcript": "", "tty": "pts/\(pid % 10)", "terminal": "", "terminalSession": "",
        "tmuxPane": "", "sshPort": NSNull(), "herdrPane": "", "herdrSocket": "",
    ]
}

private func named(_ name: String) -> ([Int32]) -> [Int32: String] {
    { pids in Dictionary(uniqueKeysWithValues: pids.map { ($0, name) }) }
}

func temporaryAgentsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MachinePulseAgents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func write(_ record: [String: Any], to directory: URL) throws {
    let name = "\(record["agent"] ?? "agent")-\(record["pid"] ?? 0).json"
    try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent(name))
}
