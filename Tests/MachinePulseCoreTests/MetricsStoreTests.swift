import Foundation
import SQLite3
import Testing
@testable import MachinePulseCore

struct MetricsStoreTests {
    @Test func returnsNewestSamplesInChronologicalOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try MetricsStore(url: directory.appendingPathComponent("test.sqlite3"))
        let now = Date()
        try await store.save(makeSample(cpuPercent: 10, timestamp: now.addingTimeInterval(-3)))
        try await store.save(makeSample(cpuPercent: 20, timestamp: now.addingTimeInterval(-2)))
        try await store.save(makeSample(cpuPercent: 30, timestamp: now.addingTimeInterval(-1)))

        let samples = try await store.recentSamples(
            deviceID: "local",
            since: now.addingTimeInterval(-60),
            limit: 2
        )
        #expect(samples.map(\.cpuPercent) == [20, 30])
    }

    @Test func prunesExpiredSamples() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try MetricsStore(url: directory.appendingPathComponent("test.sqlite3"))
        let now = Date()
        try await store.save(
            makeSample(
                cpuPercent: 10,
                timestamp: now.addingTimeInterval(-MetricsStore.sampleRetention - 1)
            ))
        try await store.save(makeSample(cpuPercent: 20, timestamp: now))
        try await store.prune(now: now)

        let samples = try await store.recentSamples(deviceID: "local", since: .distantPast)
        #expect(samples.map(\.cpuPercent) == [20])
    }

    @Test func storesAndPrunesDurableIncidents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MetricsStore(url: directory.appendingPathComponent("test.sqlite3"))
        let now = Date()
        let expired = HealthIncident(
            issue: storageIssue(),
            deviceID: "linux",
            at: now.addingTimeInterval(-MetricsStore.incidentRetention - 1)
        )
        let current = HealthIncident(issue: storageIssue(), deviceID: "linux", at: now)
        try await store.save(expired)
        try await store.save(current)
        try await store.prune(now: now)

        let incidents = try await store.recentIncidents(deviceID: "linux", since: .distantPast)
        #expect(incidents.map(\.id) == [current.id])
    }

    @Test func freePagesAreReclaimedOnlyWhenTheyAreAQuarterOfAFileWorthShrinking() {
        #expect(MetricsStore.shouldReclaimFreePages(pageSize: 4_096, pageCount: 1_000_000, freePages: 300_000))
        #expect(!MetricsStore.shouldReclaimFreePages(pageSize: 4_096, pageCount: 1_000_000, freePages: 200_000))
        #expect(!MetricsStore.shouldReclaimFreePages(pageSize: 4_096, pageCount: 20_000, freePages: 10_000))
    }

    @Test func anUndecodableRowFailsTheReadInsteadOfVanishing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite3")
        let store = try MetricsStore(url: url)
        try await store.save(makeSample(cpuPercent: 10, timestamp: Date()))

        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "UPDATE metric_samples SET payload = X'7B7D';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)

        await #expect(throws: DecodingError.self) {
            try await store.recentSamples(deviceID: "local", since: .distantPast)
        }
    }

    @Test func decodesIncidentPayloadFromBeforeObservationContext() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let incident = HealthIncident(issue: storageIssue(), deviceID: "linux", at: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var payload = try #require(JSONSerialization.jsonObject(with: encoder.encode(incident)) as? [String: Any])
        payload.removeValue(forKey: "observationContext")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode(
            HealthIncident.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(restored.observationContext == nil)
        #expect(restored.latestMeasurement == incident.peakMeasurement)
        #expect(restored.lastObservedAt == incident.updatedAt)
        #expect(!(restored.isClearing))
    }

    private func makeSample(cpuPercent: Double, timestamp: Date) -> MetricSample {
        MetricSample(
            deviceID: "local",
            timestamp: timestamp,
            hostname: "mac",
            uptimeSeconds: 100,
            cpuPercent: cpuPercent,
            logicalCPUCount: 8,
            loadAverage1: 1,
            loadAverage5: 1,
            loadAverage15: 1,
            memoryTotalBytes: 16_000,
            memoryAvailableBytes: 8_000,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            diskTotalBytes: 100_000,
            diskUsedBytes: 50_000
        )
    }

    private func storageIssue() -> HealthIssue {
        HealthIssue(
            id: "io-pressure",
            kind: .diskPressure,
            state: .warning,
            title: "Storage contention",
            explanation: "9.9% average stall time.",
            measurement: 9.9,
            threshold: 8
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
