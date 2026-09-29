import Foundation

public enum HealthState: Int, Codable, Comparable, CaseIterable, Sendable {
    case healthy = 0
    case warning = 1
    case unreachable = 2
    case critical = 3

    public static func < (lhs: HealthState, rhs: HealthState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Warning"
        case .unreachable: "Unreachable"
        case .critical: "Critical"
        }
    }
}

public enum HealthIssueKind: String, Codable, Sendable {
    case connectivity
    case collection
    case cpu
    case memory
    case swap
    case diskCapacity
    case diskPressure
    case memoryPressure
    case service
    case oom
}

/// Identifies a finding that belongs to one bounded workload rather than the
/// whole machine. The identifier matches a WorkloadResourceControlMetric.
public struct WorkloadHealthContext: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let systemdUnit: String?

    public init(id: String, name: String, systemdUnit: String? = nil) {
        self.id = id
        self.name = name
        self.systemdUnit = systemdUnit
    }
}

public struct HealthIssue: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: HealthIssueKind
    public let state: HealthState
    public let title: String
    public let explanation: String
    public let measurement: Double?
    public let threshold: Double?
    public let evidence: String?
    public let workload: WorkloadHealthContext?

    public init(
        id: String,
        kind: HealthIssueKind,
        state: HealthState,
        title: String,
        explanation: String,
        measurement: Double? = nil,
        threshold: Double? = nil,
        evidence: String? = nil,
        workload: WorkloadHealthContext? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.title = title
        self.explanation = explanation
        self.measurement = measurement
        self.threshold = threshold
        self.evidence = evidence
        self.workload = workload
    }
}

public struct HealthReport: Codable, Hashable, Sendable {
    public let deviceID: String
    public let state: HealthState
    public let summary: String
    public let issues: [HealthIssue]
    public let evaluatedAt: Date

    public init(
        deviceID: String,
        state: HealthState,
        summary: String,
        issues: [HealthIssue],
        evaluatedAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.state = state
        self.summary = summary
        self.issues = issues
        self.evaluatedAt = evaluatedAt
    }
}

public struct IncidentObservationContext: Codable, Hashable, Sendable {
    public var latestMeasurement: Double?
    public var latestThreshold: Double?
    public var latestEvidence: String?
    public var lastObservedAt: Date
    public var peakObservedAt: Date?
    public var peakExplanation: String
    public var clearSampleCount: Int
    public var requiredClearSampleCount: Int

    public init(
        latestMeasurement: Double? = nil,
        latestThreshold: Double? = nil,
        latestEvidence: String? = nil,
        lastObservedAt: Date,
        peakObservedAt: Date? = nil,
        peakExplanation: String,
        clearSampleCount: Int = 0,
        requiredClearSampleCount: Int = 0
    ) {
        self.latestMeasurement = latestMeasurement
        self.latestThreshold = latestThreshold
        self.latestEvidence = latestEvidence
        self.lastObservedAt = lastObservedAt
        self.peakObservedAt = peakObservedAt
        self.peakExplanation = peakExplanation
        self.clearSampleCount = clearSampleCount
        self.requiredClearSampleCount = requiredClearSampleCount
    }
}

public struct HealthIncident: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let deviceID: String
    public let issueID: String
    public let kind: HealthIssueKind
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var currentState: HealthState
    public private(set) var peakSeverity: HealthState
    public private(set) var latestTitle: String
    public private(set) var latestExplanation: String
    public private(set) var peakMeasurement: Double?
    public private(set) var peakThreshold: Double?
    public private(set) var retainedEvidence: String?
    public private(set) var updatedAt: Date
    public private(set) var observationContext: IncidentObservationContext?
    public private(set) var workload: WorkloadHealthContext?

    public init(
        id: UUID = UUID(),
        deviceID: String,
        issueID: String,
        kind: HealthIssueKind,
        startedAt: Date,
        endedAt: Date? = nil,
        currentState: HealthState,
        peakSeverity: HealthState,
        latestTitle: String,
        latestExplanation: String,
        peakMeasurement: Double? = nil,
        peakThreshold: Double? = nil,
        retainedEvidence: String? = nil,
        updatedAt: Date,
        observationContext: IncidentObservationContext? = nil,
        workload: WorkloadHealthContext? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.issueID = issueID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.currentState = currentState
        self.peakSeverity = peakSeverity
        self.latestTitle = latestTitle
        self.latestExplanation = latestExplanation
        self.peakMeasurement = peakMeasurement
        self.peakThreshold = peakThreshold
        self.retainedEvidence = retainedEvidence
        self.updatedAt = updatedAt
        self.observationContext = observationContext
        self.workload = workload
    }

    public init(
        issue: HealthIssue,
        deviceID: String,
        at date: Date,
        startedAt: Date? = nil,
        id: UUID = UUID()
    ) {
        self.init(
            id: id,
            deviceID: deviceID,
            issueID: issue.id,
            kind: issue.kind,
            startedAt: startedAt ?? date,
            currentState: issue.state,
            peakSeverity: issue.state,
            latestTitle: issue.title,
            latestExplanation: issue.explanation,
            peakMeasurement: issue.measurement,
            peakThreshold: issue.threshold,
            retainedEvidence: issue.evidence,
            updatedAt: date,
            observationContext: IncidentObservationContext(
                latestMeasurement: issue.measurement,
                latestThreshold: issue.threshold,
                latestEvidence: issue.evidence,
                lastObservedAt: date,
                peakObservedAt: issue.measurement == nil ? nil : date,
                peakExplanation: issue.explanation
            ),
            workload: issue.workload
        )
    }

    public var isActive: Bool {
        endedAt == nil && currentState != .healthy
    }

    public var duration: TimeInterval {
        max(0, (endedAt ?? updatedAt).timeIntervalSince(startedAt))
    }

    public var latestMeasurement: Double? {
        observationContext?.latestMeasurement ?? peakMeasurement
    }

    public var latestThreshold: Double? {
        observationContext?.latestThreshold ?? peakThreshold
    }

    public var latestEvidence: String? {
        observationContext?.latestEvidence ?? retainedEvidence
    }

    public var lastObservedAt: Date {
        observationContext?.lastObservedAt ?? updatedAt
    }

    public var peakObservedAt: Date {
        observationContext?.peakObservedAt ?? startedAt
    }

    public var clearSampleCount: Int {
        observationContext?.clearSampleCount ?? 0
    }

    public var requiredClearSampleCount: Int {
        observationContext?.requiredClearSampleCount ?? 0
    }

    public var isClearing: Bool {
        isActive && clearSampleCount > 0
    }

    public var remainingClearSampleCount: Int {
        max(0, requiredClearSampleCount - clearSampleCount)
    }

    public var presentationTitle: String {
        switch issueID {
        case "io-pressure": "Storage contention"
        case "cpu-pressure": "CPU contention"
        case "memory-pressure": "Memory contention"
        case "mac-memory-pressure": "Memory pressure"
        case "cpu": "High CPU utilization"
        case "memory": "Memory is tight"
        case "swap": "Swap and memory pressure"
        case "disk-capacity": "Disk space is running low"
        case "connectivity": "Machine is unreachable"
        case "oom": "Out-of-memory kill"
        default: latestTitle
        }
    }

    public mutating func update(with issue: HealthIssue, at date: Date) {
        guard isActive, issue.id == issueID else { return }
        let previousPeakSeverity = peakSeverity
        let measurementIncreased =
            issue.measurement.map { measurement in
                peakMeasurement.map { measurement > $0 } ?? true
            } ?? false
        let severityIncreased = issue.state > previousPeakSeverity
        var context = observationContext ?? legacyObservationContext

        currentState = issue.state
        peakSeverity = max(peakSeverity, issue.state)
        latestTitle = issue.title
        latestExplanation = issue.explanation
        workload = issue.workload
        context.latestMeasurement = issue.measurement
        context.latestThreshold = issue.threshold
        context.latestEvidence = issue.evidence
        context.lastObservedAt = date
        context.clearSampleCount = 0
        context.requiredClearSampleCount = 0

        if let measurement = issue.measurement, measurementIncreased {
            peakMeasurement = measurement
            peakThreshold = issue.threshold
            context.peakObservedAt = date
            context.peakExplanation = issue.explanation
            retainedEvidence = issue.evidence
        } else if severityIncreased {
            context.peakObservedAt = date
            context.peakExplanation = issue.explanation
            retainedEvidence = issue.evidence ?? retainedEvidence
        } else if issue.state == peakSeverity, peakThreshold == nil {
            peakThreshold = issue.threshold
        }
        if retainedEvidence == nil, let evidence = issue.evidence, !evidence.isEmpty {
            retainedEvidence = evidence
        }
        observationContext = context
        updatedAt = date
    }

    public mutating func markClearing(
        clearSampleCount: Int,
        requiredClearSampleCount: Int,
        at date: Date
    ) {
        guard isActive else { return }
        var context = observationContext ?? legacyObservationContext
        context.clearSampleCount = max(0, clearSampleCount)
        context.requiredClearSampleCount = max(context.clearSampleCount, requiredClearSampleCount)
        observationContext = context
        currentState = .warning
        updatedAt = date
    }

    public mutating func resolve(at date: Date) {
        guard isActive else { return }
        endedAt = date
        currentState = .healthy
        updatedAt = date
    }

    public var healthIssue: HealthIssue {
        if isClearing {
            let remaining = remainingClearSampleCount
            return HealthIssue(
                id: issueID,
                kind: kind,
                state: .warning,
                title: "\(presentationTitle) clearing",
                explanation:
                    "Not observed in the latest sample; waiting for \(remaining) more clear sample\(remaining == 1 ? "" : "s") before recovery.",
                workload: workload
            )
        }
        return HealthIssue(
            id: issueID,
            kind: kind,
            state: currentState,
            title: latestTitle,
            explanation: latestExplanation,
            measurement: latestMeasurement,
            threshold: latestThreshold,
            evidence: latestEvidence,
            workload: workload
        )
    }

    private var legacyObservationContext: IncidentObservationContext {
        IncidentObservationContext(
            latestMeasurement: peakMeasurement,
            latestThreshold: peakThreshold,
            latestEvidence: retainedEvidence,
            lastObservedAt: updatedAt,
            peakObservedAt: peakMeasurement == nil ? nil : startedAt,
            peakExplanation: latestExplanation
        )
    }
}
