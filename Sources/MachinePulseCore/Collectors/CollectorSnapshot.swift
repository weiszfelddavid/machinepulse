import Foundation

/// One JSON document from the bundled collector, on Linux or macOS.
public struct CollectorSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let hostname: String
    public let uptimeSeconds: TimeInterval
    public let cpuPercent: Double
    public let logicalCPUCount: Int
    public let loadAverage1: Double
    public let loadAverage5: Double
    public let loadAverage15: Double
    public let memoryTotalBytes: UInt64
    public let memoryAvailableBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let diskTotalBytes: UInt64
    public let diskUsedBytes: UInt64
    public let diskReadBytesTotal: UInt64
    public let diskWriteBytesTotal: UInt64
    public let networkReceiveBytesTotal: UInt64
    public let networkTransmitBytesTotal: UInt64
    public let swapInBytesTotal: UInt64?
    public let swapOutBytesTotal: UInt64?
    public let cpuPressure: PressureMetric?
    public let memoryPressure: PressureMetric?
    public let memoryPressureLevel: MemoryPressureLevel?
    public let ioPressure: PressureMetric?
    public let topCPUProcesses: [ProcessMetric]
    public let topMemoryProcesses: [ProcessMetric]
    public let topIOProcesses: [ProcessIOMetric]?
    public let failedServices: [ServiceMetric]
    public let expectedUnits: [ExpectedUnitMetric]?
    public let remoteWorkloads: [RemoteWorkloadMetric]?
    public let workloadResourceControls: [WorkloadResourceControlMetric]?
    public let oomKillCount: Int
    public let lastOOMKillAt: Date?
    public let oomCollectionStatus: OOMCollectionStatus?
    public let latestOOMEvent: OOMEventMetric?
    public let oomKillMark: String?
    public let oomEvidenceUnchanged: Bool?
    public let bootID: String?
    public let collectorVersion: String?
    public let rootFilesystemID: String?
}
