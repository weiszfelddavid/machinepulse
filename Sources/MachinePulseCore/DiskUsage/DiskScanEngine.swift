import Foundation

public struct DiskScanOptions: Sendable {
    /// Entries smaller than this are aggregated into their directory but
    /// not retained as nodes of their own.
    public var retainFloorBytes: UInt64 = 4 * 1_024 * 1_024
    /// Smaller than this is not worth a line in "Worth a look".
    public var findingFloorBytes: UInt64 = 64 * 1_024 * 1_024
    /// Retained children per directory; the tail is merged into a remainder.
    public var maxChildren = 96
    /// Levels below the root that keep nodes; deeper entries only aggregate.
    public var maxDepth = 4
    public var maxFindings = 12
    /// An experiment untouched this long is worth a look.
    public var staleDays = 30
    public var now = Date()

    public init() {}
}

/// Builds the bounded tree and the findings of a scan from a pre-order
/// walk, one directory frame at a time, without ever holding the whole
/// filesystem in memory. The scanner reports each directory it enters, every
/// entry it meets, and each directory it leaves; the engine classifies
/// top-down, aggregates bottom-up, retains only the largest entries within
/// the depth bound, and judges findings when a directory closes.
public struct DiskScanEngine {
    private struct Frame {
        let level: Int
        let name: String
        let path: String
        var kind: DiskKind
        let reclaim: DiskReclaimReason?
        let recognised: Bool
        let flags: DiskClassifier.SiblingFlags
        var bytes: UInt64 = 0
        var files: UInt64 = 0
        var directories: UInt64 = 0
        var modified: Int64 = 0
        var readError = false
        var retained: [DiskNode] = []
        var childDirectories: [(name: String, bytes: UInt64, modified: Int64)] = []
        let findingsStart: Int
        let judgesChildren: Bool
    }

    public let options: DiskScanOptions
    private var frames: [Frame] = []
    private var findings: [DiskFinding] = []
    private var unreadable: UInt64 = 0
    private let staleSeconds: Int64
    private let nowSeconds: Int64

    public init(rootName: String, rootFlags: DiskClassifier.SiblingFlags, options: DiskScanOptions = DiskScanOptions())
    {
        self.options = options
        staleSeconds = Int64(options.staleDays) * 86_400
        nowSeconds = Int64(options.now.timeIntervalSince1970)
        frames = [
            Frame(
                level: 0, name: rootName, path: "", kind: .other, reclaim: nil, recognised: true,
                flags: rootFlags, findingsStart: 0, judgesChildren: false)
        ]
    }

    public var unreadableCount: UInt64 { unreadable }

    public mutating func enterDirectory(name: String, flags: DiskClassifier.SiblingFlags) {
        let parent = frames[frames.count - 1]
        let kind = DiskClassifier.kind(ofDirectory: name, ownFlags: flags, parent: parent.kind)
        let recognised = DiskClassifier.kind(ofName: name) != nil || flags.isGitStore
        let reclaim =
            parent.reclaim
            ?? DiskClassifier.reclaim(ofName: name, parent: parent.kind, siblings: parent.flags)
        let lowered = name.lowercased()
        frames.append(
            Frame(
                level: parent.level + 1,
                name: name,
                path: parent.path.isEmpty ? name : parent.path + "/" + name,
                kind: kind,
                reclaim: reclaim,
                recognised: recognised,
                flags: flags,
                findingsStart: findings.count,
                judgesChildren: kind == .agentScratch && reclaim == nil
                    && (lowered == "worktrees" || lowered == "tries" || lowered == "experiments")
            ))
    }

    /// The current directory could not be listed; it stays in the tree with
    /// unknown contents.
    public mutating func markUnreadable() {
        frames[frames.count - 1].readError = true
        unreadable += 1
    }

    public mutating func addEntry(name: String, entryKind: DiskEntryKind, bytes: UInt64, modified: Int64) {
        let index = frames.count - 1
        frames[index].bytes &+= bytes
        if entryKind != .other { frames[index].files &+= 1 }
        frames[index].modified = max(frames[index].modified, modified)
        guard frames[index].level < options.maxDepth, bytes >= options.retainFloorBytes else { return }
        frames[index].retained.append(
            DiskNode(
                name: name,
                entryKind: entryKind,
                bytes: bytes,
                files: entryKind == .other ? 0 : 1,
                modifiedAt: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                kind: frames[index].kind,
                reclaim: frames[index].reclaim
            ))
    }

    /// A directory that is deliberately not entered (a cloud-only folder)
    /// still appears as an empty directory.
    public mutating func addSkippedDirectory(bytes: UInt64, modified: Int64) {
        let index = frames.count - 1
        frames[index].bytes &+= bytes
        frames[index].directories &+= 1
        frames[index].modified = max(frames[index].modified, modified)
    }

    /// Closes the current directory: `ownBytes` and `ownModified` are the
    /// directory entry's own allocation and time stamp.
    public mutating func leaveDirectory(ownBytes: UInt64, ownModified: Int64) {
        var frame = frames.removeLast()
        frame.bytes &+= ownBytes
        frame.modified = max(frame.modified, ownModified)
        keepLargest(&frame.retained)

        if frame.level == 1, !frame.recognised, frame.kind == .other {
            let probe = DiskNode(name: frame.name, entryKind: .directory, bytes: frame.bytes, children: frame.retained)
            if let dominant = DiskClassifier.dominantChildKind(of: probe) {
                frame.kind = dominant
                for index in frame.retained.indices { Self.recolor(&frame.retained[index], from: .other, to: dominant) }
            }
        }

        judge(&frame)

        let node = DiskNode(
            name: frame.name,
            entryKind: .directory,
            bytes: frame.bytes,
            files: frame.files,
            directories: frame.directories,
            modifiedAt: frame.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(frame.modified)) : nil,
            readError: frame.readError,
            kind: frame.kind,
            reclaim: frame.reclaim,
            children: frame.retained
        )
        let index = frames.count - 1
        frames[index].bytes &+= frame.bytes
        frames[index].files &+= frame.files
        frames[index].directories &+= frame.directories &+ 1
        frames[index].modified = max(frames[index].modified, frame.modified)
        if frames[index].judgesChildren {
            frames[index].childDirectories.append((frame.name, frame.bytes, frame.modified))
        }
        if frame.level <= options.maxDepth, frame.bytes >= options.retainFloorBytes {
            frames[index].retained.append(node)
        }
    }

    /// Findings are judged when a directory closes, once its size is known.
    /// Topmost only: everything beneath a reclaimable directory goes with it,
    /// and a worktree directory or a stale experiment is judged whole.
    private mutating func judge(_ frame: inout Frame) {
        guard frame.bytes >= options.findingFloorBytes else { return }
        let parentReclaim = frames[frames.count - 1].reclaim
        if let reclaim = frame.reclaim {
            guard parentReclaim == nil else { return }
            findings.append(DiskFinding(path: frame.path, bytes: frame.bytes, kind: .reclaimable, reclaim: reclaim))
            return
        }
        guard frame.judgesChildren else { return }
        if frame.name.lowercased() == "worktrees" {
            guard !frame.childDirectories.isEmpty else { return }
            let oldest = frame.childDirectories.map(\.modified).filter { $0 > 0 }.min() ?? nowSeconds
            findings.removeSubrange(frame.findingsStart...)
            findings.append(
                DiskFinding(
                    path: frame.path, bytes: frame.bytes, kind: .worktrees,
                    count: frame.childDirectories.count,
                    oldestDays: Int(max(0, nowSeconds - oldest) / 86_400)))
            return
        }
        let stale = frame.childDirectories.filter { $0.modified > 0 && nowSeconds - $0.modified > staleSeconds }
        guard !stale.isEmpty else { return }
        let stalePrefixes = stale.map { frame.path + "/" + $0.name + "/" }
        findings.removeAll { finding in
            stalePrefixes.contains { prefix in finding.path.hasPrefix(prefix) }
        }
        let staleBytes = stale.reduce(0) { $0 &+ $1.bytes }
        guard staleBytes >= options.findingFloorBytes else { return }
        findings.append(DiskFinding(path: frame.path, bytes: staleBytes, kind: .staleExperiments, count: stale.count))
    }

    private func keepLargest(_ nodes: inout [DiskNode]) {
        nodes.sort { lhs, rhs in lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.name < rhs.name }
        if nodes.count > options.maxChildren { nodes.removeLast(nodes.count - options.maxChildren) }
    }

    private static func recolor(_ node: inout DiskNode, from old: DiskKind, to new: DiskKind) {
        guard node.kind == old else { return }
        node.kind = new
        for index in node.children.indices { recolor(&node.children[index], from: old, to: new) }
    }

    /// Closes the root and applies the final bounds: children below a share
    /// of the whole scan are merged into their directory's remainder.
    public mutating func finish(rootOwnBytes: UInt64, rootModified: Int64) -> (root: DiskNode, findings: [DiskFinding])
    {
        precondition(frames.count == 1, "every entered directory must be left before finishing")
        var frame = frames.removeLast()
        frame.bytes &+= rootOwnBytes
        frame.modified = max(frame.modified, rootModified)
        keepLargest(&frame.retained)
        var root = DiskNode(
            name: frame.name,
            entryKind: .directory,
            bytes: frame.bytes,
            files: frame.files,
            directories: frame.directories,
            modifiedAt: frame.modified > 0 ? Date(timeIntervalSince1970: TimeInterval(frame.modified)) : nil,
            readError: frame.readError,
            kind: .other,
            children: frame.retained
        )
        let floor = max(options.retainFloorBytes, root.bytes / 2_048)
        Self.prune(&root, floor: floor)

        var ranked = findings.filter { $0.bytes >= options.findingFloorBytes }
        ranked.sort { lhs, rhs in lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.path < rhs.path }
        if ranked.count > options.maxFindings { ranked.removeLast(ranked.count - options.maxFindings) }
        return (root, ranked)
    }

    static func prune(_ node: inout DiskNode, floor: UInt64) {
        node.children.removeAll { $0.bytes < floor }
        var shownBytes: UInt64 = 0
        var shownEntries: UInt64 = 0
        for index in node.children.indices {
            prune(&node.children[index], floor: floor)
            let child = node.children[index]
            shownBytes &+= child.bytes
            shownEntries &+= child.files &+ child.directories &+ (child.isDirectory ? 1 : 0)
        }
        node.remainderBytes = node.bytes > shownBytes ? node.bytes - shownBytes : 0
        let entries = node.files &+ node.directories
        node.remainderCount = entries > shownEntries ? entries - shownEntries : 0
    }
}
