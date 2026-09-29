import Foundation
import Testing
@testable import MachinePulseCore

struct DiskGrowthAnalyzerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let total: UInt64 = 100_000_000_000

    @Test func classifiesStableGrowthAndShrinkage() throws {
        let stable = try #require(DiskGrowthAnalyzer.analyze(samples: samples(usedGigabytes: [50, 50, 50, 50])))
        #expect(stable.state == .stable)

        let growing = try #require(DiskGrowthAnalyzer.analyze(samples: samples(usedGigabytes: [50, 51, 52, 53])))
        #expect(growing.state == .growing)
        #expect(growing.changeBytes > 0)

        let shrinking = try #require(DiskGrowthAnalyzer.analyze(samples: samples(usedGigabytes: [53, 52, 51, 50])))
        #expect(shrinking.state == .shrinking)
        #expect(shrinking.changeBytes < 0)
    }

    @Test func distinguishesATemporarySpikeFromSustainedGrowth() throws {
        let trend = try #require(DiskGrowthAnalyzer.analyze(samples: samples(usedGigabytes: [50, 50, 55, 50, 50])))
        #expect(trend.state == .temporarySpike)
        #expect(trend.peakAboveBaselineBytes > 4_000_000_000)
    }

    @Test func sparseHistoryDoesNotPretendToHaveATrend() {
        #expect(DiskGrowthAnalyzer.analyze(samples: samples(usedGigabytes: [50, 51])) == nil)
    }

    @Test func aLargeSamplingGapStartsANewTrendWindow() {
        let values = [
            sample(minutes: 0, usedGigabytes: 50),
            sample(minutes: 5, usedGigabytes: 51),
            sample(minutes: 10, usedGigabytes: 52),
            sample(minutes: 90, usedGigabytes: 53),
            sample(minutes: 95, usedGigabytes: 54),
        ]
        #expect(DiskGrowthAnalyzer.analyze(samples: values) == nil)
    }

    @Test func aVolumeSizeChangeDoesNotBecomeFakeGrowth() {
        let values = [
            sample(minutes: 0, usedGigabytes: 50),
            sample(minutes: 5, usedGigabytes: 51),
            sample(minutes: 10, usedGigabytes: 52),
            sample(minutes: 15, usedGigabytes: 60, totalBytes: 200_000_000_000),
            sample(minutes: 20, usedGigabytes: 61, totalBytes: 200_000_000_000),
        ]
        #expect(DiskGrowthAnalyzer.analyze(samples: values) == nil)
    }

    private func samples(usedGigabytes: [UInt64]) -> [MetricSample] {
        usedGigabytes.enumerated().map { index, used in
            sample(minutes: index * 5, usedGigabytes: used)
        }
    }

    private func sample(
        minutes: Int,
        usedGigabytes: UInt64,
        totalBytes: UInt64? = nil
    ) -> MetricSample {
        MetricSample(
            deviceID: "vps",
            timestamp: start.addingTimeInterval(TimeInterval(minutes * 60)),
            hostname: "vps",
            uptimeSeconds: 1_000,
            cpuPercent: 10,
            logicalCPUCount: 2,
            loadAverage1: 0,
            loadAverage5: 0,
            loadAverage15: 0,
            memoryTotalBytes: 4_000_000_000,
            memoryAvailableBytes: 2_000_000_000,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            diskTotalBytes: totalBytes ?? total,
            diskUsedBytes: usedGigabytes * 1_000_000_000
        )
    }
}
