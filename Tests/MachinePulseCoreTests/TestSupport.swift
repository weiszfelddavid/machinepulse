import Testing
@testable import MachinePulseCore

func makeWorkloadResourceControl(
    id: String = "/system.slice/api.service",
    name: String = "api.service",
    systemdUnit: String? = "api.service",
    cgroupPath: String? = "/system.slice/api.service",
    availability: WorkloadResourceAvailability = .available,
    memoryCurrentBytes: UInt64 = 400_000_000,
    memoryPeakBytes: UInt64 = 600_000_000,
    memoryHighState: WorkloadResourceLimitState = .configured,
    memoryHighBytes: UInt64 = 800_000_000,
    memoryMaxState: WorkloadResourceLimitState = .configured,
    memoryMaxBytes: UInt64 = 1_000_000_000,
    memoryHighEvents: UInt64 = 3,
    memoryMaxEvents: UInt64 = 1,
    oomEvents: UInt64? = nil,
    oomKills: UInt64 = 0,
    cpuQuotaState: WorkloadResourceLimitState = .configured,
    cpuPeriods: UInt64 = 4_200,
    cpuThrottledPeriods: UInt64 = 4,
    cpuThrottledMicroseconds: UInt64 = 1_250_000,
    ioSomeAverage10: Double = 2.5,
    ioFullAverage10: Double = 0.5,
    tasksCurrent: UInt64 = 12,
    tasksMaxState: WorkloadResourceLimitState = .configured,
    tasksMax: UInt64 = 512
) -> WorkloadResourceControlMetric {
    func value(_ value: UInt64) -> WorkloadResourceValueMetric {
        WorkloadResourceValueMetric(availability: .available, value: value)
    }
    func limit(_ state: WorkloadResourceLimitState, _ value: UInt64) -> WorkloadResourceLimitMetric {
        WorkloadResourceLimitMetric(state: state, value: value)
    }
    return WorkloadResourceControlMetric(
        id: id,
        name: name,
        systemdUnit: systemdUnit,
        cgroupPath: cgroupPath,
        availability: availability,
        memoryCurrentBytes: value(memoryCurrentBytes),
        memoryPeakBytes: value(memoryPeakBytes),
        memoryHigh: limit(memoryHighState, memoryHighBytes),
        memoryMax: limit(memoryMaxState, memoryMaxBytes),
        memoryEvents: WorkloadMemoryEventsMetric(
            high: value(memoryHighEvents),
            max: value(memoryMaxEvents),
            oom: value(oomEvents ?? oomKills),
            oomKill: value(oomKills)
        ),
        cpuQuota: WorkloadCPUQuotaMetric(
            state: cpuQuotaState,
            quotaMicroseconds: 200_000,
            periodMicroseconds: 100_000
        ),
        cpuWeight: value(100),
        cpuStat: WorkloadCPUStatMetric(
            usageMicroseconds: value(82_000_000),
            userMicroseconds: value(61_000_000),
            systemMicroseconds: value(21_000_000),
            periods: value(cpuPeriods),
            throttledPeriods: value(cpuThrottledPeriods),
            throttledMicroseconds: value(cpuThrottledMicroseconds)
        ),
        ioWeight: value(100),
        ioPressure: WorkloadPressureMetric(
            availability: .available,
            someAverage10: ioSomeAverage10,
            fullAverage10: ioFullAverage10
        ),
        tasksCurrent: value(tasksCurrent),
        tasksMax: limit(tasksMaxState, tasksMax)
    )
}
