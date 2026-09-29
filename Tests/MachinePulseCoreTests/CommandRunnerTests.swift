import Foundation
import Testing
@testable import MachinePulseCore

struct CommandRunnerTests {
    @Test func aTimedOutCommandIsATransportFailureNotAnUnreachableMachine() async throws {
        let error = await #expect(throws: CommandExecutionError.self) {
            try await CommandRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        }
        let timedOut = try #require(error)
        #expect(timedOut.timedOut)
        let failure = MetricCollectionFailure(error: MetricSourceError.sshTransport(timedOut.localizedDescription))
        guard case .sshUnavailable = failure else {
            Issue.record("a timeout was not classified as an SSH transport failure")
            return
        }
    }

    @Test func outputAndExitStatusesComeBackAsIs() async throws {
        let result = try await CommandRunner.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5)
        #expect(result.outputString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")

        let error = await #expect(throws: CommandExecutionError.self) {
            try await CommandRunner.run(executable: "/usr/bin/false", timeout: 5)
        }
        #expect(error?.timedOut == false)
        #expect(error?.exitCode == 1)
    }
}
