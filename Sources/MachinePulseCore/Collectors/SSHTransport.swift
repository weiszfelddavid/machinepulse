import Foundation

/// Runs the bundled collector on a remote machine over the user's own SSH
/// setup and classifies how the run ended.
enum SSHTransport {
    /// OpenSSH reserves exit status 255 for its own transport, configuration,
    /// and authentication failures; any other status came from the remote
    /// command itself.
    private static let transportExitCode: Int32 = 255

    /// Multiplexing socket directory. Unix socket paths are limited to 104
    /// bytes and `%C` expands to a fixed 40-character hash, so the base must
    /// stay short; the user temporary directory under /var/folders does not
    /// fit, a per-uid /tmp directory with 0700 permissions does.
    static func controlSocketDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/machinepulse-ssh-\(getuid())", isDirectory: true)
    }

    /// One multiplexed connection per machine while sampling continues; the
    /// master closes after a minute of idle, so stopping monitoring tears the
    /// connection down on its own. The script goes up on every sample and
    /// shrinks four times under compression; the JSON coming back, eight.
    static func arguments(target: String, controlDirectory: URL) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "ClearAllForwardings=yes",
            "-o", "Compression=yes",
            "-o", "LogLevel=ERROR",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlDirectory.path)/%C",
            "-o", "ControlPersist=60s",
            target,
            "sh", "-s",
        ]
    }

    /// A line of the environment preamble that precedes the script on the
    /// remote shell's standard input.
    static func shellExport(_ name: String, _ value: String) -> String {
        "\(name)='\(value)'\nexport \(name)\n"
    }

    static func run(target: String, input: Data, timeout: TimeInterval, timeoutMessage: String) async throws
        -> Data
    {
        let controlDirectory = controlSocketDirectory()
        try? FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            return try await CommandRunner.run(
                executable: ExecutableLocator.ssh,
                arguments: arguments(target: target, controlDirectory: controlDirectory),
                standardInput: input,
                environment: ["LC_ALL": "C"],
                timeout: timeout
            ).standardOutput
        } catch let error as CommandExecutionError {
            if error.timedOut { throw MetricSourceError.sshTransport(timeoutMessage) }
            let detail = FailureSanitizer.sanitize(
                error.message.isEmpty ? "ssh exited with status \(error.exitCode)." : error.message)
            if error.exitCode == transportExitCode { throw MetricSourceError.sshTransport(detail) }
            throw MetricSourceError.collectorExit(code: error.exitCode, detail)
        } catch {
            throw MetricSourceError.sshTransport(FailureSanitizer.sanitize(error.localizedDescription))
        }
    }
}
