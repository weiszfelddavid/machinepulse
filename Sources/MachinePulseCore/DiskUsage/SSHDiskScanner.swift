import Foundation

/// Runs the bundled collector's disk-scan mode over the same multiplexed
/// SSH connection the metric sampler uses. A scan walks a whole home
/// directory, so it is started by the user and given minutes, not seconds.
public actor SSHDiskScanner {
    private static let timeout: TimeInterval = 15 * 60
    private static let preamble = SSHTransport.shellExport("MACHINEPULSE_MODE", "disk-scan")

    private let target: String
    private let collectorScript: Data

    public init(target: String, collectorScript: Data) {
        self.target = target
        self.collectorScript = collectorScript
    }

    public func scan(deviceID: String) async throws -> DiskScan {
        var input = Data(Self.preamble.utf8)
        input.append(collectorScript)
        let output = try await SSHTransport.run(
            target: target,
            input: input,
            timeout: Self.timeout,
            timeoutMessage: "The disk scan did not finish in time and was terminated."
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(DiskScanSnapshot.self, from: output).scan(deviceID: deviceID)
        } catch {
            throw MetricSourceError.invalidPayload(FailureSanitizer.sanitize(error.localizedDescription))
        }
    }
}
