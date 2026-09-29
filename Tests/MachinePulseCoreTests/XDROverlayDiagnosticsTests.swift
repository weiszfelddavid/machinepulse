import Foundation
import Testing
@testable import MachinePulseCore

struct XDROverlayDiagnosticsTests {
    private let displayID = LocalDisplayID(rawValue: "built-in-xdr")
    private let instanceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ordinaryMaintenanceKeepsOneOverlayIdentity() throws {
        var audit = XDROverlayLifecycleAudit()
        audit.recordActivation(displayID: displayID, instanceID: instanceID, at: start)

        for second in 1...300 {
            audit.recordUpdate(
                displayID: displayID,
                geometryChanged: false,
                multiplierChanged: false,
                at: start.addingTimeInterval(TimeInterval(second))
            )
        }
        audit.recordReassertion(
            displayID: displayID,
            reason: .activeSpaceChanged,
            at: start.addingTimeInterval(301)
        )
        audit.recordUpdate(
            displayID: displayID,
            geometryChanged: true,
            multiplierChanged: false,
            at: start.addingTimeInterval(302)
        )

        let record = try #require(audit.snapshot().activeOverlays.first)
        #expect(record.instanceID == instanceID)
        #expect(record.geometryChangeCount == 1)
        #expect(record.multiplierChangeCount == 0)
        #expect(record.reassertionCount == 1)
        #expect(audit.snapshot().recentEvents.count == 3)
    }

    @Test func duplicateActivationCannotReplaceTheRecordedInstance() throws {
        var audit = XDROverlayLifecycleAudit()
        audit.recordActivation(displayID: displayID, instanceID: instanceID, at: start)
        audit.recordActivation(displayID: displayID, instanceID: UUID(), at: start.addingTimeInterval(1))

        let snapshot = audit.snapshot()
        let firstOverlay = try #require(snapshot.activeOverlays.first)
        #expect(firstOverlay.instanceID == instanceID)
        #expect(snapshot.recentEvents.last?.kind == .duplicateActivationAttempt)
    }

    @Test func visibilityRestorationAndReassertionAreExplicitWithoutRecreation() throws {
        var audit = XDROverlayLifecycleAudit()
        audit.recordActivation(displayID: displayID, instanceID: instanceID, at: start)
        audit.recordVisibilityRestore(displayID: displayID, at: start.addingTimeInterval(1))
        audit.recordReassertion(
            displayID: displayID,
            reason: .applicationBecameActive,
            at: start.addingTimeInterval(2)
        )

        let record = try #require(audit.snapshot().activeOverlays.first)
        #expect(record.instanceID == instanceID)
        #expect(record.visibilityRestoreCount == 1)
        #expect(record.reassertionCount == 1)
        #expect(record.lastReassertionReason == .applicationBecameActive)
    }

    @Test func teardownRemovesOnlyTheRequestedOverlay() {
        var audit = XDROverlayLifecycleAudit()
        let external = LocalDisplayID(rawValue: "external-xdr")
        audit.recordActivation(displayID: displayID, instanceID: instanceID, at: start)
        audit.recordActivation(displayID: external, instanceID: UUID(), at: start)
        audit.recordDeactivation(displayID: displayID, at: start.addingTimeInterval(1))

        #expect(audit.snapshot().activeOverlays.map(\.displayID) == [external])
        #expect(audit.snapshot().recentEvents.last?.kind == .deactivated)
    }

    @Test func lifecycleDiagnosticsStayBounded() {
        var audit = XDROverlayLifecycleAudit()
        audit.recordActivation(displayID: displayID, instanceID: instanceID, at: start)
        for index in 1...100 {
            audit.recordReassertion(
                displayID: displayID,
                reason: .screenParametersChanged,
                at: start.addingTimeInterval(TimeInterval(index))
            )
        }

        let snapshot = audit.snapshot()
        #expect(snapshot.recentEvents.count == XDROverlayRenderPolicy.retainedEventLimit)
        #expect(snapshot.droppedEventCount == 53)
        #expect(snapshot.recentEvents.first?.kind == .reasserted)
    }
}
