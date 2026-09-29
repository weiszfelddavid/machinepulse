import Foundation
import Testing
@testable import MachinePulseCore

struct IncidentStabilizerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func warningRequiresTwoSamplesAndUsesFirstObservationAsStart() throws {
        var stabilizer = IncidentStabilizer()
        let first = stabilizer.process(report(issue: storageIssue(state: .warning), seconds: 0))
        #expect(first.report.state == .healthy)
        #expect(first.changedIncidents.isEmpty)

        let second = stabilizer.process(report(issue: storageIssue(state: .warning), seconds: 10))
        let incident = try #require(second.activeIncidents.first)
        #expect(second.report.state == .warning)
        #expect(incident.startedAt == start)
        #expect(incident.updatedAt == start.addingTimeInterval(10))
    }

    @Test func criticalActivatesImmediately() throws {
        var stabilizer = IncidentStabilizer()
        let result = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 0))
        #expect(result.report.state == .critical)
        let incident = try #require(result.activeIncidents.first)
        #expect(incident.peakSeverity == .critical)
    }

    @Test func escalationDeescalationAndRecoveryStayOneIncident() throws {
        var stabilizer = IncidentStabilizer()
        _ = stabilizer.process(report(issue: storageIssue(state: .critical, measurement: 29), seconds: 0))
        let escalatedID = try #require(
            stabilizer.process(report(issue: storageIssue(state: .warning, measurement: 12), seconds: 10))
                .activeIncidents.first?.id)

        let firstClear = stabilizer.process(report(issue: nil, seconds: 20))
        let clearingIncident = try #require(firstClear.activeIncidents.first)
        #expect(firstClear.report.state == .warning)
        #expect(clearingIncident.isClearing)
        #expect(clearingIncident.clearSampleCount == 1)
        #expect(clearingIncident.remainingClearSampleCount == 11)
        #expect(clearingIncident.peakSeverity == .critical)

        var recovered = firstClear
        for sample in 2...12 {
            recovered = stabilizer.process(
                report(issue: nil, seconds: TimeInterval(10 + sample * 10))
            )
        }
        let incident = try #require(recovered.changedIncidents.first)

        #expect(incident.id == escalatedID)
        #expect(!(incident.isActive))
        #expect(incident.peakSeverity == .critical)
        #expect(incident.peakMeasurement == 29)
        #expect(incident.currentState == .healthy)
    }

    @Test func recurrenceDuringPressureQuietWindowStaysOneIncident() throws {
        var stabilizer = IncidentStabilizer()
        let first = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 0))
        let firstID = try #require(first.activeIncidents.first?.id)
        for sample in 1...11 {
            _ = stabilizer.process(report(issue: nil, seconds: TimeInterval(sample * 10)))
        }
        let recurrence = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 120))
        let incident = try #require(recurrence.activeIncidents.first)

        #expect(incident.id == firstID)
        #expect(!(incident.isClearing))
        #expect(incident.lastObservedAt == start.addingTimeInterval(120))
    }

    @Test func recurrenceAfterPressureQuietWindowCreatesNewIncident() throws {
        var stabilizer = IncidentStabilizer()
        let first = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 0))
        let firstID = try #require(first.activeIncidents.first?.id)
        var recovered = first
        for sample in 1...12 {
            recovered = stabilizer.process(report(issue: nil, seconds: TimeInterval(sample * 10)))
        }
        #expect(recovered.activeIncidents.isEmpty)

        let recurrence = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 130))
        let recurrenceID = try #require(recurrence.activeIncidents.first?.id)
        #expect(recurrenceID != firstID)
    }

    @Test func restoredPressureIncidentKeepsClearProgress() throws {
        var stabilizer = IncidentStabilizer()
        _ = stabilizer.process(report(issue: storageIssue(state: .critical), seconds: 0))
        var clearing: IncidentProcessingResult?
        for sample in 1...5 {
            clearing = stabilizer.process(report(issue: nil, seconds: TimeInterval(sample * 10)))
        }
        let stored = try #require(clearing?.activeIncidents.first)
        #expect(stored.clearSampleCount == 5)

        var restored = IncidentStabilizer(activeIncidents: [stored])
        let next = restored.process(report(issue: nil, seconds: 60))
        let clearingIncident = try #require(next.activeIncidents.first)
        #expect(clearingIncident.clearSampleCount == 6)
    }

    @Test func simultaneousKindsCreateSeparateIncidents() {
        var stabilizer = IncidentStabilizer()
        let result = stabilizer.process(
            report(
                issues: [
                    storageIssue(state: .critical),
                    HealthIssue(
                        id: "oom",
                        kind: .oom,
                        state: .critical,
                        title: "Out-of-memory kill",
                        explanation: "The kernel killed a process."
                    ),
                ],
                seconds: 0
            ))
        #expect(result.activeIncidents.count == 2)
        #expect(Set(result.activeIncidents.map(\.kind)) == [.diskPressure, .oom])
    }

    @Test func retainsIOEvidenceAfterCauseDisappearsAndRecovery() throws {
        var stabilizer = IncidentStabilizer()
        let evidence = "Peak evidence: example.service (php)."
        let laterEvidence = "Later evidence: other.service (sqlite3)."
        _ = stabilizer.process(
            report(issue: storageIssue(state: .critical, measurement: 29, evidence: evidence), seconds: 0))
        let changed = stabilizer.process(
            report(
                issue: storageIssue(state: .warning, measurement: 10, evidence: laterEvidence),
                seconds: 10
            ))
        let active = try #require(changed.activeIncidents.first)
        #expect(active.retainedEvidence == evidence)
        #expect(active.latestEvidence == laterEvidence)

        var recovered = changed
        for sample in 1...12 {
            recovered = stabilizer.process(
                report(issue: nil, seconds: TimeInterval(10 + sample * 10))
            )
        }
        let recoveredIncident = try #require(recovered.changedIncidents.first)
        #expect(recoveredIncident.retainedEvidence == evidence)
    }

    @Test func discreteOOMAndConnectivityAreImmediate() {
        for issue in [
            HealthIssue(
                id: "oom", kind: .oom, state: .critical, title: "OOM", explanation: "A process was killed."
            ),
            HealthIssue(
                id: "connectivity",
                kind: .connectivity,
                state: .unreachable,
                title: "Unreachable",
                explanation: "SSH failed."
            ),
        ] {
            var stabilizer = IncidentStabilizer()
            #expect(stabilizer.process(report(issue: issue, seconds: 0)).activeIncidents.count == 1)
            #expect(stabilizer.process(report(issue: nil, seconds: 10)).activeIncidents.isEmpty)
        }
    }

    @Test func expectedUnitWarningStabilizesAndRecoversWithoutFlapping() throws {
        let issue = HealthIssue(
            id: "expected-unit:backup.timer",
            kind: .service,
            state: .warning,
            title: "Expected timer is inactive",
            explanation: "backup.timer is inactive."
        )
        var stabilizer = IncidentStabilizer()
        #expect(stabilizer.process(report(issue: issue, seconds: 0)).activeIncidents.isEmpty)
        let active = stabilizer.process(report(issue: issue, seconds: 10))
        #expect(active.activeIncidents.count == 1)

        #expect(stabilizer.process(report(issue: nil, seconds: 20)).activeIncidents.first?.isClearing == true)
        #expect(stabilizer.process(report(issue: issue, seconds: 30)).activeIncidents.count == 1)
        _ = stabilizer.process(report(issue: nil, seconds: 40))
        _ = stabilizer.process(report(issue: nil, seconds: 50))
        let recovered = stabilizer.process(report(issue: nil, seconds: 60))
        #expect(recovered.activeIncidents.isEmpty)
        let recoveredIncident = try #require(recovered.changedIncidents.first)
        #expect(!recoveredIncident.isActive)
    }

    @Test func discreteWorkloadEventsActivateImmediatelyAndRetainTheirScope() throws {
        let workload = WorkloadHealthContext(
            id: "/system.slice/api.service",
            name: "api.service",
            systemdUnit: "api.service"
        )
        let issue = HealthIssue(
            id: "workload:/system.slice/api.service:memory-events",
            kind: .memory,
            state: .warning,
            title: "api.service is under memory pressure",
            explanation: "The workload reported two new memory high events.",
            evidence: "Memory high 800 MB.",
            workload: workload
        )
        var stabilizer = IncidentStabilizer()
        let active = stabilizer.process(report(issue: issue, seconds: 0))
        let incident = try #require(active.activeIncidents.first)

        #expect(incident.workload == workload)
        #expect(incident.healthIssue.workload == workload)
        #expect(active.report.state == .warning)

        let clearing = stabilizer.process(report(issue: nil, seconds: 10))
        let clearingIncident = try #require(clearing.activeIncidents.first)
        #expect(clearingIncident.isClearing)
        _ = stabilizer.process(report(issue: nil, seconds: 20))
        let recovered = stabilizer.process(report(issue: nil, seconds: 30))
        #expect(recovered.activeIncidents.isEmpty)
    }

    @Test func collectionIncidentsUseTheirOwnIssueIDAndActivateImmediately() throws {
        var stabilizer = IncidentStabilizer()
        let result = stabilizer.process(collectionReport(seconds: 0))
        let incident = try #require(result.activeIncidents.first)
        #expect(result.activeIncidents.count == 1)
        #expect(incident.issueID == "metrics-collection")
        #expect(incident.kind == .collection)
        #expect(incident.issueID != "connectivity")
    }

    @Test func collectionFailureRecoversAfterOneSuccessfulCollection() throws {
        var stabilizer = IncidentStabilizer()
        _ = stabilizer.process(collectionReport(seconds: 0))
        let recovered = stabilizer.process(report(issue: nil, seconds: 10))
        let incident = try #require(recovered.changedIncidents.first)
        #expect(!(incident.isActive))
        #expect(recovered.report.state == .healthy)
        #expect(recovered.activeIncidents.isEmpty)
    }

    @Test func collectionAndConnectivityRemainSeparateIncidents() throws {
        var stabilizer = IncidentStabilizer()
        let collection = try #require(stabilizer.process(collectionReport(seconds: 0)).activeIncidents.first)
        let offline = HealthEvaluator.collectionFailure(
            deviceID: "device",
            isReachableThroughTailscale: false,
            failure: .sshUnavailable("Connection timed out"),
            evaluatedAt: start.addingTimeInterval(10)
        )
        let transitioned = stabilizer.process(offline)
        let connectivity = try #require(transitioned.activeIncidents.first)
        #expect(transitioned.activeIncidents.count == 1)
        #expect(connectivity.kind == .connectivity)
        #expect(connectivity.id != collection.id)
        #expect(connectivity.issueID != collection.issueID)
    }

    private func storageIssue(
        state: HealthState,
        measurement: Double = 12,
        evidence: String? = nil
    ) -> HealthIssue {
        HealthIssue(
            id: "io-pressure",
            kind: .diskPressure,
            state: state,
            title: "Storage contention",
            explanation: "\(measurement)% average stall time over 10 seconds.",
            measurement: measurement,
            threshold: state == .critical ? 25 : 8,
            evidence: evidence
        )
    }

    private func report(issue: HealthIssue?, seconds: TimeInterval) -> HealthReport {
        report(issues: issue.map { [$0] } ?? [], seconds: seconds)
    }

    private func report(issues: [HealthIssue], seconds: TimeInterval) -> HealthReport {
        HealthReport(
            deviceID: "device",
            state: issues.map(\.state).max() ?? .healthy,
            summary: issues.first?.title ?? "Healthy",
            issues: issues,
            evaluatedAt: start.addingTimeInterval(seconds)
        )
    }

    private func collectionReport(seconds: TimeInterval) -> HealthReport {
        HealthEvaluator.collectionFailure(
            deviceID: "device",
            isReachableThroughTailscale: true,
            failure: .collectorFailed("ValueError: invalid literal"),
            evaluatedAt: start.addingTimeInterval(seconds)
        )
    }
}
