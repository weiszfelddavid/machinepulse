import Foundation

public enum MachineSectionFilter: String, CaseIterable, Identifiable, Sendable {
    case overview
    case vitals
    case displays
    case workloads
    case storage

    public var id: Self { self }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .vitals: "Vitals"
        case .displays: "Displays"
        case .workloads: "Workloads"
        case .storage: "Storage"
        }
    }
}

public enum FeaturedIncidentPolicy {
    public static let recoveredVisibilityDuration: TimeInterval = 5 * 60

    public static func select(
        from incidents: [HealthIncident],
        at now: Date = Date()
    ) -> HealthIncident? {
        let active = incidents.filter(\.isActive).sorted {
            if $0.currentState != $1.currentState { return $0.currentState > $1.currentState }
            return $0.startedAt < $1.startedAt
        }
        if let activeIncident = active.first { return activeIncident }

        return
            incidents
            .filter { incident in
                guard let endedAt = incident.endedAt else { return false }
                let age = now.timeIntervalSince(endedAt)
                return age >= 0 && age <= recoveredVisibilityDuration
            }
            .max { lhs, rhs in
                (lhs.endedAt ?? .distantPast) < (rhs.endedAt ?? .distantPast)
            }
    }
}

public struct MachineCardExpansionState: Equatable, Sendable {
    public private(set) var expandedDeviceIDs: Set<String>
    public private(set) var observedIncidentIDs: [String: UUID]
    public private(set) var manuallyCollapsedIncidentIDs: [String: UUID]

    public init(
        expandedDeviceIDs: Set<String> = [],
        observedIncidentIDs: [String: UUID] = [:],
        manuallyCollapsedIncidentIDs: [String: UUID] = [:]
    ) {
        self.expandedDeviceIDs = expandedDeviceIDs
        self.observedIncidentIDs = observedIncidentIDs
        self.manuallyCollapsedIncidentIDs = manuallyCollapsedIncidentIDs
    }

    public func isExpanded(_ deviceID: String) -> Bool {
        expandedDeviceIDs.contains(deviceID)
    }

    public mutating func reconcile(
        deviceIDs: Set<String>,
        activeIncidentIDs: [String: UUID],
        automaticallyExpandNewIncidents: Bool = true
    ) {
        expandedDeviceIDs.formIntersection(deviceIDs)
        observedIncidentIDs = observedIncidentIDs.filter { deviceIDs.contains($0.key) }
        manuallyCollapsedIncidentIDs = manuallyCollapsedIncidentIDs.filter {
            deviceIDs.contains($0.key) && activeIncidentIDs[$0.key] == $0.value
        }

        for deviceID in deviceIDs {
            guard let incidentID = activeIncidentIDs[deviceID] else {
                observedIncidentIDs[deviceID] = nil
                manuallyCollapsedIncidentIDs[deviceID] = nil
                continue
            }
            guard observedIncidentIDs[deviceID] != incidentID else { continue }
            observedIncidentIDs[deviceID] = incidentID
            guard automaticallyExpandNewIncidents,
                manuallyCollapsedIncidentIDs[deviceID] != incidentID
            else { continue }
            expandedDeviceIDs.insert(deviceID)
        }
    }

    public mutating func setExpanded(
        _ expanded: Bool,
        deviceID: String,
        activeIncidentID: UUID?
    ) {
        if expanded {
            expandedDeviceIDs.insert(deviceID)
            manuallyCollapsedIncidentIDs[deviceID] = nil
        } else {
            expandedDeviceIDs.remove(deviceID)
            manuallyCollapsedIncidentIDs[deviceID] = activeIncidentID
        }
    }

    public mutating func setAllExpanded(
        _ expanded: Bool,
        deviceIDs: [String],
        activeIncidentIDs: [String: UUID]
    ) {
        for deviceID in deviceIDs {
            setExpanded(
                expanded,
                deviceID: deviceID,
                activeIncidentID: activeIncidentIDs[deviceID]
            )
        }
    }
}
