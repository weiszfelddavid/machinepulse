import Foundation

public struct IncidentProcessingResult: Sendable {
    public let report: HealthReport
    public let changedIncidents: [HealthIncident]
    public let activeIncidents: [HealthIncident]
}

/// Converts sample-level issues into durable incidents while applying hysteresis
/// only to continuously sampled threshold and pressure signals.
public struct IncidentStabilizer: Sendable {
    private var activeByIssueID: [String: HealthIncident]
    private var counters: [String: Counters] = [:]

    public init(activeIncidents: [HealthIncident] = []) {
        let active = activeIncidents.filter(\.isActive)
        activeByIssueID = Dictionary(uniqueKeysWithValues: active.map { ($0.issueID, $0) })
        counters = Dictionary(
            uniqueKeysWithValues: active.compactMap { incident in
                guard incident.clearSampleCount > 0 else { return nil }
                return (
                    incident.issueID,
                    Counters(clearSamples: incident.clearSampleCount)
                )
            }
        )
    }

    public mutating func process(_ rawReport: HealthReport) -> IncidentProcessingResult {
        let observed = Dictionary(uniqueKeysWithValues: rawReport.issues.map { ($0.id, $0) })
        let allIssueIDs = Set(observed.keys).union(activeByIssueID.keys).union(counters.keys)
        var changed: [HealthIncident] = []

        for issueID in allIssueIDs.sorted() {
            if let issue = observed[issueID] {
                var state = counters[issueID] ?? Counters()
                state.clearSamples = 0

                if var incident = activeByIssueID[issueID] {
                    state.warningSamples = 0
                    state.firstWarningAt = nil
                    incident.update(with: issue, at: rawReport.evaluatedAt)
                    activeByIssueID[issueID] = incident
                    changed.append(incident)
                } else if issue.state == .critical || issue.state == .unreachable || policy(for: issue) == .immediate {
                    state.warningSamples = 0
                    let startedAt = state.firstWarningAt ?? rawReport.evaluatedAt
                    state.firstWarningAt = nil
                    let incident = HealthIncident(
                        issue: issue,
                        deviceID: rawReport.deviceID,
                        at: rawReport.evaluatedAt,
                        startedAt: startedAt
                    )
                    activeByIssueID[issueID] = incident
                    changed.append(incident)
                } else {
                    if state.warningSamples == 0 {
                        state.firstWarningAt = rawReport.evaluatedAt
                    }
                    state.warningSamples += 1
                    if state.warningSamples >= 2 {
                        state.warningSamples = 0
                        let startedAt = state.firstWarningAt ?? rawReport.evaluatedAt
                        state.firstWarningAt = nil
                        let incident = HealthIncident(
                            issue: issue,
                            deviceID: rawReport.deviceID,
                            at: rawReport.evaluatedAt,
                            startedAt: startedAt
                        )
                        activeByIssueID[issueID] = incident
                        changed.append(incident)
                    }
                }
                counters[issueID] = state
            } else if var incident = activeByIssueID[issueID] {
                var state = counters[issueID] ?? Counters()
                state.warningSamples = 0
                state.firstWarningAt = nil
                state.clearSamples += 1
                let requiredClearSamples = clearSamplesRequired(for: incident)
                if state.clearSamples >= requiredClearSamples {
                    incident.resolve(at: rawReport.evaluatedAt)
                    activeByIssueID[issueID] = nil
                    counters[issueID] = nil
                    changed.append(incident)
                } else {
                    incident.markClearing(
                        clearSampleCount: state.clearSamples,
                        requiredClearSampleCount: requiredClearSamples,
                        at: rawReport.evaluatedAt
                    )
                    activeByIssueID[issueID] = incident
                    counters[issueID] = state
                    changed.append(incident)
                }
            } else {
                counters[issueID] = nil
            }
        }

        let active = activeByIssueID.values.sorted {
            if $0.currentState != $1.currentState { return $0.currentState > $1.currentState }
            return $0.startedAt < $1.startedAt
        }
        let issues = active.map(\.healthIssue)
        let state = issues.map(\.state).max() ?? .healthy
        let report = HealthReport(
            deviceID: rawReport.deviceID,
            state: state,
            summary: issues.first?.title ?? "Everything looks steady",
            issues: issues,
            evaluatedAt: rawReport.evaluatedAt
        )
        return IncidentProcessingResult(
            report: report,
            changedIncidents: changed,
            activeIncidents: active
        )
    }

    private func policy(for issue: HealthIssue) -> StabilizationPolicy {
        if issue.id.hasPrefix("expected-unit:") { return .sampledThreshold }
        if issue.id.hasPrefix("workload:"),
            issue.id.hasSuffix(":memory-events") || issue.id.hasSuffix(":tasks")
        {
            return .immediate
        }
        return policy(for: issue.kind)
    }

    private func policy(for kind: HealthIssueKind) -> StabilizationPolicy {
        switch kind {
        case .connectivity, .collection, .oom, .service:
            .immediate
        case .cpu, .memory, .swap, .diskCapacity, .diskPressure, .memoryPressure:
            .sampledThreshold
        }
    }

    private func clearSamplesRequired(for incident: HealthIncident) -> Int {
        if incident.issueID.hasPrefix("expected-unit:") { return 3 }
        if policy(for: incident.kind) == .immediate { return 1 }
        switch incident.issueID {
        case "cpu-pressure", "io-pressure", "memory-pressure":
            return 12
        default:
            if incident.issueID.hasPrefix("workload:"),
                incident.issueID.hasSuffix(":io-pressure")
            {
                return 12
            }
            return 3
        }
    }
}

private struct Counters: Sendable {
    var warningSamples = 0
    var clearSamples = 0
    var firstWarningAt: Date?
}

private enum StabilizationPolicy {
    case sampledThreshold
    case immediate
}
