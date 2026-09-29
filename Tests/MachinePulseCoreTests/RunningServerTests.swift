import Darwin
import Foundation
import Testing
@testable import MachinePulseCore

struct RunningServerTests {
    @Test func parsesListenerWorkingDirectoryAndProcessRecords() throws {
        let listeners = LocalServerDiscovery.parseListeners(
            """
            p62954
            csymfony
            u501
            f19
            PTCP
            n127.0.0.1:8000
            f20
            PTCP
            n[::1]:8000
            """)
        #expect(listeners.count == 2)
        #expect(listeners.first?.processID == 62_954)
        #expect(listeners.first?.processName == "symfony")
        #expect(listeners.first?.userID == 501)
        #expect(listeners.first?.host == "127.0.0.1")
        #expect(listeners.first?.port == 8_000)
        #expect(listeners.last?.host == "::1")

        let directories = LocalServerDiscovery.parseWorkingDirectories(
            """
            p62954
            csymfony
            fcwd
            n/Users/example/code_vault/developers
            """)
        #expect(directories[62_954]?.path == "/Users/example/code_vault/developers")

        let processes = LocalServerDiscovery.parseProcesses(
            "62954 501 Sat Aug  8 13:40:01 2026 symfony server:start --no-tls --port=8000"
        )
        let process = try #require(processes[62_954])
        #expect(process.userID == 501)
        #expect(process.command == "symfony server:start --no-tls --port=8000")
        #expect(Calendar.current.component(.year, from: process.startedAt) == 2_026)
    }

    @Test func findsProjectServersDeduplicatesSocketsAndAvoidsFalseBrowserLinks() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let discovery = LocalServerDiscovery(homeDirectory: fixture.home, currentUserID: 501)
        let listeners = [
            ListenerRecord(processID: 101, processName: "symfony", userID: 501, host: "::1", port: 8_000),
            ListenerRecord(
                processID: 101, processName: "symfony", userID: 501, host: "127.0.0.1", port: 8_000),
            ListenerRecord(processID: 102, processName: "symfony", userID: 501, host: "*", port: 8_001),
            ListenerRecord(
                processID: 103, processName: "redis-server", userID: 501, host: "127.0.0.1", port: 6_379),
            ListenerRecord(processID: 104, processName: "php-fpm", userID: 501, host: "127.0.0.1", port: 9_000),
            ListenerRecord(processID: 105, processName: "node", userID: 501, host: "127.0.0.1", port: 3_000),
            ListenerRecord(processID: 106, processName: "node", userID: 502, host: "127.0.0.1", port: 4_000),
            ListenerRecord(
                processID: 107, processName: "redis-server", userID: 501, host: "127.0.0.1", port: 6_379),
            ListenerRecord(
                processID: 108, processName: "Google Chrome", userID: 501, host: "127.0.0.1", port: 9_222),
        ]
        let workingDirectories: [Int32: URL] = [
            101: fixture.developers.appendingPathComponent("public", isDirectory: true),
            102: fixture.website,
            103: fixture.service,
            104: fixture.developers,
            105: fixture.libraryProject,
            106: fixture.website,
            107: URL(fileURLWithPath: "/opt/homebrew/var/db/redis", isDirectory: true),
            108: fixture.developers,
        ]
        let processes: [Int32: ProcessRecord] = [
            101: ProcessRecord(
                processID: 101,
                userID: 501,
                startedAt: now,
                command: "symfony server:start --no-tls --port=8000"
            ),
            102: ProcessRecord(
                processID: 102,
                userID: 501,
                startedAt: now,
                command: "symfony server:start --no-tls --port=8001"
            ),
            103: ProcessRecord(processID: 103, userID: 501, startedAt: now, command: "redis-server *:6379"),
            104: ProcessRecord(processID: 104, userID: 501, startedAt: now, command: "php-fpm: master"),
            105: ProcessRecord(processID: 105, userID: 501, startedAt: now, command: "node server.js"),
            106: ProcessRecord(processID: 106, userID: 502, startedAt: now, command: "node server.js"),
            107: ProcessRecord(processID: 107, userID: 501, startedAt: now, command: "redis-server *:6379"),
            108: ProcessRecord(
                processID: 108,
                userID: 501,
                startedAt: now,
                command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222"
            ),
        ]

        let servers = discovery.makeServers(
            listeners: listeners,
            workingDirectories: workingDirectories,
            processes: processes
        )

        #expect(servers.map(\.projectName) == ["developers", "service", "website"])
        #expect(!(servers.contains { $0.port == 9_222 }))
        let developers = try #require(servers.first { $0.projectName == "developers" })
        #expect(developers.address == "localhost:8000")
        #expect(developers.browserURL?.absoluteString == "http://localhost:8000")
        #expect(developers.kind == .web)
        let service = try #require(servers.first { $0.projectName == "service" })
        #expect(service.kind == .service)
        #expect(service.browserURL == nil)
    }

    @Test func discoveryKeepsSurvivingProcessesWhenLsofReportsAPIDRace() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let discovery = LocalServerDiscovery(
            homeDirectory: fixture.home,
            currentUserID: 501,
            outputProvider: { executable, arguments, _ in
                if executable == "/usr/sbin/lsof", arguments.contains("-iTCP") {
                    return "p101\ncsymfony\nu501\nn127.0.0.1:8000\n"
                }
                if executable == "/usr/sbin/lsof" {
                    throw CommandExecutionError(
                        executable: executable,
                        exitCode: 1,
                        message: "p101\ncsymfony\nfcwd\nn\(fixture.developers.path)\n"
                    )
                }
                #expect(arguments == ["-axo", "pid=,uid=,lstart=,command="])
                return "101 501 Sat Aug  8 13:40:01 2026 symfony server:start --no-tls --port=8000\n"
            }
        )

        let servers = try await discovery.discover()
        #expect(servers.map(\.projectName) == ["developers"])
        #expect(servers.first?.browserURL?.absoluteString == "http://localhost:8000")
    }

    @Test func stopRevalidatesIdentityAndOnlySendsGracefulTermination() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let signal = SignalCapture()
        let discovery = LocalServerDiscovery(
            homeDirectory: fixture.home,
            currentUserID: 501,
            outputProvider: { executable, arguments, _ in
                if executable == "/usr/sbin/lsof", arguments.contains("-iTCP") {
                    return signal.wasSent
                        ? ""
                        : "p101\ncsymfony\nu501\nn127.0.0.1:8000\n"
                }
                if executable == "/usr/sbin/lsof" {
                    return "p101\ncsymfony\nfcwd\nn\(fixture.developers.path)\n"
                }
                return "101 501 Sat Aug  8 13:40:01 2026 symfony server:start --no-tls --port=8000\n"
            },
            signalSender: { processID, sentSignal in
                signal.record(processID: processID, signal: sentSignal)
                return 0
            }
        )
        let server = try #require(try await discovery.discover().first)

        try await discovery.stop(server)

        #expect(signal.processID == 101)
        #expect(signal.signal == SIGTERM)
    }

    @Test func stopValidationRejectsChangedOrForeignProcesses() {
        let server = RunningServer(
            processID: 101,
            userID: 501,
            processName: "symfony",
            command: "symfony server:start --no-tls --port=8000",
            projectName: "developers",
            projectPath: "/Users/example/code_vault/developers",
            host: "localhost",
            port: 8_000,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .web,
            scheme: "http"
        )
        let replacement = RunningServer(
            processID: server.processID,
            userID: server.userID,
            processName: server.processName,
            command: server.command,
            projectName: server.projectName,
            projectPath: server.projectPath,
            host: server.host,
            port: server.port,
            startedAt: server.startedAt.addingTimeInterval(1),
            kind: server.kind,
            scheme: server.scheme
        )
        let differentPort = RunningServer(
            processID: server.processID,
            userID: server.userID,
            processName: server.processName,
            command: server.command,
            projectName: server.projectName,
            projectPath: server.projectPath,
            host: server.host,
            port: 8_001,
            startedAt: server.startedAt,
            kind: server.kind,
            scheme: server.scheme
        )

        #expect {
            try LocalServerDiscovery.validateStopCandidate(requested: server, current: replacement, currentUserID: 501)
        } throws: { error in
            if case RunningServerControlError.processChanged = error { return true }
            return false
        }

        #expect(server.hasSameProcessIdentity(as: differentPort))
        #expect {
            try LocalServerDiscovery.validateStopCandidate(
                requested: server, current: differentPort, currentUserID: 501)
        } throws: { error in
            if case RunningServerControlError.processChanged = error { return true }
            return false
        }

        #expect {
            try LocalServerDiscovery.validateStopCandidate(requested: server, current: server, currentUserID: 502)
        } throws: { error in
            if case RunningServerControlError.notOwnedByCurrentUser = error { return true }
            return false
        }
    }
}

private struct ProjectFixture {
    let root: URL
    let home: URL
    let developers: URL
    let website: URL
    let service: URL
    let libraryProject: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseServers-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        developers = home.appendingPathComponent("code_vault/developers", isDirectory: true)
        website = home.appendingPathComponent("code_vault/website", isDirectory: true)
        service = home.appendingPathComponent("code_vault/service", isDirectory: true)
        libraryProject = home.appendingPathComponent("Library/Project", isDirectory: true)
        for directory in [
            developers.appendingPathComponent("public", isDirectory: true),
            website,
            service,
            libraryProject,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for marker in [
            developers.appendingPathComponent("composer.json"),
            website.appendingPathComponent("package.json"),
            service.appendingPathComponent(".git"),
            libraryProject.appendingPathComponent("package.json"),
        ] {
            _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SignalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedProcessID: Int32?
    private var capturedSignal: Int32?

    var processID: Int32? { lock.withLock { capturedProcessID } }
    var signal: Int32? { lock.withLock { capturedSignal } }
    var wasSent: Bool { lock.withLock { capturedSignal != nil } }

    func record(processID: Int32, signal: Int32) {
        lock.withLock {
            capturedProcessID = processID
            capturedSignal = signal
        }
    }
}
