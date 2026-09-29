import Foundation

public actor SSHMetricSource: MetricSource {
    public nonisolated let deviceID: String

    private let target: String
    private let collectorScript: Data
    private let expectedUnits: [ExpectedSystemdUnit]
    private var previousSnapshot: CollectorSnapshot?
    private var previousOOMContext: OOMContext?

    public init(
        deviceID: String,
        target: String,
        collectorScript: Data,
        expectedUnits: [ExpectedSystemdUnit] = []
    ) {
        self.deviceID = deviceID
        self.target = target
        self.collectorScript = collectorScript
        self.expectedUnits = Array(expectedUnits.prefix(ExpectedSystemdUnit.maxWatchlistCount))
    }

    public func collect() async throws -> MetricSample {
        let output = try await SSHTransport.run(
            target: target,
            input: collectorInput(),
            timeout: 30,
            timeoutMessage: "The collection attempt timed out and was terminated."
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot: CollectorSnapshot
        do {
            snapshot = try decoder.decode(CollectorSnapshot.self, from: output)
        } catch {
            throw MetricSourceError.invalidPayload(FailureSanitizer.sanitize(error.localizedDescription))
        }

        let rates = Self.calculateRates(current: snapshot, previous: previousSnapshot)
        let oom = Self.resolveOOMContext(snapshot: snapshot, previous: previousOOMContext)
        previousSnapshot = snapshot
        previousOOMContext = oom

        return MetricSample(
            deviceID: deviceID,
            timestamp: snapshot.timestamp,
            hostname: snapshot.hostname,
            uptimeSeconds: snapshot.uptimeSeconds,
            cpuPercent: snapshot.cpuPercent,
            logicalCPUCount: snapshot.logicalCPUCount,
            loadAverage1: snapshot.loadAverage1,
            loadAverage5: snapshot.loadAverage5,
            loadAverage15: snapshot.loadAverage15,
            memoryTotalBytes: snapshot.memoryTotalBytes,
            memoryAvailableBytes: snapshot.memoryAvailableBytes,
            swapTotalBytes: snapshot.swapTotalBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            diskTotalBytes: snapshot.diskTotalBytes,
            diskUsedBytes: snapshot.diskUsedBytes,
            diskReadBytesPerSecond: rates.diskRead,
            diskWriteBytesPerSecond: rates.diskWrite,
            networkReceiveBytesPerSecond: rates.networkReceive,
            networkTransmitBytesPerSecond: rates.networkTransmit,
            cpuPressure: snapshot.cpuPressure,
            memoryPressure: snapshot.memoryPressure,
            memoryPressureLevel: snapshot.memoryPressureLevel,
            ioPressure: snapshot.ioPressure,
            swapInBytesPerSecond: rates.swapIn,
            swapOutBytesPerSecond: rates.swapOut,
            topCPUProcesses: snapshot.topCPUProcesses,
            topMemoryProcesses: snapshot.topMemoryProcesses,
            topIOProcesses: snapshot.topIOProcesses,
            failedServices: snapshot.failedServices,
            expectedUnits: snapshot.expectedUnits,
            remoteWorkloads: snapshot.remoteWorkloads,
            workloadResourceControls: snapshot.workloadResourceControls,
            oomKillCount: oom.killCount,
            lastOOMKillAt: oom.lastKillAt,
            oomCollectionStatus: oom.collectionStatus,
            latestOOMEvent: oom.latestEvent,
            bootID: snapshot.bootID,
            collectorVersion: snapshot.collectorVersion,
            rootFilesystemID: snapshot.rootFilesystemID
        )
    }

    /// Journal evidence is reused while the remote kernel's OOM kill counter
    /// is unchanged; a collector that reports the evidence as unchanged has
    /// not read the journal, so the previous evidence remains current.
    public static func resolveOOMContext(snapshot: CollectorSnapshot, previous: OOMContext?) -> OOMContext {
        if snapshot.oomEvidenceUnchanged == true, let previous {
            return OOMContext(
                killCount: previous.killCount,
                lastKillAt: previous.lastKillAt,
                collectionStatus: previous.collectionStatus,
                latestEvent: previous.latestEvent,
                mark: snapshot.oomKillMark
            )
        }
        return OOMContext(
            killCount: snapshot.oomKillCount,
            lastKillAt: snapshot.lastOOMKillAt,
            collectionStatus: snapshot.oomCollectionStatus,
            latestEvent: snapshot.latestOOMEvent,
            mark: snapshot.oomKillMark
        )
    }

    static func collectorPreamble(expectedUnits: [ExpectedSystemdUnit], oomKillMark: String?) -> String {
        var preamble = ""
        if !expectedUnits.isEmpty, let encoded = try? JSONEncoder().encode(expectedUnits) {
            preamble += SSHTransport.shellExport("MACHINEPULSE_EXPECTED_UNITS_B64", encoded.base64EncodedString())
        }
        if let oomKillMark, OOMContext.isValidMark(oomKillMark) {
            preamble += SSHTransport.shellExport("MACHINEPULSE_OOM_KILL_MARK", oomKillMark)
        }
        return preamble
    }

    private func collectorInput() -> Data {
        var input = Data(
            Self.collectorPreamble(expectedUnits: expectedUnits, oomKillMark: previousOOMContext?.reusableMark).utf8
        )
        input.append(collectorScript)
        return input
    }

    struct CounterRates {
        var diskRead: Double = 0
        var diskWrite: Double = 0
        var networkReceive: Double = 0
        var networkTransmit: Double = 0
        var swapIn: Double?
        var swapOut: Double?
    }

    static func calculateRates(current: CollectorSnapshot, previous: CollectorSnapshot?) -> CounterRates {
        guard
            let previous,
            previous.bootID == current.bootID,
            current.timestamp > previous.timestamp
        else {
            return CounterRates()
        }

        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        func rate(_ new: UInt64, _ old: UInt64) -> Double {
            guard new >= old else { return 0 }
            return Double(new - old) / interval
        }
        func optionalRate(_ new: UInt64?, _ old: UInt64?) -> Double? {
            guard let new, let old else { return nil }
            return rate(new, old)
        }

        return CounterRates(
            diskRead: rate(current.diskReadBytesTotal, previous.diskReadBytesTotal),
            diskWrite: rate(current.diskWriteBytesTotal, previous.diskWriteBytesTotal),
            networkReceive: rate(current.networkReceiveBytesTotal, previous.networkReceiveBytesTotal),
            networkTransmit: rate(current.networkTransmitBytesTotal, previous.networkTransmitBytesTotal),
            swapIn: optionalRate(current.swapInBytesTotal, previous.swapInBytesTotal),
            swapOut: optionalRate(current.swapOutBytesTotal, previous.swapOutBytesTotal)
        )
    }
}

public struct OOMContext: Sendable, Equatable {
    public let killCount: Int
    public let lastKillAt: Date?
    public let collectionStatus: OOMCollectionStatus?
    public let latestEvent: OOMEventMetric?
    public let mark: String?

    public init(
        killCount: Int,
        lastKillAt: Date?,
        collectionStatus: OOMCollectionStatus?,
        latestEvent: OOMEventMetric?,
        mark: String?
    ) {
        self.killCount = killCount
        self.lastKillAt = lastKillAt
        self.collectionStatus = collectionStatus
        self.latestEvent = latestEvent
        self.mark = mark
    }

    /// Only evidence that was actually read can be reused; an unavailable
    /// journal is retried on the next sample.
    public var reusableMark: String? {
        collectionStatus == .available ? mark : nil
    }

    public static func isValidMark(_ mark: String) -> Bool {
        !mark.isEmpty && mark.count <= 96
            && mark.allSatisfy { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }
    }
}
