import Foundation

/// Rendering and diagnostic bounds shared by the AppKit adapter and its
/// deterministic lifecycle tests.
public enum XDROverlayRenderPolicy {
    public static let framesPerSecond = 10
    public static let retainedEventLimit = 48
}

public enum XDROverlayReassertionReason: String, Codable, Hashable, Sendable {
    case applicationBecameActive
    case applicationResignedActive
    case screenParametersChanged
    case activeSpaceChanged
}

public enum XDROverlayLifecycleEventKind: String, Codable, Hashable, Sendable {
    case activated
    case duplicateActivationAttempt
    case geometryChanged
    case multiplierChanged
    case reasserted
    case visibilityRestored
    case deactivated
}

public struct XDROverlayLifecycleEvent: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let displayID: LocalDisplayID
    public let instanceID: UUID
    public let kind: XDROverlayLifecycleEventKind
    public let reassertionReason: XDROverlayReassertionReason?

    public init(
        timestamp: Date,
        displayID: LocalDisplayID,
        instanceID: UUID,
        kind: XDROverlayLifecycleEventKind,
        reassertionReason: XDROverlayReassertionReason? = nil
    ) {
        self.timestamp = timestamp
        self.displayID = displayID
        self.instanceID = instanceID
        self.kind = kind
        self.reassertionReason = reassertionReason
    }
}

public struct XDROverlayLifecycleRecord: Codable, Hashable, Sendable {
    public let displayID: LocalDisplayID
    public let instanceID: UUID
    public let activatedAt: Date
    public fileprivate(set) var geometryChangeCount: Int
    public fileprivate(set) var multiplierChangeCount: Int
    public fileprivate(set) var reassertionCount: Int
    public fileprivate(set) var visibilityRestoreCount: Int
    public fileprivate(set) var lastReassertionReason: XDROverlayReassertionReason?
}

public struct XDROverlayLifecycleSnapshot: Codable, Hashable, Sendable {
    public let activeOverlays: [XDROverlayLifecycleRecord]
    public let recentEvents: [XDROverlayLifecycleEvent]
    public let droppedEventCount: Int

    public init(
        activeOverlays: [XDROverlayLifecycleRecord],
        recentEvents: [XDROverlayLifecycleEvent],
        droppedEventCount: Int
    ) {
        self.activeOverlays = activeOverlays
        self.recentEvents = recentEvents
        self.droppedEventCount = droppedEventCount
    }
}

/// Tracks identity-affecting overlay operations without observing pixels. The
/// event buffer is deliberately bounded and is reset at each app launch.
public struct XDROverlayLifecycleAudit: Sendable {
    private var activeOverlays: [LocalDisplayID: XDROverlayLifecycleRecord] = [:]
    private var recentEvents: [XDROverlayLifecycleEvent] = []
    private var droppedEventCount = 0

    public init() {}

    public mutating func recordActivation(
        displayID: LocalDisplayID,
        instanceID: UUID,
        at timestamp: Date
    ) {
        if let existing = activeOverlays[displayID] {
            append(
                XDROverlayLifecycleEvent(
                    timestamp: timestamp,
                    displayID: displayID,
                    instanceID: existing.instanceID,
                    kind: .duplicateActivationAttempt
                ))
            return
        }
        activeOverlays[displayID] = XDROverlayLifecycleRecord(
            displayID: displayID,
            instanceID: instanceID,
            activatedAt: timestamp,
            geometryChangeCount: 0,
            multiplierChangeCount: 0,
            reassertionCount: 0,
            visibilityRestoreCount: 0
        )
        append(
            XDROverlayLifecycleEvent(
                timestamp: timestamp,
                displayID: displayID,
                instanceID: instanceID,
                kind: .activated
            ))
    }

    public mutating func recordUpdate(
        displayID: LocalDisplayID,
        geometryChanged: Bool,
        multiplierChanged: Bool,
        at timestamp: Date
    ) {
        guard var record = activeOverlays[displayID] else { return }
        if geometryChanged {
            record.geometryChangeCount += 1
            append(
                XDROverlayLifecycleEvent(
                    timestamp: timestamp,
                    displayID: displayID,
                    instanceID: record.instanceID,
                    kind: .geometryChanged
                ))
        }
        if multiplierChanged {
            record.multiplierChangeCount += 1
            append(
                XDROverlayLifecycleEvent(
                    timestamp: timestamp,
                    displayID: displayID,
                    instanceID: record.instanceID,
                    kind: .multiplierChanged
                ))
        }
        activeOverlays[displayID] = record
    }

    public mutating func recordReassertion(
        displayID: LocalDisplayID,
        reason: XDROverlayReassertionReason,
        at timestamp: Date
    ) {
        guard var record = activeOverlays[displayID] else { return }
        record.reassertionCount += 1
        record.lastReassertionReason = reason
        activeOverlays[displayID] = record
        append(
            XDROverlayLifecycleEvent(
                timestamp: timestamp,
                displayID: displayID,
                instanceID: record.instanceID,
                kind: .reasserted,
                reassertionReason: reason
            ))
    }

    public mutating func recordVisibilityRestore(displayID: LocalDisplayID, at timestamp: Date) {
        guard var record = activeOverlays[displayID] else { return }
        record.visibilityRestoreCount += 1
        activeOverlays[displayID] = record
        append(
            XDROverlayLifecycleEvent(
                timestamp: timestamp,
                displayID: displayID,
                instanceID: record.instanceID,
                kind: .visibilityRestored
            ))
    }

    public mutating func recordDeactivation(displayID: LocalDisplayID, at timestamp: Date) {
        guard let record = activeOverlays.removeValue(forKey: displayID) else { return }
        append(
            XDROverlayLifecycleEvent(
                timestamp: timestamp,
                displayID: displayID,
                instanceID: record.instanceID,
                kind: .deactivated
            ))
    }

    public func snapshot() -> XDROverlayLifecycleSnapshot {
        XDROverlayLifecycleSnapshot(
            activeOverlays: activeOverlays.values.sorted { $0.displayID.rawValue < $1.displayID.rawValue },
            recentEvents: recentEvents,
            droppedEventCount: droppedEventCount
        )
    }

    private mutating func append(_ event: XDROverlayLifecycleEvent) {
        recentEvents.append(event)
        if recentEvents.count > XDROverlayRenderPolicy.retainedEventLimit {
            recentEvents.removeFirst(recentEvents.count - XDROverlayRenderPolicy.retainedEventLimit)
            droppedEventCount += 1
        }
    }
}
