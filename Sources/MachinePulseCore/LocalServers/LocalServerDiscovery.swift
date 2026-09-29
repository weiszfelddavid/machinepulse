import Darwin
import Foundation

public enum RunningServerControlError: LocalizedError, Sendable {
    case noLongerRunning
    case processChanged
    case notOwnedByCurrentUser
    case signalFailed(Int32)
    case didNotStop

    public var errorDescription: String? {
        switch self {
        case .noLongerRunning:
            "The server is no longer running."
        case .processChanged:
            "The process changed before MachinePulse could stop it. Refresh and try again."
        case .notOwnedByCurrentUser:
            "MachinePulse only stops local servers owned by the current user."
        case let .signalFailed(code):
            "The server could not be stopped: \(String(cString: strerror(code)))."
        case .didNotStop:
            "The server is still listening after a graceful stop request."
        }
    }
}

public struct LocalServerDiscovery: Sendable {
    typealias OutputProvider = @Sendable (String, [String], [String: String]?) async throws -> String
    typealias SignalSender = @Sendable (Int32, Int32) -> Int32
    typealias Pause = @Sendable (Duration) async -> Void

    private let homeDirectory: URL
    private let currentUserID: UInt32
    private let outputProvider: OutputProvider
    private let signalSender: SignalSender
    private let pause: Pause

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        currentUserID: UInt32 = getuid()
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.currentUserID = currentUserID
        self.outputProvider = { executable, arguments, environment in
            try await CommandRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 5
            ).outputString
        }
        self.signalSender = { processID, signal in kill(processID, signal) }
        self.pause = { duration in try? await Task.sleep(for: duration) }
    }

    init(
        homeDirectory: URL,
        currentUserID: UInt32,
        outputProvider: @escaping OutputProvider,
        signalSender: @escaping SignalSender = { _, _ in 0 },
        pause: @escaping Pause = { _ in }
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.currentUserID = currentUserID
        self.outputProvider = outputProvider
        self.signalSender = signalSender
        self.pause = pause
    }

    public func discover() async throws -> [RunningServer] {
        let listenerOutput: String
        do {
            listenerOutput = try await outputProvider(
                "/usr/sbin/lsof",
                ["+c", "0", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-FpcuPn"],
                nil
            )
        } catch let error as CommandExecutionError where error.exitCode == 1 {
            return []
        }

        let listeners = Self.parseListeners(listenerOutput)
            .filter { $0.userID == currentUserID && !Self.isExcludedProcessName($0.processName) }
        let processIDs = Array(Set(listeners.map(\.processID))).sorted()
        guard !processIDs.isEmpty else { return [] }

        let processList = processIDs.map(String.init).joined(separator: ",")
        async let workingDirectoryOutput = workingDirectoryOutput(for: processList)
        async let processOutput = outputProvider(
            "/bin/ps",
            ["-axo", "pid=,uid=,lstart=,command="],
            ["LC_ALL": "C"]
        )

        return makeServers(
            listeners: listeners,
            workingDirectories: Self.parseWorkingDirectories(try await workingDirectoryOutput),
            processes: Self.parseProcesses(try await processOutput)
        )
    }

    public func stop(_ server: RunningServer) async throws {
        let currentServers = try await discover()
        guard let current = currentServers.first(where: { $0.id == server.id }) else {
            throw RunningServerControlError.noLongerRunning
        }
        try Self.validateStopCandidate(requested: server, current: current, currentUserID: currentUserID)

        errno = 0
        guard signalSender(server.processID, SIGTERM) == 0 else {
            throw RunningServerControlError.signalFailed(errno)
        }

        for _ in 0..<6 {
            await pause(.milliseconds(500))
            let remainingServers = try await discover()
            if !remainingServers.contains(where: { $0.hasSameProcessIdentity(as: server) }) {
                return
            }
        }
        throw RunningServerControlError.didNotStop
    }

    static func validateStopCandidate(
        requested: RunningServer,
        current: RunningServer,
        currentUserID: UInt32
    ) throws {
        guard requested.userID == currentUserID, current.userID == currentUserID else {
            throw RunningServerControlError.notOwnedByCurrentUser
        }
        guard requested.hasSameProcessIdentity(as: current), requested.port == current.port else {
            throw RunningServerControlError.processChanged
        }
    }

    private func workingDirectoryOutput(for processList: String) async throws -> String {
        do {
            return try await outputProvider(
                "/usr/sbin/lsof",
                ["-nP", "-a", "-p", processList, "-d", "cwd", "-Fpcn"],
                nil
            )
        } catch let error as CommandExecutionError where error.exitCode == 1 {
            // lsof exits 1 when any requested PID disappears, but preserves the
            // records for processes that still exist in its output.
            return error.message
        }
    }

    func makeServers(
        listeners: [ListenerRecord],
        workingDirectories: [Int32: URL],
        processes: [Int32: ProcessRecord]
    ) -> [RunningServer] {
        var uniqueListeners: [String: ListenerRecord] = [:]
        for listener in listeners {
            let key = "\(listener.processID):\(listener.port)"
            if let existing = uniqueListeners[key] {
                if Self.hostPriority(listener.host) > Self.hostPriority(existing.host) {
                    uniqueListeners[key] = listener
                }
            } else {
                uniqueListeners[key] = listener
            }
        }

        return uniqueListeners.values.compactMap { listener in
            guard
                listener.userID == currentUserID,
                let workingDirectory = workingDirectories[listener.processID],
                let process = processes[listener.processID],
                process.userID == currentUserID,
                !Self.isExcludedProcessName(process.command),
                let projectRoot = projectRoot(containing: workingDirectory)
            else { return nil }

            let classification = Self.classify(
                processName: listener.processName,
                command: process.command,
                port: listener.port
            )
            return RunningServer(
                processID: listener.processID,
                userID: listener.userID,
                processName: listener.processName,
                command: process.command,
                projectName: projectRoot.lastPathComponent,
                projectPath: projectRoot.path,
                host: Self.displayHost(listener.host),
                port: listener.port,
                startedAt: process.startedAt,
                kind: classification.kind,
                scheme: classification.scheme
            )
        }.sorted {
            let comparison = $0.projectName.localizedCaseInsensitiveCompare($1.projectName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.processID < $1.processID
        }
    }

    private func projectRoot(containing workingDirectory: URL) -> URL? {
        var candidate = workingDirectory.standardizedFileURL
        let excludedRoots = [
            homeDirectory.appendingPathComponent("Library", isDirectory: true).path,
            homeDirectory.appendingPathComponent("Applications", isDirectory: true).path,
            "/Applications",
            "/Library",
            "/System",
            "/opt/homebrew",
            "/private/var",
            "/usr",
        ]
        guard !excludedRoots.contains(where: { Self.isDescendant(candidate.path, of: $0) }) else {
            return nil
        }

        for _ in 0..<12 {
            if candidate.path == homeDirectory.path { return nil }
            if Self.projectMarkers.contains(where: {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0).path)
            }) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        return nil
    }

    static func parseListeners(_ output: String) -> [ListenerRecord] {
        var processID: Int32?
        var processName: String?
        var userID: UInt32?
        var records: [ListenerRecord] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": processID = Int32(value)
            case "c": processName = value
            case "u": userID = UInt32(value)
            case "n":
                guard
                    let processID,
                    let processName,
                    let userID,
                    let endpoint = parseEndpoint(value)
                else { continue }
                records.append(
                    ListenerRecord(
                        processID: processID,
                        processName: processName,
                        userID: userID,
                        host: endpoint.host,
                        port: endpoint.port
                    )
                )
            default: continue
            }
        }
        return records
    }

    static func parseWorkingDirectories(_ output: String) -> [Int32: URL] {
        var processID: Int32?
        var values: [Int32: URL] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            if prefix == "p" {
                processID = Int32(value)
            } else if prefix == "n", let processID, value.hasPrefix("/") {
                values[processID] = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            }
        }
        return values
    }

    static func parseProcesses(_ output: String) -> [Int32: ProcessRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = false

        var values: [Int32: ProcessRecord] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 7, whereSeparator: \.isWhitespace)
            guard
                fields.count == 8,
                let processID = Int32(fields[0]),
                let userID = UInt32(fields[1]),
                let startedAt = formatter.date(
                    from: fields[2...6].map(String.init).joined(separator: " ")
                )
            else { continue }
            values[processID] = ProcessRecord(
                processID: processID,
                userID: userID,
                startedAt: startedAt,
                command: String(fields[7]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return values
    }

    private static func parseEndpoint(_ value: String) -> (host: String, port: UInt16)? {
        let host: String
        let portText: Substring
        if value.hasPrefix("["), let boundary = value.range(of: "]:") {
            host = String(value[value.index(after: value.startIndex)..<boundary.lowerBound])
            portText = value[boundary.upperBound...]
        } else if let separator = value.lastIndex(of: ":") {
            host = String(value[..<separator])
            portText = value[value.index(after: separator)...]
        } else {
            return nil
        }
        guard let port = UInt16(portText) else { return nil }
        return (host, port)
    }

    private static func classify(
        processName: String,
        command: String,
        port: UInt16
    ) -> (kind: RunningServerKind, scheme: String?) {
        let text = "\(processName) \(command)".lowercased()
        let webKeywords = [
            "symfony", "node", "bun", "deno", "vite", "next", "nuxt", "astro", "webpack",
            "http", "django", "flask", "uvicorn", "gunicorn", "puma", "rails", "laravel",
        ]
        guard webKeywords.contains(where: text.contains) else { return (.service, nil) }
        if text.contains("--no-tls") { return (.web, "http") }
        let usesTLS =
            text.contains("--tls") || text.contains("https") || text.contains("ssl")
            || port == 443 || port == 8443
        return (.web, usesTLS ? "https" : "http")
    }

    private static func displayHost(_ host: String) -> String {
        switch host.lowercased() {
        case "*", "0.0.0.0", "::", "::1", "127.0.0.1": "localhost"
        default: host
        }
    }

    private static func hostPriority(_ host: String) -> Int {
        switch displayHost(host) {
        case "localhost": 2
        default: 1
        }
    }

    private static func isExcludedProcessName(_ value: String) -> Bool {
        let name = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let excludedUtilities = [
            "php-fpm", "controlcenter", "rapportd", "raycast", "google drive", "cursor helper",
        ]
        if excludedUtilities.contains(where: name.contains) { return true }

        let browsers = [
            "google chrome", "chromium", "brave browser", "microsoft edge", "firefox", "safari", "arc",
        ]
        return browsers.contains { browser in
            name == browser
                || name.hasPrefix(browser + " helper")
                || name.hasPrefix(browser + " web content")
                || name.contains("/\(browser).app/contents/")
        }
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static let projectMarkers = [
        ".git", "Package.swift", "package.json", "composer.json", "pyproject.toml", "requirements.txt",
        "manage.py", "Gemfile", "go.mod", "Cargo.toml", "mix.exs", "pom.xml", "build.gradle",
    ]
}

struct ListenerRecord: Hashable, Sendable {
    let processID: Int32
    let processName: String
    let userID: UInt32
    let host: String
    let port: UInt16
}

struct ProcessRecord: Hashable, Sendable {
    let processID: Int32
    let userID: UInt32
    let startedAt: Date
    let command: String
}
