import Foundation
import Testing
@testable import MachinePulseCore

struct LocalDisplayControlTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func supportedAndUnsupportedDisplaysRemainDistinct() {
        let xdr = display("built-in", potential: 16)
        let ordinary = display("external", potential: 1)

        #expect(xdr.supportsXDR)
        #expect(xdr.maximumProductBoost == 2)
        #expect(!(ordinary.supportsXDR))
        #expect(ordinary.maximumProductBoost == 1)
    }

    @Test func stableIdentitySurvivesReconnect() {
        let first = LocalDisplayID(vendor: 1552, product: 41038, serial: 4_251_086_178, unit: 0)
        let reconnected = LocalDisplayID(vendor: 1552, product: 41038, serial: 4_251_086_178, unit: 4)
        let seriallessOtherUnit = LocalDisplayID(vendor: 1507, product: 10128, serial: 0, unit: 5)
        #expect(first == reconnected)
        #expect(seriallessOtherUnit != LocalDisplayID(vendor: 1507, product: 10128, serial: 0, unit: 6))
    }

    @Test func multiplierBootstrapsAndClampsToDynamicHeadroom() {
        var manager = LocalDisplaySessionManager()
        let waiting = display("xdr", potential: 16, current: 1)
        let preferences = enabledPreferences()
        #expect(
            manager.enable(display: waiting, preferences: preferences, environment: .init(), now: now) == [
                .activate(displayID: waiting.id, multiplier: 1.01)
            ])

        let available = display("xdr", potential: 16, current: 1.2)
        #expect(
            manager.reconcile(
                displays: [available],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(1)
            ) == [.update(displayID: available.id, multiplier: 1.2)])
        #expect(manager.activeSessions[available.id]?.appliedMultiplier == 1.2)
    }

    @Test func multipleDisplaysKeepIndependentState() {
        var manager = LocalDisplaySessionManager()
        let first = display("first", potential: 4, current: 2)
        let second = display("second", potential: 3, current: 1.5)
        var preferences = enabledPreferences()
        preferences.setPreferredBoost(1.8, for: first)
        preferences.setPreferredBoost(1.4, for: second)
        _ = manager.enable(display: first, preferences: preferences, environment: .init(), now: now)
        _ = manager.enable(display: second, preferences: preferences, environment: .init(), now: now)

        #expect(manager.activeSessions.count == 2)
        #expect(manager.activeSessions[first.id]?.appliedMultiplier == 1.8)
        #expect(manager.activeSessions[second.id]?.appliedMultiplier == 1.4)
        _ = manager.disable(displayID: first.id)
        #expect(manager.activeSessions[first.id] == nil)
        #expect(manager.activeSessions[second.id] != nil)
    }

    @Test func timeoutTurnsBoostOff() {
        var manager = LocalDisplaySessionManager()
        let xdr = display("xdr", potential: 4, current: 2)
        let preferences = enabledPreferences(timeoutMinutes: 30)
        _ = manager.enable(display: xdr, preferences: preferences, environment: .init(), now: now)
        #expect(
            manager.reconcile(
                displays: [xdr],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(1_800)
            ) == [.deactivate(displayID: xdr.id, reason: .timeout)])
    }

    @Test func disappearingRuntimeHeadroomTurnsBoostOffAfterGrace() {
        var manager = LocalDisplaySessionManager()
        let available = display("xdr", potential: 4, current: 2)
        let preferences = enabledPreferences()
        _ = manager.enable(display: available, preferences: preferences, environment: .init(), now: now)
        let limited = display("xdr", potential: 4, current: 1)
        #expect(
            manager.reconcile(
                displays: [limited],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(3)
            ) == [.deactivate(displayID: limited.id, reason: .currentHeadroomUnavailable)])
    }

    @Test func runtimeHeadroomReductionClampsAnActiveSessionInPlace() {
        var manager = LocalDisplaySessionManager()
        let initial = display("xdr", potential: 4, current: 2)
        var preferences = enabledPreferences()
        preferences.setPreferredBoost(1.8, for: initial)
        _ = manager.enable(display: initial, preferences: preferences, environment: .init(), now: now)

        let reduced = display("xdr", potential: 4, current: 1.25)
        #expect(
            manager.reconcile(
                displays: [reduced],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(1)
            ) == [.update(displayID: reduced.id, multiplier: 1.25)])
        #expect(manager.activeSessions[reduced.id]?.requestedMultiplier == 1.8)
        #expect(manager.activeSessions[reduced.id]?.appliedMultiplier == 1.25)
    }

    @Test func disablingTheModuleImmediatelyRemovesEverySession() {
        var manager = LocalDisplaySessionManager()
        let first = display("first", potential: 4, current: 2)
        let second = display("second", potential: 4, current: 2)
        let enabled = enabledPreferences()
        _ = manager.enable(display: first, preferences: enabled, environment: .init(), now: now)
        _ = manager.enable(display: second, preferences: enabled, environment: .init(), now: now)

        #expect(
            manager.reconcile(
                displays: [first, second],
                preferences: LocalDisplayPreferences(),
                environment: .init(),
                now: now.addingTimeInterval(1)
            ) == [
                .deactivate(displayID: first.id, reason: .featureDisabled),
                .deactivate(displayID: second.id, reason: .featureDisabled),
            ])
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func batteryTransitionHonorsPolicyAndOverride() {
        var manager = LocalDisplaySessionManager()
        let xdr = display("xdr", potential: 4, current: 2)
        var preferences = enabledPreferences()
        preferences.allowsBoostOnBattery = false
        _ = manager.enable(display: xdr, preferences: preferences, environment: .init(powerSource: .ac), now: now)
        #expect(
            manager.reconcile(
                displays: [xdr],
                preferences: preferences,
                environment: .init(powerSource: .battery),
                now: now.addingTimeInterval(1)
            ) == [.deactivate(displayID: xdr.id, reason: .batteryPolicy)])

        preferences.allowsBoostOnBattery = true
        #expect(
            !(manager.enable(
                display: xdr,
                preferences: preferences,
                environment: .init(powerSource: .battery),
                now: now
            ).isEmpty))
    }

    @Test func defaultsAllowBatteryBoostAndSleepRestoration() {
        let defaults = LocalDisplayPreferences()
        #expect(defaults.allowsBoostOnBattery)
        #expect(defaults.restoresAfterSleep)
        #expect(defaults.timeoutMinutes == 30)
        #expect(!(defaults.showsControls))
    }

    @Test func versionOnePreferencesMigrateToNewSafetyDefaults() {
        let versionOne = Data(
            #"{"version":1,"showsControls":true,"timeoutMinutes":60,"allowsBoostOnBattery":false,"restoresAfterSleep":false,"preferredBoostByDisplay":{"xdr":1.5}}"#
                .utf8
        )
        let migrated = LocalDisplayPreferences.decodePersisted(versionOne)
        #expect(migrated.showsControls)
        #expect(migrated.timeoutMinutes == 60)
        #expect(migrated.allowsBoostOnBattery)
        #expect(migrated.restoresAfterSleep)
        #expect(migrated.preferredBoostByDisplay[LocalDisplayID(rawValue: "xdr")] == 1.5)

        let versionTwoExplicit = Data(
            #"{"version":2,"showsControls":true,"timeoutMinutes":30,"allowsBoostOnBattery":false,"restoresAfterSleep":false,"preferredBoostByDisplay":{}}"#
                .utf8
        )
        let decoded = LocalDisplayPreferences.decodePersisted(versionTwoExplicit)
        #expect(!(decoded.allowsBoostOnBattery))
        #expect(!(decoded.restoresAfterSleep))
    }

    @Test func seriousAndCriticalThermalStatesTurnBoostOff() {
        for thermalState in [LocalDisplayThermalState.serious, .critical] {
            var manager = LocalDisplaySessionManager()
            let xdr = display("xdr-\(thermalState.rawValue)", potential: 4, current: 2)
            let preferences = enabledPreferences()
            _ = manager.enable(display: xdr, preferences: preferences, environment: .init(), now: now)
            #expect(
                manager.reconcile(
                    displays: [xdr],
                    preferences: preferences,
                    environment: .init(thermalState: thermalState),
                    now: now.addingTimeInterval(1)
                ) == [.deactivate(displayID: xdr.id, reason: .thermalProtection)])
        }
    }

    @Test func sleepRestorationKeepsOriginalDeadlineAndPolicy() {
        var manager = LocalDisplaySessionManager()
        let xdr = display("xdr", potential: 4, current: 2)
        var preferences = enabledPreferences(timeoutMinutes: 30)
        preferences.restoresAfterSleep = true
        _ = manager.enable(display: xdr, preferences: preferences, environment: .init(), now: now)
        #expect(
            manager.suspend(preferences: preferences, reason: .sleep, now: now.addingTimeInterval(60)) == [
                .deactivate(displayID: xdr.id, reason: .sleep)
            ])
        #expect(manager.suspend(preferences: preferences, reason: .sleep, now: now.addingTimeInterval(61)).isEmpty)
        #expect(
            manager.resume(
                displays: [xdr],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(120)
            ) == [.activate(displayID: xdr.id, multiplier: 1.35)])
        #expect(manager.activeSessions[xdr.id]?.expiresAt == now.addingTimeInterval(1_800))
    }

    @Test func lidCloseRemovalSuspendsAndReopenRevivesWithOriginalDeadline() throws {
        var manager = LocalDisplaySessionManager()
        let builtIn = display("built-in", potential: 16, current: 2)
        var preferences = enabledPreferences(timeoutMinutes: 30)
        preferences.setPreferredBoost(1.5, for: builtIn)
        _ = manager.enable(display: builtIn, preferences: preferences, environment: .init(), now: now)

        #expect(
            manager.reconcile(
                displays: [], preferences: preferences, environment: .init(), now: now.addingTimeInterval(60)) == [
                    .deactivate(displayID: builtIn.id, reason: .displayRemoved)
                ])
        #expect(manager.activeSessions.isEmpty)

        #expect(
            manager.reconcile(
                displays: [builtIn], preferences: preferences, environment: .init(),
                now: now.addingTimeInterval(120)) == [.activate(displayID: builtIn.id, multiplier: 1.5)])
        let revived = try #require(manager.activeSessions[builtIn.id])
        #expect(revived.startedAt == now)
        #expect(revived.expiresAt == now.addingTimeInterval(1_800))
    }

    @Test func reopenAfterTheOriginalDeadlineDoesNotRevive() {
        var manager = LocalDisplaySessionManager()
        let builtIn = display("built-in", potential: 16, current: 2)
        let preferences = enabledPreferences(timeoutMinutes: 30)
        _ = manager.enable(display: builtIn, preferences: preferences, environment: .init(), now: now)
        _ = manager.reconcile(
            displays: [], preferences: preferences, environment: .init(), now: now.addingTimeInterval(60))

        #expect(
            manager.reconcile(
                displays: [builtIn], preferences: preferences, environment: .init(),
                now: now.addingTimeInterval(2_000)
            ).isEmpty)
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func removalWithRestorationDisabledCancelsOutright() {
        var manager = LocalDisplaySessionManager()
        let builtIn = display("built-in", potential: 16, current: 2)
        var preferences = enabledPreferences()
        preferences.restoresAfterSleep = false
        _ = manager.enable(display: builtIn, preferences: preferences, environment: .init(), now: now)
        _ = manager.reconcile(
            displays: [], preferences: preferences, environment: .init(), now: now.addingTimeInterval(60))

        #expect(
            manager.reconcile(
                displays: [builtIn], preferences: preferences, environment: .init(),
                now: now.addingTimeInterval(120)
            ).isEmpty)
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func revivalBlockedByPolicyConsumesTheSuspension() {
        var manager = LocalDisplaySessionManager()
        let builtIn = display("built-in", potential: 16, current: 2)
        var preferences = enabledPreferences()
        preferences.allowsBoostOnBattery = false
        _ = manager.enable(
            display: builtIn, preferences: preferences, environment: .init(powerSource: .ac), now: now)
        _ = manager.reconcile(
            displays: [], preferences: preferences, environment: .init(powerSource: .ac),
            now: now.addingTimeInterval(60))

        #expect(
            manager.reconcile(
                displays: [builtIn], preferences: preferences, environment: .init(powerSource: .battery),
                now: now.addingTimeInterval(120)
            ).isEmpty)
        #expect(manager.lastStopReasons[builtIn.id] == .batteryPolicy)

        #expect(
            manager.reconcile(
                displays: [builtIn], preferences: preferences, environment: .init(powerSource: .ac),
                now: now.addingTimeInterval(180)
            ).isEmpty)
    }

    @Test func displayRemovalCleansUpOnlyItsOverlay() {
        var manager = LocalDisplaySessionManager()
        let removed = display("removed", potential: 4, current: 2)
        let remaining = display("remaining", potential: 4, current: 2)
        let preferences = enabledPreferences()
        _ = manager.enable(display: removed, preferences: preferences, environment: .init(), now: now)
        _ = manager.enable(display: remaining, preferences: preferences, environment: .init(), now: now)

        #expect(
            manager.reconcile(
                displays: [remaining],
                preferences: preferences,
                environment: .init(),
                now: now.addingTimeInterval(1)
            ) == [.deactivate(displayID: removed.id, reason: .displayRemoved)])
        #expect(manager.activeSessions[remaining.id] != nil)
    }

    @Test func malformedAndObsoletePreferencesRecoverSafely() throws {
        #expect(LocalDisplayPreferences.decodePersisted(Data("not json".utf8)) == LocalDisplayPreferences())
        let obsolete = Data(#"{"version":99,"showsControls":true}"#.utf8)
        #expect(LocalDisplayPreferences.decodePersisted(obsolete) == LocalDisplayPreferences())

        let encoded = Data(
            #"{"version":1,"showsControls":true,"timeoutMinutes":999,"allowsBoostOnBattery":false,"restoresAfterSleep":false,"preferredBoostByDisplay":{"xdr":99}}"#
                .utf8
        )
        let decoded = LocalDisplayPreferences.decodePersisted(encoded)
        #expect(decoded.timeoutMinutes == 120)
        #expect(decoded.preferredBoostByDisplay[LocalDisplayID(rawValue: "xdr")] == 2)
    }

    @Test func levelControlActivatesAboveMinimumAndDeactivatesAtMinimum() throws {
        var manager = LocalDisplaySessionManager()
        let xdr = display("xdr", potential: 4, current: 2)
        let preferences = enabledPreferences()

        #expect(manager.setLevel(1.0, for: xdr, preferences: preferences, environment: .init(), now: now) == [])
        #expect(manager.activeSessions.isEmpty)

        #expect(
            manager.setLevel(1.4, for: xdr, preferences: preferences, environment: .init(), now: now) == [
                .activate(displayID: xdr.id, multiplier: 1.4)
            ])
        #expect(manager.activeSessions[xdr.id]?.requestedMultiplier == 1.4)

        #expect(
            manager.setLevel(1.8, for: xdr, preferences: preferences, environment: .init(), now: now) == [
                .update(displayID: xdr.id, multiplier: 1.8)
            ])

        #expect(
            manager.setLevel(1.0, for: xdr, preferences: preferences, environment: .init(), now: now) == [
                .deactivate(displayID: xdr.id, reason: .user)
            ])
        #expect(manager.activeSessions.isEmpty)
    }

    @Test func levelControlRespectsUnavailableStates() {
        var manager = LocalDisplaySessionManager()
        let xdr = display("xdr", potential: 4, current: 2)
        var preferences = enabledPreferences()
        preferences.allowsBoostOnBattery = false

        #expect(
            manager.setLevel(
                1.4,
                for: xdr,
                preferences: preferences,
                environment: .init(powerSource: .battery),
                now: now
            ) == [])
        #expect(manager.activeSessions.isEmpty)
        #expect(manager.lastStopReasons[xdr.id] == .batteryPolicy)
    }

    private func display(
        _ id: String,
        potential: Double,
        current: Double = 1
    ) -> LocalDisplayDescriptor {
        LocalDisplayDescriptor(
            id: LocalDisplayID(rawValue: id),
            name: id,
            isBuiltIn: id != "external",
            potentialEDRMultiplier: potential,
            currentEDRMultiplier: current
        )
    }

    private func enabledPreferences(timeoutMinutes: Int = 30) -> LocalDisplayPreferences {
        LocalDisplayPreferences(showsControls: true, timeoutMinutes: timeoutMinutes)
    }
}
