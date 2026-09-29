import Darwin
import Foundation

public actor LocalMacMetricSource: MetricSource {
    public nonisolated let deviceID: String

    private var previousCPU: CPUTicks?
    private var previousSnapshot: LocalCounterSnapshot?

    public init(deviceID: String) {
        self.deviceID = deviceID
    }

    public func collect() async throws -> MetricSample {
        let now = Date()
        let cpu = readCPU()
        let cpuPercent = utilization(current: cpu, previous: previousCPU)
        previousCPU = cpu

        let memory = readMemory()
        let swap = readSwap()
        let disk = try readDisk()
        let network = readNetworkTotals()
        let counters = LocalCounterSnapshot(
            timestamp: now,
            received: network.received,
            transmitted: network.transmitted,
            swapIns: memory.swapIns,
            swapOuts: memory.swapOuts
        )
        let rates = calculateRates(current: counters, previous: previousSnapshot)
        previousSnapshot = counters

        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, Int32(loads.count))
        let processes = await readProcesses()

        return MetricSample(
            deviceID: deviceID,
            timestamp: now,
            hostname: ProcessInfo.processInfo.hostName,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            cpuPercent: cpuPercent,
            logicalCPUCount: ProcessInfo.processInfo.processorCount,
            loadAverage1: loads[0],
            loadAverage5: loads[1],
            loadAverage15: loads[2],
            memoryTotalBytes: memory.total,
            memoryAvailableBytes: memory.available,
            swapTotalBytes: swap.total,
            swapUsedBytes: swap.used,
            diskTotalBytes: disk.total,
            diskUsedBytes: disk.used,
            networkReceiveBytesPerSecond: rates.received,
            networkTransmitBytesPerSecond: rates.transmitted,
            memoryPressureLevel: readMemoryPressureLevel(),
            swapInBytesPerSecond: rates.swapIns,
            swapOutBytesPerSecond: rates.swapOuts,
            topCPUProcesses: Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)),
            topMemoryProcesses: Array(processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(5)),
            collectorVersion: "mac-native-v1",
            rootFilesystemID: disk.identity
        )
    }

    private func readCPU() -> CPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return CPUTicks(active: 0, idle: 0) }
        let ticks = info.cpu_ticks
        return CPUTicks(
            active: UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3),
            idle: UInt64(ticks.2)
        )
    }

    private func utilization(current: CPUTicks, previous: CPUTicks?) -> Double {
        guard let previous, current.active >= previous.active, current.idle >= previous.idle else { return 0 }
        let active = current.active - previous.active
        let idle = current.idle - previous.idle
        let total = active + idle
        guard total > 0 else { return 0 }
        return 100 * Double(active) / Double(total)
    }

    private func readMemory() -> LocalMemorySnapshot {
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            return LocalMemorySnapshot(total: total, available: 0, swapIns: 0, swapOuts: 0)
        }

        let pageSize = UInt64(getpagesize())
        let availablePages = UInt64(info.free_count) + UInt64(info.external_page_count)
        return LocalMemorySnapshot(
            total: total,
            available: min(total, availablePages * pageSize),
            swapIns: info.swapins * pageSize,
            swapOuts: info.swapouts * pageSize
        )
    }

    private func readMemoryPressureLevel() -> MemoryPressureLevel? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        if value >= 4 { return .critical }
        if value >= 2 { return .warning }
        return .normal
    }

    private func readSwap() -> (total: UInt64, used: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_total, usage.xsu_used)
    }

    private func readDisk() throws -> (total: UInt64, used: UInt64, identity: String?) {
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIdentifierKey,
        ])
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        return (
            total,
            total > available ? total - available : 0,
            values.volumeIdentifier.map { String(describing: $0) }
        )
    }

    private func readNetworkTotals() -> (received: UInt64, transmitted: UInt64) {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return (0, 0) }
        defer { freeifaddrs(firstAddress) }

        var received: UInt64 = 0
        var transmitted: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self)
            {
                received += UInt64(data.pointee.ifi_ibytes)
                transmitted += UInt64(data.pointee.ifi_obytes)
            }
            pointer = interface.ifa_next
        }
        return (received, transmitted)
    }

    private func calculateRates(
        current: LocalCounterSnapshot,
        previous: LocalCounterSnapshot?
    ) -> (received: Double, transmitted: Double, swapIns: Double, swapOuts: Double) {
        guard let previous, current.timestamp > previous.timestamp else { return (0, 0, 0, 0) }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        func rate(_ new: UInt64, _ old: UInt64) -> Double {
            new >= old ? Double(new - old) / elapsed : 0
        }
        return (
            rate(current.received, previous.received),
            rate(current.transmitted, previous.transmitted),
            rate(current.swapIns, previous.swapIns),
            rate(current.swapOuts, previous.swapOuts)
        )
    }

    private func readProcesses() async -> [ProcessMetric] {
        guard
            let result = try? await CommandRunner.run(
                executable: "/bin/ps",
                arguments: ["-A", "-o", "%cpu=,rss=,comm="],
                timeout: 5
            )
        else { return [] }

        return result.outputString.split(whereSeparator: \.isNewline)
            .compactMap(Self.processMetric(fromNumericFirstPSLine:))
    }

    /// Parses one `%cpu rss comm` line. The command name comes last because it
    /// may itself contain whitespace; the numeric columns are read from the
    /// left and the remainder of the line is the complete name.
    static func processMetric(fromNumericFirstPSLine line: Substring) -> ProcessMetric? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard
            fields.count >= 3,
            let cpuPercent = Double(fields[0]),
            let residentKilobytes = UInt64(fields[1])
        else { return nil }
        let name = line[fields[1].endIndex...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, cpuPercent.isFinite, cpuPercent >= 0 else { return nil }
        return ProcessMetric(
            name: name.components(separatedBy: "/").last ?? name,
            cpuPercent: cpuPercent,
            residentBytes: residentKilobytes * 1024
        )
    }
}

private struct CPUTicks {
    let active: UInt64
    let idle: UInt64
}

private struct LocalCounterSnapshot {
    let timestamp: Date
    let received: UInt64
    let transmitted: UInt64
    let swapIns: UInt64
    let swapOuts: UInt64
}

private struct LocalMemorySnapshot {
    let total: UInt64
    let available: UInt64
    let swapIns: UInt64
    let swapOuts: UInt64
}
