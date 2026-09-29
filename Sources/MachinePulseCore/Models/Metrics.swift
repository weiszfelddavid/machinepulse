import Foundation

public struct ProcessMetric: Codable, Hashable, Sendable {
    public let name: String
    public let cpuPercent: Double
    public let residentBytes: UInt64

    public init(
        name: String,
        cpuPercent: Double,
        residentBytes: UInt64
    ) {
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public struct ProcessIOMetric: Codable, Hashable, Sendable {
    public let name: String
    public let systemdUnit: String?
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(
        name: String,
        systemdUnit: String? = nil,
        readBytesPerSecond: Double,
        writeBytesPerSecond: Double
    ) {
        self.name = name
        self.systemdUnit = systemdUnit
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }

    public var totalBytesPerSecond: Double {
        readBytesPerSecond + writeBytesPerSecond
    }
}

public enum WorkloadListenerBinding: String, Codable, Hashable, Sendable {
    case loopback
    case tailnet
    case publicAddress
    case privateNetwork
    case allInterfaces
    case unknown
}

public enum WorkloadWebProtocol: String, Codable, Hashable, Sendable {
    case http
    case https
}

public struct WorkloadListenerMetric: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(address):\(port)" }
    public let address: String
    public let port: UInt16
    public let binding: WorkloadListenerBinding
    public let webProtocol: WorkloadWebProtocol?

    public init(
        address: String,
        port: UInt16,
        binding: WorkloadListenerBinding,
        webProtocol: WorkloadWebProtocol? = nil
    ) {
        self.address = address
        self.port = port
        self.binding = binding
        self.webProtocol = webProtocol
    }

    public var displayAddress: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

public struct RemoteWorkloadMetric: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let processName: String?
    public let systemdUnit: String?
    public let state: ExpectedUnitState
    public let substate: String?
    public let uptimeSeconds: TimeInterval?
    public let listeners: [WorkloadListenerMetric]

    public init(
        id: String,
        name: String,
        processName: String? = nil,
        systemdUnit: String? = nil,
        state: ExpectedUnitState,
        substate: String? = nil,
        uptimeSeconds: TimeInterval? = nil,
        listeners: [WorkloadListenerMetric] = []
    ) {
        self.id = id
        self.name = name
        self.processName = processName
        self.systemdUnit = systemdUnit
        self.state = state
        self.substate = substate
        self.uptimeSeconds = uptimeSeconds
        self.listeners = listeners
    }

    /// A browser URL is offered only for a recognized web listener whose
    /// binding supplies a concrete host or explicitly includes the tailnet
    /// interface. Loopback, private, and ambiguous bindings stay copy-only.
    public func browserURL(for device: MachineDevice) -> URL? {
        guard device.isOnline,
            let listener = listeners.first(where: {
                guard $0.webProtocol != nil else { return false }
                return $0.binding == .tailnet
                    || $0.binding == .publicAddress
                    || $0.binding == .allInterfaces
            }),
            let webProtocol = listener.webProtocol
        else { return nil }

        let host: String?
        switch listener.binding {
        case .tailnet, .publicAddress:
            host = listener.address
        case .allInterfaces:
            host =
                device.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                ?? device.addresses.first(where: { address in
                    address.hasPrefix("100.") || address.lowercased().hasPrefix("fd7a:115c:a1e0:")
                })
        case .loopback, .privateNetwork, .unknown:
            host = nil
        }
        guard let host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = webProtocol.rawValue
        components.host = host
        components.port = Int(listener.port)
        return components.url
    }
}

public enum WorkloadResourceAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case unsupported
}

public struct WorkloadResourceValueMetric: Codable, Hashable, Sendable {
    public let availability: WorkloadResourceAvailability
    public let value: UInt64?

    public init(
        availability: WorkloadResourceAvailability,
        value: UInt64? = nil
    ) {
        self.availability = availability
        self.value = availability == .available ? value : nil
    }
}

public enum WorkloadResourceLimitState: String, Codable, Hashable, Sendable {
    case configured
    case unlimited
    case unavailable
    case unsupported
}

public struct WorkloadResourceLimitMetric: Codable, Hashable, Sendable {
    public let state: WorkloadResourceLimitState
    public let value: UInt64?

    public init(
        state: WorkloadResourceLimitState,
        value: UInt64? = nil
    ) {
        self.state = state
        self.value = state == .configured ? value : nil
    }
}

public struct WorkloadCPUQuotaMetric: Codable, Hashable, Sendable {
    public let state: WorkloadResourceLimitState
    public let quotaMicroseconds: UInt64?
    public let periodMicroseconds: UInt64?

    public init(
        state: WorkloadResourceLimitState,
        quotaMicroseconds: UInt64? = nil,
        periodMicroseconds: UInt64? = nil
    ) {
        self.state = state
        self.quotaMicroseconds = state == .configured ? quotaMicroseconds : nil
        self.periodMicroseconds =
            state == .configured || state == .unlimited ? periodMicroseconds : nil
    }
}

public struct WorkloadPressureMetric: Codable, Hashable, Sendable {
    public let availability: WorkloadResourceAvailability
    public let someAverage10: Double?
    public let fullAverage10: Double?

    public init(
        availability: WorkloadResourceAvailability,
        someAverage10: Double? = nil,
        fullAverage10: Double? = nil
    ) {
        self.availability = availability
        self.someAverage10 = availability == .available ? someAverage10 : nil
        self.fullAverage10 = availability == .available ? fullAverage10 : nil
    }
}

public struct WorkloadMemoryEventsMetric: Codable, Hashable, Sendable {
    public let high: WorkloadResourceValueMetric
    public let max: WorkloadResourceValueMetric
    public let oom: WorkloadResourceValueMetric
    public let oomKill: WorkloadResourceValueMetric

    public init(
        high: WorkloadResourceValueMetric,
        max: WorkloadResourceValueMetric,
        oom: WorkloadResourceValueMetric,
        oomKill: WorkloadResourceValueMetric
    ) {
        self.high = high
        self.max = max
        self.oom = oom
        self.oomKill = oomKill
    }
}

public struct WorkloadCPUStatMetric: Codable, Hashable, Sendable {
    public let usageMicroseconds: WorkloadResourceValueMetric
    public let userMicroseconds: WorkloadResourceValueMetric
    public let systemMicroseconds: WorkloadResourceValueMetric
    public let periods: WorkloadResourceValueMetric
    public let throttledPeriods: WorkloadResourceValueMetric
    public let throttledMicroseconds: WorkloadResourceValueMetric

    public init(
        usageMicroseconds: WorkloadResourceValueMetric,
        userMicroseconds: WorkloadResourceValueMetric,
        systemMicroseconds: WorkloadResourceValueMetric,
        periods: WorkloadResourceValueMetric,
        throttledPeriods: WorkloadResourceValueMetric,
        throttledMicroseconds: WorkloadResourceValueMetric
    ) {
        self.usageMicroseconds = usageMicroseconds
        self.userMicroseconds = userMicroseconds
        self.systemMicroseconds = systemMicroseconds
        self.periods = periods
        self.throttledPeriods = throttledPeriods
        self.throttledMicroseconds = throttledMicroseconds
    }
}

/// A bounded, read-only snapshot of one relevant cgroup v2 workload. Values
/// are cumulative kernel counters or current controls, never inferred policy.
public struct WorkloadResourceControlMetric: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let systemdUnit: String?
    public let cgroupPath: String?
    public let availability: WorkloadResourceAvailability
    public let memoryCurrentBytes: WorkloadResourceValueMetric
    public let memoryPeakBytes: WorkloadResourceValueMetric
    public let memoryHigh: WorkloadResourceLimitMetric
    public let memoryMax: WorkloadResourceLimitMetric
    public let memoryEvents: WorkloadMemoryEventsMetric
    public let cpuQuota: WorkloadCPUQuotaMetric
    public let cpuWeight: WorkloadResourceValueMetric
    public let cpuStat: WorkloadCPUStatMetric
    public let ioWeight: WorkloadResourceValueMetric
    public let ioPressure: WorkloadPressureMetric
    public let tasksCurrent: WorkloadResourceValueMetric
    public let tasksMax: WorkloadResourceLimitMetric

    public init(
        id: String,
        name: String,
        systemdUnit: String? = nil,
        cgroupPath: String? = nil,
        availability: WorkloadResourceAvailability,
        memoryCurrentBytes: WorkloadResourceValueMetric,
        memoryPeakBytes: WorkloadResourceValueMetric,
        memoryHigh: WorkloadResourceLimitMetric,
        memoryMax: WorkloadResourceLimitMetric,
        memoryEvents: WorkloadMemoryEventsMetric,
        cpuQuota: WorkloadCPUQuotaMetric,
        cpuWeight: WorkloadResourceValueMetric,
        cpuStat: WorkloadCPUStatMetric,
        ioWeight: WorkloadResourceValueMetric,
        ioPressure: WorkloadPressureMetric,
        tasksCurrent: WorkloadResourceValueMetric,
        tasksMax: WorkloadResourceLimitMetric
    ) {
        self.id = id
        self.name = name
        self.systemdUnit = systemdUnit
        self.cgroupPath = cgroupPath
        self.availability = availability
        self.memoryCurrentBytes = memoryCurrentBytes
        self.memoryPeakBytes = memoryPeakBytes
        self.memoryHigh = memoryHigh
        self.memoryMax = memoryMax
        self.memoryEvents = memoryEvents
        self.cpuQuota = cpuQuota
        self.cpuWeight = cpuWeight
        self.cpuStat = cpuStat
        self.ioWeight = ioWeight
        self.ioPressure = ioPressure
        self.tasksCurrent = tasksCurrent
        self.tasksMax = tasksMax
    }
}

public struct ServiceMetric: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let failedAt: Date?
    public let isEnabled: Bool?

    public init(
        name: String,
        failedAt: Date? = nil,
        isEnabled: Bool? = nil
    ) {
        self.name = name
        self.failedAt = failedAt
        self.isEnabled = isEnabled
    }
}

public enum SystemdUnitKind: String, Codable, Hashable, Sendable {
    case service
    case timer

    public var suffix: String { ".\(rawValue)" }
}

public struct ExpectedSystemdUnit: Codable, Hashable, Sendable, Identifiable {
    public static let maxWatchlistCount = 12

    public var id: String { name }
    public let name: String
    public let kind: SystemdUnitKind

    public init?(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128 else { return nil }
        let kind: SystemdUnitKind
        if name.hasSuffix(SystemdUnitKind.service.suffix) {
            kind = .service
        } else if name.hasSuffix(SystemdUnitKind.timer.suffix) {
            kind = .timer
        } else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@:-")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.name = name
        self.kind = kind
    }
}

public enum ExpectedUnitState: String, Codable, Hashable, Sendable {
    case active
    case inactive
    case failed
    case missing
}

public struct ExpectedUnitMetric: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: SystemdUnitKind
    public let state: ExpectedUnitState
    public let substate: String?

    public init(
        name: String,
        kind: SystemdUnitKind,
        state: ExpectedUnitState,
        substate: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.state = state
        self.substate = substate
    }
}

public enum OOMConstraint: String, Codable, Hashable, Sendable {
    case system
    case cgroup
    case unknown
}

public enum OOMCollectionStatus: String, Codable, Hashable, Sendable {
    case available
    case unavailable
}

public struct OOMEventMetric: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let victimProcess: String?
    public let processID: Int?
    public let cgroup: String?
    public let constraint: OOMConstraint
    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?

    public init(
        timestamp: Date,
        victimProcess: String? = nil,
        processID: Int? = nil,
        cgroup: String? = nil,
        constraint: OOMConstraint = .unknown,
        memoryUsageBytes: UInt64? = nil,
        memoryLimitBytes: UInt64? = nil
    ) {
        self.timestamp = timestamp
        self.victimProcess = victimProcess
        self.processID = processID
        self.cgroup = cgroup
        self.constraint = constraint
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}

public struct PressureMetric: Codable, Hashable, Sendable {
    public let someAverage10: Double
    public let fullAverage10: Double

    public init(someAverage10: Double = 0, fullAverage10: Double = 0) {
        self.someAverage10 = someAverage10
        self.fullAverage10 = fullAverage10
    }
}

public enum MemoryPressureLevel: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
}

public struct MetricSample: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let deviceID: String
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
    public let diskReadBytesPerSecond: Double
    public let diskWriteBytesPerSecond: Double
    public let networkReceiveBytesPerSecond: Double
    public let networkTransmitBytesPerSecond: Double
    public let cpuPressure: PressureMetric?
    public let memoryPressure: PressureMetric?
    public let memoryPressureLevel: MemoryPressureLevel?
    public let ioPressure: PressureMetric?
    public let swapInBytesPerSecond: Double?
    public let swapOutBytesPerSecond: Double?
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
    public let bootID: String?
    public let collectorVersion: String?
    public let rootFilesystemID: String?

    public init(
        id: UUID = UUID(),
        deviceID: String,
        timestamp: Date = Date(),
        hostname: String,
        uptimeSeconds: TimeInterval,
        cpuPercent: Double,
        logicalCPUCount: Int,
        loadAverage1: Double,
        loadAverage5: Double,
        loadAverage15: Double,
        memoryTotalBytes: UInt64,
        memoryAvailableBytes: UInt64,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        diskTotalBytes: UInt64,
        diskUsedBytes: UInt64,
        diskReadBytesPerSecond: Double = 0,
        diskWriteBytesPerSecond: Double = 0,
        networkReceiveBytesPerSecond: Double = 0,
        networkTransmitBytesPerSecond: Double = 0,
        cpuPressure: PressureMetric? = nil,
        memoryPressure: PressureMetric? = nil,
        memoryPressureLevel: MemoryPressureLevel? = nil,
        ioPressure: PressureMetric? = nil,
        swapInBytesPerSecond: Double? = nil,
        swapOutBytesPerSecond: Double? = nil,
        topCPUProcesses: [ProcessMetric] = [],
        topMemoryProcesses: [ProcessMetric] = [],
        topIOProcesses: [ProcessIOMetric]? = nil,
        failedServices: [ServiceMetric] = [],
        expectedUnits: [ExpectedUnitMetric]? = nil,
        remoteWorkloads: [RemoteWorkloadMetric]? = nil,
        workloadResourceControls: [WorkloadResourceControlMetric]? = nil,
        oomKillCount: Int = 0,
        lastOOMKillAt: Date? = nil,
        oomCollectionStatus: OOMCollectionStatus? = nil,
        latestOOMEvent: OOMEventMetric? = nil,
        bootID: String? = nil,
        collectorVersion: String? = nil,
        rootFilesystemID: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.hostname = hostname
        self.uptimeSeconds = uptimeSeconds
        self.cpuPercent = cpuPercent
        self.logicalCPUCount = logicalCPUCount
        self.loadAverage1 = loadAverage1
        self.loadAverage5 = loadAverage5
        self.loadAverage15 = loadAverage15
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkTransmitBytesPerSecond = networkTransmitBytesPerSecond
        self.cpuPressure = cpuPressure
        self.memoryPressure = memoryPressure
        self.memoryPressureLevel = memoryPressureLevel
        self.ioPressure = ioPressure
        self.swapInBytesPerSecond = swapInBytesPerSecond
        self.swapOutBytesPerSecond = swapOutBytesPerSecond
        self.topCPUProcesses = topCPUProcesses
        self.topMemoryProcesses = topMemoryProcesses
        self.topIOProcesses = topIOProcesses
        self.failedServices = failedServices
        self.expectedUnits = expectedUnits
        self.remoteWorkloads = remoteWorkloads
        self.workloadResourceControls = workloadResourceControls
        self.oomKillCount = oomKillCount
        self.lastOOMKillAt = lastOOMKillAt
        self.oomCollectionStatus = oomCollectionStatus
        self.latestOOMEvent = latestOOMEvent
        self.bootID = bootID
        self.collectorVersion = collectorVersion
        self.rootFilesystemID = rootFilesystemID
    }

    public var memoryUsedFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return 1 - Double(memoryAvailableBytes) / Double(memoryTotalBytes)
    }

    public var swapUsedFraction: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return Double(swapUsedBytes) / Double(swapTotalBytes)
    }

    public var diskUsedFraction: Double {
        guard diskTotalBytes > 0 else { return 0 }
        return Double(diskUsedBytes) / Double(diskTotalBytes)
    }

    public var diskFreeBytes: UInt64 {
        diskTotalBytes >= diskUsedBytes ? diskTotalBytes - diskUsedBytes : 0
    }
}
