import Foundation
import Testing
@testable import MachinePulseCore

struct LocalMacMetricSourceTests {
    @Test func collectsThisMac() async throws {
        let source = LocalMacMetricSource(deviceID: "this-mac")
        _ = try await source.collect()
        try await Task.sleep(for: .milliseconds(50))
        let sample = try await source.collect()

        #expect(sample.memoryTotalBytes > 0)
        #expect(sample.diskTotalBytes > 0)
        #expect(sample.logicalCPUCount > 0)
        #expect((0...100).contains(sample.cpuPercent))
        #expect(sample.collectorVersion == "mac-native-v1")
        #expect(sample.rootFilesystemID != nil)
    }

    @Test func processLineParsingSurvivesMultiWordNames() throws {
        let metric = try #require(
            LocalMacMetricSource.processMetric(
                fromNumericFirstPSLine: "  0.4 11272 /Applications/Firefox.app/Contents/MacOS/Web Content"
            ))
        #expect(metric.name == "Web Content")
        #expect(metric.cpuPercent == 0.4)
        #expect(metric.residentBytes == 11272 * 1024)
        for line: Substring in [
            "garbage 11272 name", "0.4 not-a-number name", "0.4 11272", "nan 11272 name", "inf 11272 name",
        ] {
            #expect(LocalMacMetricSource.processMetric(fromNumericFirstPSLine: line) == nil)
        }
    }
}
