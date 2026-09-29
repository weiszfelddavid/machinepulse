import Foundation

/// What a directory holds, for colour.
public enum DiskKind: String, Codable, CaseIterable, Hashable, Sendable {
    case code
    case agentScratch
    case toolchain
    case synced
    case git
    case media
    case documents
    case cache
    case other

    /// The kinds the legend lists, in its order.
    public static let legend: [DiskKind] = [
        .code, .agentScratch, .toolchain, .synced, .git, .media, .documents, .cache,
    ]

    public var label: String {
        switch self {
        case .code: "Code"
        case .agentScratch: "Agent scratch"
        case .toolchain: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

/// Why a directory's space can be had back.
public enum DiskReclaimReason: String, Codable, Hashable, Sendable {
    case regenerable
    case syncHistory
    case packageStore
    case buildOutput
    case reinstallable
    case sandboxLayers
    case snapshots
    case trash
    case temporary

    public var label: String {
        switch self {
        case .regenerable: "regenerable"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .sandboxLayers: "sandbox layers"
        case .snapshots: "snapshots"
        case .trash: "trash"
        case .temporary: "temporary"
        }
    }
}

public enum DiskEntryKind: String, Codable, Hashable, Sendable {
    case directory
    case file
    case symlink
    case other
}

/// One retained entry of a scan. Sizes are what the filesystem allocated, the
/// number that comes back when the entry is deleted. A directory's totals
/// cover everything beneath it, including entries that were not retained;
/// `remainderBytes` and `remainderCount` say how much of it the retained
/// children do not show.
public struct DiskNode: Codable, Hashable, Sendable {
    public var name: String
    public var entryKind: DiskEntryKind
    public var bytes: UInt64
    public var files: UInt64
    public var directories: UInt64
    public var modifiedAt: Date?
    public var readError: Bool
    public var kind: DiskKind
    public var reclaim: DiskReclaimReason?
    public var children: [DiskNode]
    public var remainderBytes: UInt64
    public var remainderCount: UInt64

    public init(
        name: String,
        entryKind: DiskEntryKind,
        bytes: UInt64,
        files: UInt64 = 0,
        directories: UInt64 = 0,
        modifiedAt: Date? = nil,
        readError: Bool = false,
        kind: DiskKind = .other,
        reclaim: DiskReclaimReason? = nil,
        children: [DiskNode] = [],
        remainderBytes: UInt64 = 0,
        remainderCount: UInt64 = 0
    ) {
        self.name = name
        self.entryKind = entryKind
        self.bytes = bytes
        self.files = files
        self.directories = directories
        self.modifiedAt = modifiedAt
        self.readError = readError
        self.kind = kind
        self.reclaim = reclaim
        self.children = children
        self.remainderBytes = remainderBytes
        self.remainderCount = remainderCount
    }

    public var isDirectory: Bool { entryKind == .directory }

    /// Bytes under the top-most hatched tiles: a reclaimable directory counts
    /// once, however deep the mark is inherited below it.
    public var reclaimableBytes: UInt64 {
        reclaim != nil ? bytes : children.reduce(0) { $0 &+ $1.reclaimableBytes }
    }

    public func resolve(_ crumbs: [Int]) -> DiskNode? {
        var node = self
        for index in crumbs {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    public func child(named name: String) -> DiskNode? {
        children.first { $0.name == name }
    }
}

public struct DiskVolume: Codable, Hashable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
}

public enum DiskFindingKind: String, Codable, Hashable, Sendable {
    case reclaimable
    case worktrees
    case staleExperiments
}

/// One line of "Worth a look": a directory a person can judge in a second.
/// Findings never nest, so their total is space that exists once.
public struct DiskFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    /// Relative to the scanned root, `/`-joined.
    public let path: String
    /// What clearing it frees. For stale experiments, only the stale ones.
    public let bytes: UInt64
    public let kind: DiskFindingKind
    public let reclaim: DiskReclaimReason?
    public let count: Int?
    public let oldestDays: Int?

    public init(
        path: String,
        bytes: UInt64,
        kind: DiskFindingKind,
        reclaim: DiskReclaimReason? = nil,
        count: Int? = nil,
        oldestDays: Int? = nil
    ) {
        self.path = path
        self.bytes = bytes
        self.kind = kind
        self.reclaim = reclaim
        self.count = count
        self.oldestDays = oldestDays
    }

    public var explanation: String {
        switch kind {
        case .reclaimable:
            return reclaim?.label ?? "reclaimable"
        case .worktrees:
            let count = count ?? 0
            let oldest = oldestDays ?? 0
            return "\(count) worktree\(count == 1 ? "" : "s") · oldest \(oldest) day\(oldest == 1 ? "" : "s")"
        case .staleExperiments:
            let count = count ?? 0
            return "\(count) experiment\(count == 1 ? "" : "s") untouched for 30 days"
        }
    }
}

public struct DiskScan: Codable, Hashable, Sendable {
    public let deviceID: String
    public let scannedAt: Date
    public let rootPath: String
    public let durationSeconds: Double
    public let unreadableCount: UInt64
    public let fullDiskAccess: Bool?
    public let volume: DiskVolume?
    public let root: DiskNode
    public let findings: [DiskFinding]
    public let scannerVersion: String

    public init(
        deviceID: String,
        scannedAt: Date,
        rootPath: String,
        durationSeconds: Double,
        unreadableCount: UInt64,
        fullDiskAccess: Bool? = nil,
        volume: DiskVolume?,
        root: DiskNode,
        findings: [DiskFinding],
        scannerVersion: String
    ) {
        self.deviceID = deviceID
        self.scannedAt = scannedAt
        self.rootPath = rootPath
        self.durationSeconds = durationSeconds
        self.unreadableCount = unreadableCount
        self.fullDiskAccess = fullDiskAccess
        self.volume = volume
        self.root = root
        self.findings = findings
        self.scannerVersion = scannerVersion
    }

    public var totalBytes: UInt64 { root.bytes }
    public var fileCount: UInt64 { root.files }
    public var directoryCount: UInt64 { root.directories }
    public var worthALookBytes: UInt64 { findings.reduce(0) { $0 &+ $1.bytes } }
    public var reclaimableBytes: UInt64 { root.reclaimableBytes }
}

/// The shape of a snapshot a remote collector returns; the app adds the
/// device identity and the time it received it.
public struct DiskScanSnapshot: Codable, Sendable {
    public let rootPath: String
    public let durationSeconds: Double
    public let unreadableCount: UInt64
    public let volume: DiskVolume?
    public let root: DiskNode
    public let findings: [DiskFinding]
    public let scannerVersion: String

    public init(
        rootPath: String,
        durationSeconds: Double,
        unreadableCount: UInt64,
        volume: DiskVolume?,
        root: DiskNode,
        findings: [DiskFinding],
        scannerVersion: String
    ) {
        self.rootPath = rootPath
        self.durationSeconds = durationSeconds
        self.unreadableCount = unreadableCount
        self.volume = volume
        self.root = root
        self.findings = findings
        self.scannerVersion = scannerVersion
    }

    public func scan(deviceID: String, scannedAt: Date = Date()) -> DiskScan {
        DiskScan(
            deviceID: deviceID,
            scannedAt: scannedAt,
            rootPath: rootPath,
            durationSeconds: durationSeconds,
            unreadableCount: unreadableCount,
            volume: volume,
            root: root,
            findings: findings,
            scannerVersion: scannerVersion
        )
    }
}
