import Foundation
import Testing
@testable import MachinePulseCore

struct SSHMetricSourceTests {
    @Test func unchangedEvidenceReusesThePreviousJournalContext() throws {
        let previous = OOMContext(
            killCount: 3,
            lastKillAt: Date(timeIntervalSince1970: 1_700_000_000),
            collectionStatus: .available,
            latestEvent: OOMEventMetric(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000), victimProcess: "postgres"),
            mark: "boot-1:3"
        )
        let unchanged = try snapshot(oom: ["oomKillCount": 0, "oomEvidenceUnchanged": true, "oomKillMark": "boot-1:3"])
        let resolved = SSHMetricSource.resolveOOMContext(snapshot: unchanged, previous: previous)
        #expect(resolved.killCount == 3)
        #expect(resolved.latestEvent?.victimProcess == "postgres")
        #expect(resolved.collectionStatus == .available)
        #expect(resolved.mark == "boot-1:3")
    }

    @Test func freshEvidenceReplacesThePreviousContext() throws {
        let previous = OOMContext(
            killCount: 3, lastKillAt: nil, collectionStatus: .available, latestEvent: nil, mark: "boot-1:3")
        let fresh = try snapshot(oom: [
            "oomEvidenceUnchanged": false, "oomKillMark": "boot-1:4", "oomKillCount": 4,
            "oomCollectionStatus": "available",
        ])
        let resolved = SSHMetricSource.resolveOOMContext(snapshot: fresh, previous: previous)
        #expect(resolved.killCount == 4)
        #expect(resolved.mark == "boot-1:4")

        let legacy = try snapshot(oom: ["oomKillCount": 1, "oomCollectionStatus": "available"])
        #expect(SSHMetricSource.resolveOOMContext(snapshot: legacy, previous: previous).killCount == 1)
        #expect(SSHMetricSource.resolveOOMContext(snapshot: legacy, previous: previous).mark == nil)
    }

    @Test func unchangedEvidenceWithoutPreviousContextFallsBackToTheSnapshot() throws {
        let unchanged = try snapshot(oom: ["oomKillCount": 0, "oomEvidenceUnchanged": true, "oomKillMark": "boot-1:3"])
        let resolved = SSHMetricSource.resolveOOMContext(snapshot: unchanged, previous: nil)
        #expect(resolved.killCount == 0)
        #expect(resolved.collectionStatus == nil)
    }

    @Test func onlyAvailableJournalEvidenceIsReusedAndMarksAreValidated() {
        let available = OOMContext(
            killCount: 0, lastKillAt: nil, collectionStatus: .available, latestEvent: nil, mark: "boot-1:0")
        let unavailable = OOMContext(
            killCount: 0, lastKillAt: nil, collectionStatus: .unavailable, latestEvent: nil, mark: "boot-1:0")
        #expect(available.reusableMark == "boot-1:0")
        #expect(unavailable.reusableMark == nil)

        let preamble = SSHMetricSource.collectorPreamble(expectedUnits: [], oomKillMark: "boot-1:0")
        #expect(preamble == "MACHINEPULSE_OOM_KILL_MARK='boot-1:0'\nexport MACHINEPULSE_OOM_KILL_MARK\n")
        #expect(SSHMetricSource.collectorPreamble(expectedUnits: [], oomKillMark: "boot'; rm -rf /") == "")
        #expect(SSHMetricSource.collectorPreamble(expectedUnits: [], oomKillMark: nil) == "")

        let units = [ExpectedSystemdUnit(name: "api.service")].compactMap { $0 }
        let combined = SSHMetricSource.collectorPreamble(expectedUnits: units, oomKillMark: "boot-1:0")
        #expect(combined.hasPrefix("MACHINEPULSE_EXPECTED_UNITS_B64='"))
        #expect(combined.hasSuffix("export MACHINEPULSE_OOM_KILL_MARK\n"))
    }

    @Test func sshInvocationMultiplexesConnections() {
        let directory = URL(fileURLWithPath: "/tmp/machinepulse-ssh")
        let arguments = SSHTransport.arguments(target: "vps-alias", controlDirectory: directory)
        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPersist=60s"))
        #expect(arguments.contains("ControlPath=/tmp/machinepulse-ssh/%C"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("Compression=yes"))
        #expect(arguments.suffix(3) == ["vps-alias", "sh", "-s"])
    }

    @Test func counterRatesNeedTheSameBootAndMonotonicCounters() throws {
        let previous = try snapshot(
            timestamp: 1_700_000_000, bootID: "boot-1", diskReadBytesTotal: 1_000, swapInBytesTotal: 100)
        let later = try snapshot(
            timestamp: 1_700_000_010, bootID: "boot-1", diskReadBytesTotal: 6_000, swapInBytesTotal: 100)
        let rates = SSHMetricSource.calculateRates(current: later, previous: previous)
        #expect(rates.diskRead == 500)
        #expect(rates.swapIn == 0)
        #expect(rates.networkReceive == 0)

        let rebooted = try snapshot(timestamp: 1_700_000_010, bootID: "boot-2", diskReadBytesTotal: 6_000)
        #expect(SSHMetricSource.calculateRates(current: rebooted, previous: previous).diskRead == 0)
        let wrapped = try snapshot(timestamp: 1_700_000_010, bootID: "boot-1", diskReadBytesTotal: 500)
        #expect(SSHMetricSource.calculateRates(current: wrapped, previous: previous).diskRead == 0)
        #expect(SSHMetricSource.calculateRates(current: wrapped, previous: previous).swapIn == nil)
        #expect(SSHMetricSource.calculateRates(current: later, previous: nil).diskRead == 0)
    }

    private func snapshot(
        timestamp: Int = 1_700_000_000,
        bootID: String? = nil,
        diskReadBytesTotal: UInt64 = 0,
        swapInBytesTotal: UInt64? = nil,
        oom: [String: Any] = [:]
    ) throws -> CollectorSnapshot {
        var fields: [String: Any] = [
            "timestamp": timestamp, "hostname": "vps", "uptimeSeconds": 10, "cpuPercent": 1, "logicalCPUCount": 1,
            "loadAverage1": 0, "loadAverage5": 0, "loadAverage15": 0, "memoryTotalBytes": 1,
            "memoryAvailableBytes": 1, "swapTotalBytes": 0, "swapUsedBytes": 0, "diskTotalBytes": 1,
            "diskUsedBytes": 0, "diskReadBytesTotal": diskReadBytesTotal, "diskWriteBytesTotal": 0,
            "networkReceiveBytesTotal": 0, "networkTransmitBytesTotal": 0, "topCPUProcesses": [],
            "topMemoryProcesses": [], "failedServices": [], "oomKillCount": 0,
        ]
        fields["bootID"] = bootID
        fields["swapInBytesTotal"] = swapInBytesTotal
        fields.merge(oom) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(CollectorSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
