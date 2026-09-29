import Foundation

public struct CommandResult: Sendable {
    public let standardOutput: Data

    public var outputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }
}

public struct CommandExecutionError: LocalizedError, Sendable {
    public let executable: String
    public let exitCode: Int32
    public let message: String
    public let timedOut: Bool

    public init(executable: String, exitCode: Int32, message: String, timedOut: Bool = false) {
        self.executable = executable
        self.exitCode = exitCode
        self.message = message
        self.timedOut = timedOut
    }

    public var errorDescription: String? {
        if timedOut {
            return "\(executable) did not finish in time and was terminated."
        }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "\(executable) exited with status \(exitCode)."
            : detail
    }
}

public enum CommandRunner {
    public static let defaultTimeout: TimeInterval = 30

    /// Runs a child process without blocking the Swift cooperative thread
    /// pool. The timeout is a hard deadline: the process receives SIGTERM at
    /// the deadline and SIGKILL two seconds later. Cancelling the calling task
    /// terminates the process the same way.
    public static func run(
        executable: String,
        arguments: [String] = [],
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = CommandRunner.defaultTimeout
    ) async throws -> CommandResult {
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            environment: environment
        )
        return try await withTaskCancellationHandler {
            try await execution.run(timeout: timeout)
        } onCancel: {
            execution.terminate()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let executable: String
    private let arguments: [String]
    private let standardInput: Data?
    private let environment: [String: String]?
    private let lock = NSLock()
    private var timedOut = false

    init(
        executable: String,
        arguments: [String],
        standardInput: Data?,
        environment: [String: String]?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
    }

    func run(timeout: TimeInterval) async throws -> CommandResult {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if standardInput != nil {
            process.standardInput = inputPipe
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outputData = LockedData()
        let errorData = LockedData()
        let completion = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)

        completion.enter()
        queue.async {
            outputData.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            completion.leave()
        }
        completion.enter()
        queue.async {
            errorData.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            completion.leave()
        }

        completion.enter()
        process.terminationHandler = { _ in completion.leave() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            completion.leave()
            throw error
        }

        if let standardInput {
            queue.async {
                inputPipe.fileHandleForWriting.write(standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let deadline = DispatchWorkItem { [weak self] in
            self?.markTimedOutAndTerminate()
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.notify(queue: queue) {
                continuation.resume()
            }
        }
        deadline.cancel()

        let exitCode = process.terminationStatus
        let wasTimedOut = lock.withLock { timedOut }

        if wasTimedOut {
            throw CommandExecutionError(
                executable: executable,
                exitCode: exitCode,
                message: "Timed out after the configured deadline.",
                timedOut: true
            )
        }
        guard exitCode == 0 else {
            let standardError = String(decoding: errorData.value, as: UTF8.self)
            throw CommandExecutionError(
                executable: executable,
                exitCode: exitCode,
                message: standardError.isEmpty ? String(decoding: outputData.value, as: UTF8.self) : standardError
            )
        }
        return CommandResult(standardOutput: outputData.value)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let processID = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(processID, SIGKILL)
        }
    }

    private func markTimedOutAndTerminate() {
        lock.lock()
        let isRunning = process.isRunning
        if isRunning { timedOut = true }
        lock.unlock()
        if isRunning { terminate() }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

public enum ExecutableLocator {
    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    public static var tailscale: String? {
        firstExisting([
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/bin/tailscale",
        ])
    }

    public static let ssh = "/usr/bin/ssh"
}
