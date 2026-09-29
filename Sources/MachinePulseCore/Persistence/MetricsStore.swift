import Foundation
import SQLite3

public enum MetricsStoreError: LocalizedError, Sendable {
    case open(String)
    case statement(String)

    public var errorDescription: String? {
        switch self {
        case let .open(message): "Could not open the MachinePulse database: \(message)"
        case let .statement(message): "MachinePulse database error: \(message)"
        }
    }
}

public actor MetricsStore {
    public static let sampleRetentionDays = 1
    public static let incidentRetentionDays = 30
    public static let capacityRollupRetentionDays = 90
    public static let capacityRollupPayloadBudgetBytes = 64 * 1_024 * 1_024
    public static let sampleRetention = TimeInterval(sampleRetentionDays * 24 * 60 * 60)
    public static let incidentRetention = TimeInterval(incidentRetentionDays * 24 * 60 * 60)
    public static let capacityRollupRetention = TimeInterval(capacityRollupRetentionDays * 24 * 60 * 60)

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MachinePulse", isDirectory: true)
            .appendingPathComponent("machinepulse.sqlite3")
    }

    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rollupPayloadBudgetBytes: Int

    public init(
        url: URL = MetricsStore.defaultURL,
        rollupPayloadBudgetBytes: Int = MetricsStore.capacityRollupPayloadBudgetBytes
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw MetricsStoreError.open(message)
        }
        connection = SQLiteConnection(handle: handle)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.rollupPayloadBudgetBytes = max(1, rollupPayloadBudgetBytes)

        func initialize(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                throw MetricsStoreError.statement(message)
            }
        }
        try initialize("PRAGMA journal_mode=WAL;")
        try initialize("PRAGMA synchronous=NORMAL;")
        try initialize(
            """
            CREATE TABLE IF NOT EXISTS metric_samples (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS metric_samples_device_time
                ON metric_samples(device_id, timestamp DESC);
            CREATE TABLE IF NOT EXISTS health_incidents (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                issue_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                ended_at REAL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS health_incidents_device_time
                ON health_incidents(device_id, updated_at DESC);
            CREATE INDEX IF NOT EXISTS health_incidents_active_issue
                ON health_incidents(device_id, issue_id, ended_at);
            CREATE TABLE IF NOT EXISTS capacity_hourly_rollups (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                hour_start REAL NOT NULL,
                observed_through REAL NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS capacity_rollups_device_time
                ON capacity_hourly_rollups(device_id, hour_start ASC, id ASC);
            CREATE INDEX IF NOT EXISTS capacity_rollups_oldest
                ON capacity_hourly_rollups(observed_through ASC);
            CREATE TABLE IF NOT EXISTS schema_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS disk_scans (
                device_id TEXT PRIMARY KEY,
                scanned_at REAL NOT NULL,
                payload BLOB NOT NULL
            );
            """)
    }

    public func save(_ sample: MetricSample) throws {
        try insert(
            sql: "INSERT OR REPLACE INTO metric_samples(id, device_id, timestamp, payload) VALUES(?, ?, ?, ?);",
            id: sample.id.uuidString,
            deviceID: sample.deviceID,
            timestamp: sample.timestamp,
            payload: encoder.encode(sample)
        )
    }

    /// Replaces one machine's rollups for one hour. The caller builds them
    /// from the samples it already holds, so a save never re-reads the hour.
    public func replaceCapacityRollups(deviceID: String, hourStart: Date, with rollups: [CapacityHourlyRollup])
        throws
    {
        try transaction {
            let delete = try prepare("DELETE FROM capacity_hourly_rollups WHERE device_id = ? AND hour_start = ?;")
            defer { sqlite3_finalize(delete) }
            bind(deviceID, at: 1, in: delete)
            sqlite3_bind_double(delete, 2, hourStart.timeIntervalSince1970)
            try step(delete)
            for rollup in rollups { try insertCapacityRollup(rollup) }
        }
        try enforceCapacityBudget()
    }

    public func save(_ incident: HealthIncident) throws {
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO health_incidents(
                id, device_id, issue_id, started_at, updated_at, ended_at, payload
            ) VALUES(?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        bind(incident.id.uuidString, at: 1, in: statement)
        bind(incident.deviceID, at: 2, in: statement)
        bind(incident.issueID, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, incident.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, incident.updatedAt.timeIntervalSince1970)
        if let endedAt = incident.endedAt {
            sqlite3_bind_double(statement, 6, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        bind(try encoder.encode(incident), at: 7, in: statement)
        try step(statement)
    }

    /// One scan per machine: the latest replaces the previous one.
    public func save(_ scan: DiskScan) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO disk_scans(device_id, scanned_at, payload) VALUES(?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        bind(scan.deviceID, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, scan.scannedAt.timeIntervalSince1970)
        bind(try encoder.encode(scan), at: 3, in: statement)
        try step(statement)
    }

    public func latestDiskScans() throws -> [DiskScan] {
        try queryAllPayloads(sql: "SELECT payload FROM disk_scans ORDER BY scanned_at DESC;", type: DiskScan.self)
    }

    public func recentSamples(deviceID: String, since: Date, limit: Int = 1_000) throws -> [MetricSample] {
        let samples: [MetricSample] = try queryPayloads(
            sql:
                "SELECT payload FROM metric_samples WHERE device_id = ? AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?;",
            deviceID: deviceID,
            since: since,
            limit: limit,
            type: MetricSample.self
        )
        return samples.reversed()
    }

    public func recentIncidents(deviceID: String, since: Date, limit: Int = 500) throws -> [HealthIncident] {
        try queryPayloads(
            sql:
                "SELECT payload FROM health_incidents WHERE device_id = ? AND updated_at >= ? ORDER BY updated_at DESC LIMIT ?;",
            deviceID: deviceID,
            since: since,
            limit: limit,
            type: HealthIncident.self
        )
    }

    public func recentCapacityRollups(
        deviceID: String,
        since: Date,
        limit: Int = 10_000
    ) throws -> [CapacityHourlyRollup] {
        try queryPayloads(
            sql:
                "SELECT payload FROM capacity_hourly_rollups WHERE device_id = ? AND observed_through >= ? ORDER BY hour_start ASC, id ASC LIMIT ?;",
            deviceID: deviceID,
            since: since,
            limit: limit,
            type: CapacityHourlyRollup.self
        )
    }

    /// Additively derives compact history from every retained legacy sample.
    /// The marker is written in the same transaction as the replacement rows,
    /// so an interrupted migration is safe to retry.
    public func backfillCapacityRollupsIfNeeded() throws {
        let migrationKey = "capacity-hourly-rollups-v1"
        guard try metadataValue(for: migrationKey) == nil else { return }
        let samples: [MetricSample] = try queryAllPayloads(
            sql: "SELECT payload FROM metric_samples ORDER BY device_id ASC, timestamp ASC, id ASC;",
            type: MetricSample.self
        )
        let rollups = CapacityRollupBuilder.build(samples: samples)
        try transaction {
            try execute("DELETE FROM capacity_hourly_rollups;")
            for rollup in rollups { try insertCapacityRollup(rollup) }
            try setMetadataValue("complete", for: migrationKey)
        }
        try enforceCapacityBudget()
    }

    public func capacityRollupStorage() throws -> (rowCount: Int, payloadBytes: Int) {
        let statement = try prepare(
            "SELECT COUNT(*), COALESCE(SUM(length(payload)), 0) FROM capacity_hourly_rollups;"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    public func prune(now: Date = Date()) throws {
        try deleteOlderThan(
            table: "metric_samples",
            timestamp: now.addingTimeInterval(-Self.sampleRetention)
        )
        try deleteOlderThan(
            table: "health_incidents",
            column: "updated_at",
            timestamp: now.addingTimeInterval(-Self.incidentRetention)
        )
        try deleteOlderThan(
            table: "capacity_hourly_rollups",
            column: "observed_through",
            timestamp: now.addingTimeInterval(-Self.capacityRollupRetention)
        )
        try enforceCapacityBudget()
        try reclaimFreePagesIfWorthwhile()
        try execute("PRAGMA wal_checkpoint(PASSIVE);")
    }

    /// Deleted rows leave free pages that new rows reuse, so the file only
    /// shrinks when a quarter of it is free and that quarter is worth the
    /// rewrite.
    static func shouldReclaimFreePages(pageSize: Int64, pageCount: Int64, freePages: Int64) -> Bool {
        freePages * 4 > pageCount && freePages * pageSize >= 64 * 1_024 * 1_024
    }

    private func reclaimFreePagesIfWorthwhile() throws {
        let worthwhile = Self.shouldReclaimFreePages(
            pageSize: try scalar("PRAGMA page_size;"),
            pageCount: try scalar("PRAGMA page_count;"),
            freePages: try scalar("PRAGMA freelist_count;")
        )
        if worthwhile { try execute("VACUUM;") }
    }

    private func insertCapacityRollup(_ rollup: CapacityHourlyRollup) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO capacity_hourly_rollups(id, device_id, hour_start, observed_through, payload) VALUES(?, ?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        bind(rollup.id, at: 1, in: statement)
        bind(rollup.deviceID, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, rollup.hourStart.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, rollup.observedThrough.timeIntervalSince1970)
        bind(try encoder.encode(rollup), at: 5, in: statement)
        try step(statement)
    }

    private func enforceCapacityBudget() throws {
        let storage = try capacityRollupStorage()
        guard storage.payloadBytes > rollupPayloadBudgetBytes else { return }
        let statement = try prepare(
            "SELECT id, length(payload) FROM capacity_hourly_rollups ORDER BY observed_through ASC, id ASC;"
        )
        var remaining = storage.payloadBytes
        var ids: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW, remaining > rollupPayloadBudgetBytes {
            if let rawID = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: rawID))
                remaining -= Int(sqlite3_column_int64(statement, 1))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw lastError()
        }
        sqlite3_finalize(statement)
        guard !ids.isEmpty else { return }
        try transaction {
            let delete = try prepare("DELETE FROM capacity_hourly_rollups WHERE id = ?;")
            defer { sqlite3_finalize(delete) }
            for id in ids {
                sqlite3_reset(delete)
                sqlite3_clear_bindings(delete)
                bind(id, at: 1, in: delete)
                try step(delete)
            }
        }
    }

    private func insert(
        sql: String,
        id: String,
        deviceID: String,
        timestamp: Date,
        payload: Data
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(id, at: 1, in: statement)
        bind(deviceID, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, timestamp.timeIntervalSince1970)
        bind(payload, at: 4, in: statement)
        try step(statement)
    }

    private func queryPayloads<Value: Decodable>(
        sql: String,
        deviceID: String,
        since: Date,
        limit: Int,
        type: Value.Type
    ) throws -> [Value] {
        let statement = try prepare(sql)
        bind(deviceID, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(limit))
        return try payloads(statement, as: type)
    }

    private func queryAllPayloads<Value: Decodable>(sql: String, type: Value.Type) throws -> [Value] {
        try payloads(try prepare(sql), as: type)
    }

    /// Steps a prepared payload query to the end and finalizes it.
    private func payloads<Value: Decodable>(_ statement: OpaquePointer, as type: Value.Type) throws -> [Value] {
        defer { sqlite3_finalize(statement) }
        var values: [Value] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                let count = Int(sqlite3_column_bytes(statement, 0))
                values.append(try decoder.decode(type, from: Data(bytes: bytes, count: count)))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return values
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM schema_metadata WHERE key = ?;")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            return String(cString: value)
        }
        guard result == SQLITE_DONE else { throw lastError() }
        return nil
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO schema_metadata(key, value) VALUES(?, ?);")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try step(statement)
    }

    private func deleteOlderThan(table: String, column: String = "timestamp", timestamp: Date) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE \(column) < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
        try step(statement)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ payload: Data, at index: Int32, in statement: OpaquePointer) {
        payload.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private func lastError() -> MetricsStoreError {
        .statement(String(cString: sqlite3_errmsg(database)))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}
