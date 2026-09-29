import Foundation
import MachinePulseCore

@main
enum MachinePulseVerifier {
    static func main() async throws {
        let devices = try await TailscaleDiscovery().discover()
        try require(!devices.isEmpty, "Tailscale discovery returned no devices")
        try require(devices.contains(where: \.isLocal), "Tailscale discovery did not identify this Mac")

        let localSource = LocalMacMetricSource(deviceID: "verification-mac")
        _ = try await localSource.collect()
        try await Task.sleep(for: .milliseconds(60))
        let localSample = try await localSource.collect()
        try require(localSample.memoryTotalBytes > 0, "Local memory collection failed")
        try require(localSample.memoryPressureLevel != nil, "Local memory pressure collection failed")
        try require((0...1).contains(localSample.memoryUsedFraction), "Local memory result is outside 0...100%")
        try require(localSample.diskTotalBytes > 0, "Local disk collection failed")
        try require((0...100).contains(localSample.cpuPercent), "Local CPU result is outside 0...100")

        let localServers = try await LocalServerDiscovery().discover()
        try require(
            Set(localServers.map(\.id)).count == localServers.count,
            "Local server discovery returned duplicate process/port identities"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseVerifier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MetricsStore(url: directory.appendingPathComponent("verify.sqlite3"))
        try await store.save(localSample)
        try await store.replaceCapacityRollups(
            deviceID: localSample.deviceID,
            hourStart: CapacityRollupBuilder.hour(containing: localSample.timestamp),
            with: CapacityRollupBuilder.build(samples: [localSample])
        )
        let restored = try await store.recentSamples(
            deviceID: localSample.deviceID,
            since: Date().addingTimeInterval(-60)
        )
        try require(restored.count == 1, "SQLite did not return the stored sample")
        let capacityRollups = try await store.recentCapacityRollups(
            deviceID: localSample.deviceID,
            since: .distantPast
        )
        try require(capacityRollups.count == 1, "SQLite did not keep the hourly capacity rollup")
        try require(
            capacityRollups.first?.sampleCount == 1,
            "The hourly capacity rollup did not retain its observation count"
        )
        if ProcessInfo.processInfo.environment["MACHINEPULSE_VERIFY_DISK_SCAN"] != nil {
            let scan = try LocalDiskScanner.scan(deviceID: "verification-mac")
            try require(scan.totalBytes > 0, "Local disk scan measured nothing")
            try require(!scan.root.children.isEmpty, "Local disk scan retained no entries")
            _ = try JSONDecoder().decode(DiskScan.self, from: JSONEncoder().encode(scan))
            print(
                "  Local disk scan: \(SizeFormat.bytes(scan.totalBytes)) in \(SizeFormat.count(scan.fileCount)) files, "
                    + "\(scan.findings.count) findings, \(String(format: "%.1f", scan.durationSeconds)) s, "
                    + "\(scan.unreadableCount) unreadable, full disk access \(scan.fullDiskAccess.map(String.init) ?? "unknown")"
            )
            if let target = ProcessInfo.processInfo.environment["MACHINEPULSE_SSH_TARGET"] {
                let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Sources/MachinePulseApp/Resources/collector.sh")
                let remote = try await SSHDiskScanner(target: target, collectorScript: Data(contentsOf: scriptURL))
                    .scan(deviceID: "verification-remote")
                try require(remote.totalBytes > 0, "Remote disk scan measured nothing")
                print(
                    "  Remote disk scan: \(SizeFormat.bytes(remote.totalBytes)) in \(SizeFormat.count(remote.fileCount)) files, "
                        + "\(remote.findings.count) findings, \(String(format: "%.1f", remote.durationSeconds)) s, "
                        + "\(remote.scannerVersion)"
                )
            }
        }

        if let databaseCopy = ProcessInfo.processInfo.environment["MACHINEPULSE_VERIFY_DATABASE_COPY"] {
            let copiedStore = try MetricsStore(url: URL(fileURLWithPath: databaseCopy))
            try await copiedStore.backfillCapacityRollupsIfNeeded()
            let capacityStorage = try await copiedStore.capacityRollupStorage()
            try require(
                capacityStorage.payloadBytes <= MetricsStore.capacityRollupPayloadBudgetBytes,
                "Capacity rollups exceeded their encoded-payload budget"
            )
            print(
                "  Existing database copy opened and migrated in place: \(capacityStorage.rowCount) bounded rollups"
            )
        }

        print("MachinePulse verification passed")
        print("  Tailnet devices: \(devices.count)")
        print("  Local CPU: \(String(format: "%.1f%%", localSample.cpuPercent))")
        print("  Local memory used: \(String(format: "%.1f%%", localSample.memoryUsedFraction * 100))")
        print("  Local project servers: \(localServers.count)")
        for server in localServers {
            print("    \(server.projectName): \(server.address) (\(server.processName))")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError(message: message) }
    }
}

private struct VerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
