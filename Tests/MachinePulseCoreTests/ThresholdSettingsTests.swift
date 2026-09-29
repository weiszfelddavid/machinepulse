import Foundation
import Testing
@testable import MachinePulseCore

struct ThresholdSettingsTests {
    @Test func presetsSatisfyTheOrderingInvariants() {
        for thresholds in [HealthThresholds.quiet, .balanced, .sensitive] {
            assertValid(thresholds)
        }
    }

    @Test func customEditIsRepresentedAsCustomAndMaintainsInvariants() {
        var settings = HealthThresholdSettings(preset: .balanced)
        settings.update(\.cpuWarningPercent, value: 100)
        #expect(settings.preset == .custom)
        assertValid(settings.thresholds)
        #expect(settings.thresholds.cpuWarningPercent == 99)
        #expect(settings.thresholds.cpuCriticalPercent == 100)
    }

    @Test func malformedPersistedSettingsRecoverToSafeBounds() throws {
        let payload = """
            {
              "preset": "balanced",
              "thresholds": {
                "cpuWarningPercent": 200,
                "cpuCriticalPercent": -3,
                "memoryWarningFraction": 4,
                "memoryCriticalFraction": -1,
                "swapWarningFraction": 8,
                "diskWarningFraction": 2,
                "diskCriticalFraction": 0,
                "pressureWarningAverage10": 200,
                "pressureCriticalAverage10": -2
              }
            }
            """
        let settings = try JSONDecoder().decode(HealthThresholdSettings.self, from: Data(payload.utf8))
        #expect(settings.preset == .custom)
        assertValid(settings.thresholds)
    }

    @Test func restoreBalancedIsExact() {
        var settings = HealthThresholdSettings(preset: .custom, thresholds: .sensitive)
        settings.select(.balanced)
        #expect(settings.preset == .balanced)
        #expect(settings.thresholds == .balanced)
    }

    private func assertValid(_ value: HealthThresholds) {
        #expect((1...100).contains(value.cpuWarningPercent))
        #expect(value.cpuWarningPercent < value.cpuCriticalPercent)
        #expect((0...1).contains(value.memoryWarningFraction))
        #expect(value.memoryWarningFraction < value.memoryCriticalFraction)
        #expect((0...1).contains(value.diskWarningFraction))
        #expect(value.diskWarningFraction < value.diskCriticalFraction)
        #expect(value.pressureWarningAverage10 < value.pressureCriticalAverage10)
    }
}
