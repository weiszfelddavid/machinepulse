import Foundation
import MachinePulseCore
import Testing

@Suite("Popover presentation")
struct PopoverPresentationTests {
    @Test("Recovered incidents remain featured for five minutes")
    func recoveredIncidentVisibility() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let issue = HealthIssue(
            id: "io-pressure",
            kind: .diskPressure,
            state: .warning,
            title: "Storage contention",
            explanation: "Storage wait is elevated."
        )
        var incident = HealthIncident(
            issue: issue,
            deviceID: "server",
            at: now.addingTimeInterval(-600)
        )
        incident.resolve(at: now.addingTimeInterval(-300))

        #expect(FeaturedIncidentPolicy.select(from: [incident], at: now)?.id == incident.id)
        #expect(
            FeaturedIncidentPolicy.select(
                from: [incident],
                at: now.addingTimeInterval(1)
            ) == nil
        )
    }

    @Test("Active incidents remain featured regardless of age")
    func activeIncidentVisibility() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let issue = HealthIssue(
            id: "cpu-pressure",
            kind: .cpu,
            state: .warning,
            title: "CPU contention",
            explanation: "CPU wait is elevated."
        )
        let incident = HealthIncident(
            issue: issue,
            deviceID: "server",
            at: now.addingTimeInterval(-86_400)
        )

        #expect(FeaturedIncidentPolicy.select(from: [incident], at: now)?.id == incident.id)
    }

    @Test("The most severe active incident leads, ties go to the oldest, recovered ones to the latest")
    func featuredIncidentOrdering() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func incident(_ state: HealthState, startedAgo: TimeInterval, endedAgo: TimeInterval? = nil) -> HealthIncident {
            var incident = HealthIncident(
                issue: HealthIssue(id: "cpu", kind: .cpu, state: state, title: "CPU is busy", explanation: ""),
                deviceID: "server",
                at: now.addingTimeInterval(-startedAgo)
            )
            if let endedAgo { incident.resolve(at: now.addingTimeInterval(-endedAgo)) }
            return incident
        }
        let olderWarning = incident(.warning, startedAgo: 600)
        let newerCritical = incident(.critical, startedAgo: 60)
        let oldestCritical = incident(.critical, startedAgo: 900)
        let recoveredEarlier = incident(.critical, startedAgo: 900, endedAgo: 240)
        let recoveredLater = incident(.warning, startedAgo: 600, endedAgo: 30)

        #expect(FeaturedIncidentPolicy.select(from: [olderWarning, newerCritical], at: now)?.id == newerCritical.id)
        #expect(FeaturedIncidentPolicy.select(from: [newerCritical, oldestCritical], at: now)?.id == oldestCritical.id)
        #expect(
            FeaturedIncidentPolicy.select(from: [recoveredLater, recoveredEarlier], at: now)?.id == recoveredLater.id)
        #expect(FeaturedIncidentPolicy.select(from: [recoveredEarlier, olderWarning], at: now)?.id == olderWarning.id)
    }

    @Test("New incidents expand once and respect a manual collapse")
    func incidentExpansionPrecedence() {
        let firstIncident = UUID()
        let secondIncident = UUID()
        var state = MachineCardExpansionState()

        state.reconcile(deviceIDs: ["server"], activeIncidentIDs: ["server": firstIncident])
        #expect(state.isExpanded("server"))

        state.setExpanded(false, deviceID: "server", activeIncidentID: firstIncident)
        state.reconcile(deviceIDs: ["server"], activeIncidentIDs: ["server": firstIncident])
        #expect(!state.isExpanded("server"))

        state.reconcile(deviceIDs: ["server"], activeIncidentIDs: ["server": secondIncident])
        #expect(state.isExpanded("server"))
    }

    @Test("Bulk expansion state affects only visible machines")
    func globalExpansion() {
        let incident = UUID()
        var state = MachineCardExpansionState(expandedDeviceIDs: ["hidden"])

        state.setAllExpanded(
            true,
            deviceIDs: ["local", "server"],
            activeIncidentIDs: [:]
        )
        #expect(state.isExpanded("local") && state.isExpanded("server"))
        #expect(state.isExpanded("hidden"))

        state.setAllExpanded(
            false,
            deviceIDs: ["local", "server"],
            activeIncidentIDs: ["server": incident]
        )
        #expect(!state.isExpanded("local") && !state.isExpanded("server"))
        #expect(state.isExpanded("hidden"))

        state.reconcile(deviceIDs: ["local", "server"], activeIncidentIDs: ["server": incident])
        #expect(!state.isExpanded("server"))
        #expect(!state.isExpanded("hidden"))
    }
}
