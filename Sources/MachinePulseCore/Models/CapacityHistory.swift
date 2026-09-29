import Foundation

public enum CapacityHistoryBreakReason: String, Codable, CaseIterable, Hashable, Sendable {
    case reboot
    case filesystem
    case machineIdentity
    case collectorVersion
    case samplingGap

    public var title: String {
        switch self {
        case .reboot: "reboot"
        case .filesystem: "filesystem change"
        case .machineIdentity: "machine identity change"
        case .collectorVersion: "collector change"
        case .samplingGap: "sampling gap"
        }
    }
}

public struct CapacityHistoryBreak: Codable, Hashable, Sendable {
    public let reasons: [CapacityHistoryBreakReason]
    public let gapSeconds: TimeInterval?

    public init(reasons: [CapacityHistoryBreakReason], gapSeconds: TimeInterval? = nil) {
        self.reasons = CapacityHistoryBreakReason.allCases.filter { reasons.contains($0) }
        self.gapSeconds = gapSeconds
    }
}

public struct CapacityDistribution: Codable, Hashable, Sendable {
    public let count: Int
    public let minimum: Double
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let maximum: Double

    public init?(values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard let minimum = sorted.first, let maximum = sorted.last else { return nil }
        count = sorted.count
        self.minimum = minimum
        p50 = Self.nearestRank(0.50, in: sorted)
        p95 = Self.nearestRank(0.95, in: sorted)
        p99 = Self.nearestRank(0.99, in: sorted)
        self.maximum = maximum
    }

    public init(
        count: Int,
        minimum: Double,
        p50: Double,
        p95: Double,
        p99: Double,
        maximum: Double
    ) {
        self.count = count
        self.minimum = minimum
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.maximum = maximum
    }

    static func typicalHour(_ values: [CapacityDistribution?]) -> CapacityDistribution? {
        let distributions = values.compactMap { $0 }.filter { $0.count > 0 }
        guard !distributions.isEmpty else { return nil }
        return CapacityDistribution(
            count: distributions.reduce(0) { $0 + $1.count },
            minimum: distributions.map(\.minimum).min() ?? 0,
            p50: weightedMedian(distributions.map { ($0.p50, $0.count) }),
            p95: weightedMedian(distributions.map { ($0.p95, $0.count) }),
            p99: weightedMedian(distributions.map { ($0.p99, $0.count) }),
            maximum: distributions.map(\.maximum).max() ?? 0
        )
    }

    private static func nearestRank(_ percentile: Double, in sorted: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    private static func weightedMedian(_ values: [(value: Double, weight: Int)]) -> Double {
        let sorted = values.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.weight < $1.weight
        }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return sorted.first?.value ?? 0 }
        let target = (total + 1) / 2
        var accumulated = 0
        for item in sorted {
            accumulated += item.weight
            if accumulated >= target { return item.value }
        }
        return sorted.last?.value ?? 0
    }
}

public struct CapacityPressureRollup: Codable, Hashable, Sendable {
    public let some: CapacityDistribution?
    public let full: CapacityDistribution?

    public init(some: CapacityDistribution?, full: CapacityDistribution?) {
        self.some = some
        self.full = full
    }

    static func typicalHour(_ values: [CapacityPressureRollup]) -> CapacityPressureRollup {
        CapacityPressureRollup(
            some: CapacityDistribution.typicalHour(values.map(\.some)),
            full: CapacityDistribution.typicalHour(values.map(\.full))
        )
    }
}

public struct HostCapacityRollup: Codable, Hashable, Sendable {
    public let cpuPercent: CapacityDistribution?
    public let memoryUsedPercent: CapacityDistribution?
    public let swapUsedPercent: CapacityDistribution?
    public let diskUsedPercent: CapacityDistribution?
    public let diskReadBytesPerSecond: CapacityDistribution?
    public let diskWriteBytesPerSecond: CapacityDistribution?
    public let networkReceiveBytesPerSecond: CapacityDistribution?
    public let networkTransmitBytesPerSecond: CapacityDistribution?
    public let cpuPressure: CapacityPressureRollup
    public let memoryPressure: CapacityPressureRollup
    public let ioPressure: CapacityPressureRollup
    public let oomKillCount: Int
    public let failedServiceSampleCount: Int
    public let expectedUnitObservationCount: Int
    public let activeExpectedUnitObservationCount: Int

    public init(
        cpuPercent: CapacityDistribution?,
        memoryUsedPercent: CapacityDistribution?,
        swapUsedPercent: CapacityDistribution?,
        diskUsedPercent: CapacityDistribution?,
        diskReadBytesPerSecond: CapacityDistribution?,
        diskWriteBytesPerSecond: CapacityDistribution?,
        networkReceiveBytesPerSecond: CapacityDistribution?,
        networkTransmitBytesPerSecond: CapacityDistribution?,
        cpuPressure: CapacityPressureRollup,
        memoryPressure: CapacityPressureRollup,
        ioPressure: CapacityPressureRollup,
        oomKillCount: Int,
        failedServiceSampleCount: Int,
        expectedUnitObservationCount: Int,
        activeExpectedUnitObservationCount: Int
    ) {
        self.cpuPercent = cpuPercent
        self.memoryUsedPercent = memoryUsedPercent
        self.swapUsedPercent = swapUsedPercent
        self.diskUsedPercent = diskUsedPercent
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkReceiveBytesPerSecond = networkReceiveBytesPerSecond
        self.networkTransmitBytesPerSecond = networkTransmitBytesPerSecond
        self.cpuPressure = cpuPressure
        self.memoryPressure = memoryPressure
        self.ioPressure = ioPressure
        self.oomKillCount = oomKillCount
        self.failedServiceSampleCount = failedServiceSampleCount
        self.expectedUnitObservationCount = expectedUnitObservationCount
        self.activeExpectedUnitObservationCount = activeExpectedUnitObservationCount
    }
}

public struct WorkloadCapacityRollup: Codable, Hashable, Sendable {
    public let cpuThrottledPeriodPercent: CapacityDistribution?
    public let ioPressure: CapacityPressureRollup
    public let memoryHighEvents: Int
    public let memoryMaxEvents: Int
    public let oomEvents: Int
    public let oomKillEvents: Int
    public let tasksAtLimitSampleCount: Int
    public let configuredLimitObservationCount: Int
    public let unlimitedLimitObservationCount: Int

    public init(
        cpuThrottledPeriodPercent: CapacityDistribution?,
        ioPressure: CapacityPressureRollup,
        memoryHighEvents: Int,
        memoryMaxEvents: Int,
        oomEvents: Int,
        oomKillEvents: Int,
        tasksAtLimitSampleCount: Int,
        configuredLimitObservationCount: Int,
        unlimitedLimitObservationCount: Int
    ) {
        self.cpuThrottledPeriodPercent = cpuThrottledPeriodPercent
        self.ioPressure = ioPressure
        self.memoryHighEvents = memoryHighEvents
        self.memoryMaxEvents = memoryMaxEvents
        self.oomEvents = oomEvents
        self.oomKillEvents = max(0, oomKillEvents)
        self.tasksAtLimitSampleCount = max(0, tasksAtLimitSampleCount)
        self.configuredLimitObservationCount = max(0, configuredLimitObservationCount)
        self.unlimitedLimitObservationCount = max(0, unlimitedLimitObservationCount)
    }
}

public struct CapacityHourlyRollup: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let deviceID: String
    public let hourStart: Date
    public let segmentIndex: Int
    public let observedFrom: Date
    public let observedThrough: Date
    public let sampleCount: Int
    public let expectedSampleCount: Int
    public let breakBefore: CapacityHistoryBreak?
    public let host: HostCapacityRollup
    public let workload: WorkloadCapacityRollup

    public init(
        id: String,
        deviceID: String,
        hourStart: Date,
        segmentIndex: Int,
        observedFrom: Date,
        observedThrough: Date,
        sampleCount: Int,
        expectedSampleCount: Int,
        breakBefore: CapacityHistoryBreak?,
        host: HostCapacityRollup,
        workload: WorkloadCapacityRollup
    ) {
        self.id = id
        self.deviceID = deviceID
        self.hourStart = hourStart
        self.segmentIndex = max(0, segmentIndex)
        self.observedFrom = observedFrom
        self.observedThrough = observedThrough
        self.sampleCount = max(0, sampleCount)
        self.expectedSampleCount = max(sampleCount, expectedSampleCount)
        self.breakBefore = breakBefore
        self.host = host
        self.workload = workload
    }

    public var coverageFraction: Double {
        guard expectedSampleCount > 0 else { return 0 }
        return min(1, Double(sampleCount) / Double(expectedSampleCount))
    }
}

public struct CapacityWindowEvidence: Hashable, Sendable {
    public let observedFrom: Date
    public let observedThrough: Date
    public let rollupCount: Int
    public let sampleCount: Int
    public let expectedSampleCount: Int
    public let boundaryCount: Int
    public let breakCounts: [CapacityHistoryBreakReason: Int]
    public let host: HostCapacityRollup
    public let workload: WorkloadCapacityRollup

    public static func summarize(_ rollups: [CapacityHourlyRollup]) -> CapacityWindowEvidence? {
        let ordered = rollups.sorted {
            if $0.observedFrom != $1.observedFrom { return $0.observedFrom < $1.observedFrom }
            return $0.segmentIndex < $1.segmentIndex
        }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        var breakCounts: [CapacityHistoryBreakReason: Int] = [:]
        for item in ordered {
            for reason in item.breakBefore?.reasons ?? [] { breakCounts[reason, default: 0] += 1 }
        }
        let hosts = ordered.map(\.host)
        let workloads = ordered.map(\.workload)
        return CapacityWindowEvidence(
            observedFrom: first.observedFrom,
            observedThrough: last.observedThrough,
            rollupCount: ordered.count,
            sampleCount: ordered.reduce(0) { $0 + $1.sampleCount },
            expectedSampleCount: ordered.reduce(0) { $0 + $1.expectedSampleCount },
            boundaryCount: ordered.count { $0.breakBefore != nil },
            breakCounts: breakCounts,
            host: HostCapacityRollup(
                cpuPercent: CapacityDistribution.typicalHour(hosts.map(\.cpuPercent)),
                memoryUsedPercent: CapacityDistribution.typicalHour(hosts.map(\.memoryUsedPercent)),
                swapUsedPercent: CapacityDistribution.typicalHour(hosts.map(\.swapUsedPercent)),
                diskUsedPercent: CapacityDistribution.typicalHour(hosts.map(\.diskUsedPercent)),
                diskReadBytesPerSecond: CapacityDistribution.typicalHour(
                    hosts.map(\.diskReadBytesPerSecond)),
                diskWriteBytesPerSecond: CapacityDistribution.typicalHour(
                    hosts.map(\.diskWriteBytesPerSecond)),
                networkReceiveBytesPerSecond: CapacityDistribution.typicalHour(
                    hosts.map(\.networkReceiveBytesPerSecond)),
                networkTransmitBytesPerSecond: CapacityDistribution.typicalHour(
                    hosts.map(\.networkTransmitBytesPerSecond)),
                cpuPressure: CapacityPressureRollup.typicalHour(hosts.map(\.cpuPressure)),
                memoryPressure: CapacityPressureRollup.typicalHour(hosts.map(\.memoryPressure)),
                ioPressure: CapacityPressureRollup.typicalHour(hosts.map(\.ioPressure)),
                oomKillCount: hosts.reduce(0) { $0 + $1.oomKillCount },
                failedServiceSampleCount: hosts.reduce(0) { $0 + $1.failedServiceSampleCount },
                expectedUnitObservationCount: hosts.reduce(0) { $0 + $1.expectedUnitObservationCount },
                activeExpectedUnitObservationCount: hosts.reduce(0) {
                    $0 + $1.activeExpectedUnitObservationCount
                }
            ),
            workload: WorkloadCapacityRollup(
                cpuThrottledPeriodPercent: CapacityDistribution.typicalHour(
                    workloads.map(\.cpuThrottledPeriodPercent)),
                ioPressure: CapacityPressureRollup.typicalHour(workloads.map(\.ioPressure)),
                memoryHighEvents: workloads.reduce(0) { $0 + $1.memoryHighEvents },
                memoryMaxEvents: workloads.reduce(0) { $0 + $1.memoryMaxEvents },
                oomEvents: workloads.reduce(0) { $0 + $1.oomEvents },
                oomKillEvents: workloads.reduce(0) { $0 + $1.oomKillEvents },
                tasksAtLimitSampleCount: workloads.reduce(0) { $0 + $1.tasksAtLimitSampleCount },
                configuredLimitObservationCount: workloads.reduce(0) {
                    $0 + $1.configuredLimitObservationCount
                },
                unlimitedLimitObservationCount: workloads.reduce(0) {
                    $0 + $1.unlimitedLimitObservationCount
                }
            )
        )
    }

    public var coverageFraction: Double {
        guard expectedSampleCount > 0 else { return 0 }
        return min(1, Double(sampleCount) / Double(expectedSampleCount))
    }

    public var totalBreakCount: Int { boundaryCount }

    public var expectedServiceFreshnessPercent: Double? {
        guard host.expectedUnitObservationCount > 0 else { return nil }
        return 100 * Double(host.activeExpectedUnitObservationCount)
            / Double(host.expectedUnitObservationCount)
    }
}

public enum CapacityRollupBuilder {
    public static let expectedSampleInterval: TimeInterval = 10
    public static let materialSamplingGap: TimeInterval = 120

    public static func build(samples: [MetricSample]) -> [CapacityHourlyRollup] {
        let ordered = samples.sorted {
            if $0.deviceID != $1.deviceID { return $0.deviceID < $1.deviceID }
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [CapacityHourlyRollup] = []
        var previous: MetricSample?
        var accumulator: Accumulator?
        var segmentIndexes: [String: Int] = [:]

        for sample in ordered {
            if previous?.deviceID != sample.deviceID {
                if let accumulator { result.append(accumulator.finish()) }
                accumulator = nil
                previous = nil
            }
            let hourStart = hour(containing: sample.timestamp)
            let historyBreak: CapacityHistoryBreak? =
                if let previous {
                    compatibilityBreak(from: previous, to: sample)
                } else {
                    nil
                }
            let beginsNewSegment =
                accumulator == nil
                || accumulator?.hourStart != hourStart
                || historyBreak != nil
            if beginsNewSegment {
                if let accumulator { result.append(accumulator.finish()) }
                let key = "\(sample.deviceID)|\(Int(hourStart.timeIntervalSince1970))"
                let index = segmentIndexes[key, default: 0]
                segmentIndexes[key] = index + 1
                accumulator = Accumulator(
                    deviceID: sample.deviceID,
                    hourStart: hourStart,
                    segmentIndex: index,
                    breakBefore: historyBreak
                )
            }
            accumulator?.add(sample, previous: historyBreak == nil ? previous : nil)
            previous = sample
        }
        if let accumulator { result.append(accumulator.finish()) }
        return result
    }

    public static func hour(containing date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
    }

    static func compatibilityBreak(
        from previous: MetricSample,
        to current: MetricSample
    ) -> CapacityHistoryBreak? {
        var reasons: [CapacityHistoryBreakReason] = []
        let gap = current.timestamp.timeIntervalSince(previous.timestamp)
        if gap > materialSamplingGap { reasons.append(.samplingGap) }
        if previous.deviceID != current.deviceID || previous.hostname != current.hostname {
            reasons.append(.machineIdentity)
        }
        if let previousBoot = previous.bootID, let currentBoot = current.bootID {
            if previousBoot != currentBoot { reasons.append(.reboot) }
        } else if current.uptimeSeconds + expectedSampleInterval < previous.uptimeSeconds {
            reasons.append(.reboot)
        }
        if normalized(previous.collectorVersion) != normalized(current.collectorVersion) {
            reasons.append(.collectorVersion)
        }
        if normalized(previous.rootFilesystemID) != normalized(current.rootFilesystemID)
            || materiallyDifferent(previous.diskTotalBytes, current.diskTotalBytes)
        {
            reasons.append(.filesystem)
        }
        guard !reasons.isEmpty else { return nil }
        return CapacityHistoryBreak(
            reasons: reasons,
            gapSeconds: reasons.contains(.samplingGap) ? max(0, gap) : nil
        )
    }

    private static func normalized(_ value: String?) -> String { value ?? "unknown" }

    private static func materiallyDifferent(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        guard lhs != rhs else { return false }
        let difference = lhs > rhs ? lhs - rhs : rhs - lhs
        let relativeBoundary = UInt64(Double(max(lhs, rhs)) * 0.01)
        return difference > max(1_073_741_824, relativeBoundary)
    }
}

private struct Accumulator {
    let deviceID: String
    let hourStart: Date
    let segmentIndex: Int
    let breakBefore: CapacityHistoryBreak?
    var samples: [MetricSample] = []
    var missingSamples = 0
    var cpuThrottledPercent: [Double] = []
    var memoryHighEvents = 0
    var memoryMaxEvents = 0
    var workloadOOMEvents = 0
    var workloadOOMKillEvents = 0
    var hostOOMKillEvents = 0

    mutating func add(_ sample: MetricSample, previous: MetricSample?) {
        if let previous {
            let interval = sample.timestamp.timeIntervalSince(previous.timestamp)
            if interval > CapacityRollupBuilder.expectedSampleInterval * 1.5 {
                missingSamples += max(
                    0,
                    Int((interval / CapacityRollupBuilder.expectedSampleInterval).rounded()) - 1
                )
            }
            if sample.bootID == previous.bootID {
                if sample.oomKillCount >= previous.oomKillCount {
                    hostOOMKillEvents += sample.oomKillCount - previous.oomKillCount
                }
                appendWorkloadDeltas(from: previous, to: sample)
            }
        } else if let gap = breakBefore?.gapSeconds {
            missingSamples += max(
                0,
                Int((gap / CapacityRollupBuilder.expectedSampleInterval).rounded()) - 1
            )
        }
        samples.append(sample)
    }

    func finish() -> CapacityHourlyRollup {
        let first = samples.first!
        let last = samples.last!
        let host = HostCapacityRollup(
            cpuPercent: CapacityDistribution(values: samples.map(\.cpuPercent)),
            memoryUsedPercent: CapacityDistribution(values: samples.map { $0.memoryUsedFraction * 100 }),
            swapUsedPercent: CapacityDistribution(
                values: samples.compactMap { $0.swapTotalBytes > 0 ? $0.swapUsedFraction * 100 : nil }),
            diskUsedPercent: CapacityDistribution(values: samples.map { $0.diskUsedFraction * 100 }),
            diskReadBytesPerSecond: CapacityDistribution(values: samples.map(\.diskReadBytesPerSecond)),
            diskWriteBytesPerSecond: CapacityDistribution(values: samples.map(\.diskWriteBytesPerSecond)),
            networkReceiveBytesPerSecond: CapacityDistribution(
                values: samples.map(\.networkReceiveBytesPerSecond)),
            networkTransmitBytesPerSecond: CapacityDistribution(
                values: samples.map(\.networkTransmitBytesPerSecond)),
            cpuPressure: pressure(samples.compactMap(\.cpuPressure)),
            memoryPressure: pressure(samples.compactMap(\.memoryPressure)),
            ioPressure: pressure(samples.compactMap(\.ioPressure)),
            oomKillCount: hostOOMKillEvents,
            failedServiceSampleCount: samples.count { !$0.failedServices.isEmpty },
            expectedUnitObservationCount: samples.reduce(0) { $0 + ($1.expectedUnits?.count ?? 0) },
            activeExpectedUnitObservationCount: samples.reduce(0) { partial, sample in
                partial + (sample.expectedUnits?.count { $0.state == .active } ?? 0)
            }
        )

        let controls = samples.flatMap { $0.workloadResourceControls ?? [] }
        let workloadPressure = controls.compactMap { control -> PressureMetric? in
            guard control.ioPressure.availability == .available else { return nil }
            return PressureMetric(
                someAverage10: control.ioPressure.someAverage10 ?? 0,
                fullAverage10: control.ioPressure.fullAverage10 ?? 0
            )
        }
        let workload = WorkloadCapacityRollup(
            cpuThrottledPeriodPercent: CapacityDistribution(values: cpuThrottledPercent),
            ioPressure: pressure(workloadPressure),
            memoryHighEvents: memoryHighEvents,
            memoryMaxEvents: memoryMaxEvents,
            oomEvents: workloadOOMEvents,
            oomKillEvents: workloadOOMKillEvents,
            tasksAtLimitSampleCount: controls.count { control in
                guard control.tasksCurrent.availability == .available,
                    let current = control.tasksCurrent.value,
                    control.tasksMax.state == .configured,
                    let maximum = control.tasksMax.value
                else { return false }
                return current >= maximum
            },
            configuredLimitObservationCount: controls.reduce(0) { count, control in
                count + limitCount(control, state: .configured)
            },
            unlimitedLimitObservationCount: controls.reduce(0) { count, control in
                count + limitCount(control, state: .unlimited)
            }
        )

        return CapacityHourlyRollup(
            id: "\(deviceID)|\(Int(hourStart.timeIntervalSince1970))|\(segmentIndex)",
            deviceID: deviceID,
            hourStart: hourStart,
            segmentIndex: segmentIndex,
            observedFrom: first.timestamp,
            observedThrough: last.timestamp,
            sampleCount: samples.count,
            expectedSampleCount: samples.count + missingSamples,
            breakBefore: breakBefore,
            host: host,
            workload: workload
        )
    }

    private func pressure(_ values: [PressureMetric]) -> CapacityPressureRollup {
        CapacityPressureRollup(
            some: CapacityDistribution(values: values.map(\.someAverage10)),
            full: CapacityDistribution(values: values.map(\.fullAverage10))
        )
    }

    private mutating func appendWorkloadDeltas(from previous: MetricSample, to current: MetricSample) {
        var previousByID: [String: WorkloadResourceControlMetric] = [:]
        for control in previous.workloadResourceControls ?? [] where previousByID[control.id] == nil {
            previousByID[control.id] = control
        }
        for control in current.workloadResourceControls ?? [] {
            guard let old = previousByID[control.id] else { continue }
            if let periods = delta(control.cpuStat.periods, old.cpuStat.periods), periods > 0,
                let throttled = delta(control.cpuStat.throttledPeriods, old.cpuStat.throttledPeriods)
            {
                cpuThrottledPercent.append(100 * Double(throttled) / Double(periods))
            }
            memoryHighEvents += Int(delta(control.memoryEvents.high, old.memoryEvents.high) ?? 0)
            memoryMaxEvents += Int(delta(control.memoryEvents.max, old.memoryEvents.max) ?? 0)
            workloadOOMEvents += Int(delta(control.memoryEvents.oom, old.memoryEvents.oom) ?? 0)
            workloadOOMKillEvents += Int(delta(control.memoryEvents.oomKill, old.memoryEvents.oomKill) ?? 0)
        }
    }

    private func delta(
        _ current: WorkloadResourceValueMetric,
        _ previous: WorkloadResourceValueMetric
    ) -> UInt64? {
        guard current.availability == .available, previous.availability == .available,
            let currentValue = current.value, let previousValue = previous.value,
            currentValue >= previousValue
        else { return nil }
        return currentValue - previousValue
    }

    private func limitCount(_ control: WorkloadResourceControlMetric, state: WorkloadResourceLimitState) -> Int {
        [control.memoryHigh.state, control.memoryMax.state, control.cpuQuota.state, control.tasksMax.state]
            .count { $0 == state }
    }
}
