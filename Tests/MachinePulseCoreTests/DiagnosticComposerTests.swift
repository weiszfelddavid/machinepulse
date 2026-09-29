import Foundation
import Testing
@testable import MachinePulseCore

struct DiagnosticComposerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let device = MachineDevice(id: "vps", name: "ubuntu", platform: .linux, isOnline: true)

    @Test func statesReachabilityTruthAndLastSuccessfulSample() throws {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: true,
            failure: .collectorFailed("ValueError: invalid literal")
        )
        let diagnostic = DiagnosticComposer.compose(
            device: MachineDevice(
                id: "vps",
                name: "example-vps",
                dnsName: "example-vps.example.ts.net",
                addresses: ["100.64.0.10"],
                platform: .linux,
                isOnline: true
            ),
            report: report,
            sample: makeSample(),
            thresholds: .balanced,
            activeIncidents: [],
            recentRecoveredIncidents: []
        )
        #expect(diagnostic.contains("Reachable through Tailscale: yes"))
        #expect(diagnostic.contains("Metrics collection failed"))
        #expect(diagnostic.contains("Last successful sample:"))
        #expect(diagnostic.contains("CPU: 21.0%"))
        #expect(!diagnostic.contains("Machine is unreachable"))

        let marker = "All captured data (JSON):\n"
        let markerRange = try #require(diagnostic.range(of: marker))
        let payloadData = Data(diagnostic[markerRange.upperBound...].utf8)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        #expect(payload["formatVersion"] as? Int == 3)
        let capturedDevice = try #require(payload["device"] as? [String: Any])
        #expect(capturedDevice["dnsName"] as? String == "example-vps.example.ts.net")
        let capturedSample = try #require(payload["sample"] as? [String: Any])
        #expect(capturedSample["logicalCPUCount"] as? Int == 2)
        #expect(capturedSample["loadAverage15"] as? Double == 1)
        let capturedThresholds = try #require(payload["thresholds"] as? [String: Any])
        #expect(capturedThresholds["cpuWarningPercent"] as? Double == 75)
    }

    @Test func healthyDiagnosticDoesNotLabelTelemetryAsStale() {
        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: HealthReport(deviceID: "vps", state: .healthy, summary: "Everything looks steady", issues: []),
            sample: makeSample(),
            activeIncidents: [],
            recentRecoveredIncidents: []
        )
        #expect(!diagnostic.contains("Last successful sample:"))
        #expect(diagnostic.contains("Current sample:"))
        #expect(diagnostic.contains("Current readings:"))
        #expect(diagnostic.contains("CPU: 21.0%"))
    }

    @Test func clearingDiagnosticSeparatesCurrentReadingFromIncidentPeak() {
        let sampleTime = start.addingTimeInterval(60)
        let peakIssue = HealthIssue(
            id: "cpu",
            kind: .cpu,
            state: .critical,
            title: "CPU is busy",
            explanation: "98% CPU utilization; the critical threshold is 92% CPU utilization.",
            measurement: 98,
            threshold: 92
        )
        var incident = HealthIncident(issue: peakIssue, deviceID: "vps", at: start)
        incident.markClearing(clearSampleCount: 1, requiredClearSampleCount: 3, at: sampleTime)
        let clearingIssue = incident.healthIssue
        let report = HealthReport(
            deviceID: "vps",
            state: .warning,
            summary: clearingIssue.title,
            issues: [clearingIssue],
            evaluatedAt: sampleTime
        )

        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: report,
            sample: makeSample(timestamp: sampleTime, cpuPercent: 33),
            thresholds: .balanced,
            activeIncidents: [incident],
            recentRecoveredIncidents: []
        )

        #expect(diagnostic.contains("Current sample:"))
        #expect(diagnostic.contains("CPU: 33.0%"))
        #expect(diagnostic.contains("High CPU utilization clearing"))
        #expect(diagnostic.contains("[Clearing after Critical · Host]"))
        #expect(diagnostic.contains("Peak at"))
        #expect(diagnostic.contains("98.0%"))
        #expect(diagnostic.contains("2 more clear samples required"))
    }

    @Test func includesDiskHeadroomTrendOOMContextAndExpectedUnits() {
        let event = OOMEventMetric(
            timestamp: start,
            victimProcess: "php",
            processID: 42,
            cgroup: "/system.slice/worker.service",
            constraint: .cgroup,
            memoryUsageBytes: 500 * 1_024 * 1_024,
            memoryLimitBytes: 512 * 1_024 * 1_024
        )
        let sample = makeSample(
            diskUsedBytes: 60_000_000_000,
            expectedUnits: [
                ExpectedUnitMetric(name: "api.service", kind: .service, state: .active, substate: "running"),
                ExpectedUnitMetric(name: "backup.timer", kind: .timer, state: .inactive, substate: "dead"),
            ],
            remoteWorkloads: [
                RemoteWorkloadMetric(
                    id: "api.service",
                    name: "api.service",
                    processName: "gunicorn",
                    systemdUnit: "api.service",
                    state: .active,
                    uptimeSeconds: 3_600,
                    listeners: [
                        WorkloadListenerMetric(
                            address: "100.64.0.10",
                            port: 8_000,
                            binding: .tailnet,
                            webProtocol: .http
                        )
                    ]
                )
            ],
            workloadResourceControls: [makeWorkloadResourceControl(oomKills: 1)],
            oomKillCount: 1,
            lastOOMKillAt: start,
            oomCollectionStatus: .available,
            latestOOMEvent: event,
            bootID: "boot"
        )
        let trend = DiskGrowthTrend(
            state: .growing,
            changeBytes: 2_000_000_000,
            peakAboveBaselineBytes: 2_000_000_000,
            startedAt: start.addingTimeInterval(-3_600),
            endedAt: start,
            sampleCount: 100
        )
        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: HealthReport(deviceID: "vps", state: .healthy, summary: "Everything looks steady", issues: []),
            sample: sample,
            diskTrend: trend,
            activeIncidents: [],
            recentRecoveredIncidents: []
        )

        #expect(diagnostic.contains("used ·"))
        #expect(diagnostic.contains("free ·"))
        #expect(diagnostic.contains("Recent storage trend: grew"))
        #expect(diagnostic.contains("php (PID 42)"))
        #expect(diagnostic.contains("workload/cgroup memory constraint"))
        #expect(diagnostic.contains("backup.timer: inactive · dead"))
        #expect(diagnostic.contains("Observed remote workloads:"))
        #expect(diagnostic.contains("api.service: active · up 1.0 hours"))
        #expect(diagnostic.contains("100.64.0.10:8000 (tailnet, http)"))
        #expect(diagnostic.contains("Workload resource controls"))
        #expect(diagnostic.contains("memory 381 MiB current"))
        #expect(diagnostic.contains("CPU quota 200%"))
        #expect(diagnostic.contains("OOM-kill 1"))
        #expect(diagnostic.contains("tasks 12 / 512"))
        #expect(diagnostic.contains("\"diskGrowthTrend\""))
        #expect(diagnostic.contains("\"latestOOMEvent\""))
        #expect(diagnostic.contains("\"expectedUnits\""))
        #expect(diagnostic.contains("\"remoteWorkloads\""))
        #expect(diagnostic.contains("\"workloadResourceControls\""))
    }

    @Test func statesWhenOOMJournalContextIsUnavailable() {
        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: nil,
            sample: makeSample(oomCollectionStatus: .unavailable),
            activeIncidents: [],
            recentRecoveredIncidents: []
        )
        #expect(diagnostic.contains("OOM journal context: unavailable"))
        #expect(!diagnostic.contains("OOM kills observed"))
    }

    @Test func labelsWorkloadFindingsAndKeepsStructuredScope() throws {
        let previous = makeSample(
            workloadResourceControls: [makeWorkloadResourceControl(memoryHighEvents: 8, memoryMaxEvents: 0)],
            bootID: "boot"
        )
        let current = makeSample(
            timestamp: start.addingTimeInterval(10),
            workloadResourceControls: [makeWorkloadResourceControl(memoryHighEvents: 10, memoryMaxEvents: 0)],
            bootID: "boot"
        )
        let issue = try #require(
            WorkloadHealthEvaluator.evaluate(sample: current, previousSample: previous, thresholds: .balanced).first)
        let report = HealthReport(
            deviceID: "vps",
            state: .warning,
            summary: issue.title,
            issues: [issue],
            evaluatedAt: current.timestamp
        )
        let diagnostic = DiagnosticComposer.compose(
            device: device,
            report: report,
            sample: current,
            activeIncidents: [HealthIncident(issue: issue, deviceID: "vps", at: start)],
            recentRecoveredIncidents: []
        )

        #expect(diagnostic.contains("[Workload api.service]"))
        #expect(diagnostic.contains("Warning · Workload api.service"))
        #expect(diagnostic.contains("\"workload\""))
    }

    private func makeSample(
        timestamp: Date? = nil,
        cpuPercent: Double = 21,
        diskUsedBytes: UInt64 = 40_000_000_000,
        expectedUnits: [ExpectedUnitMetric]? = nil,
        remoteWorkloads: [RemoteWorkloadMetric]? = nil,
        workloadResourceControls: [WorkloadResourceControlMetric]? = nil,
        oomKillCount: Int = 0,
        lastOOMKillAt: Date? = nil,
        oomCollectionStatus: OOMCollectionStatus? = nil,
        latestOOMEvent: OOMEventMetric? = nil,
        bootID: String? = nil
    ) -> MetricSample {
        MetricSample(
            deviceID: "vps",
            timestamp: timestamp ?? start,
            hostname: "ubuntu",
            uptimeSeconds: 1_000,
            cpuPercent: cpuPercent,
            logicalCPUCount: 2,
            loadAverage1: 1,
            loadAverage5: 1,
            loadAverage15: 1,
            memoryTotalBytes: 4_000_000_000,
            memoryAvailableBytes: 2_000_000_000,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            diskTotalBytes: 80_000_000_000,
            diskUsedBytes: diskUsedBytes,
            expectedUnits: expectedUnits,
            remoteWorkloads: remoteWorkloads,
            workloadResourceControls: workloadResourceControls,
            oomKillCount: oomKillCount,
            lastOOMKillAt: lastOOMKillAt,
            oomCollectionStatus: oomCollectionStatus,
            latestOOMEvent: latestOOMEvent,
            bootID: bootID
        )
    }
}
