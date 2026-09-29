import Darwin
import Foundation

public enum LocalDiskScannerError: LocalizedError {
    case cannotOpen(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path): "The directory \(path) could not be opened for scanning."
        }
    }
}

/// Measures the current Mac's home directory with `fts`: physical walk, one
/// filesystem, symlinks not followed, hardlinks once, cloud-only folders
/// never opened. Sizes are `st_blocks × 512`, the space that comes back
/// when an entry is deleted. The walk is synchronous; callers run it off the
/// main actor.
public enum LocalDiskScanner {
    public static let scannerVersion = "mac-native-disk-v1"
    private static let datalessFlag = UInt32(SF_DATALESS)

    public static func scan(
        deviceID: String,
        root: URL = FileManager.default.homeDirectoryForCurrentUser,
        options: DiskScanOptions = DiskScanOptions()
    ) throws -> DiskScan {
        let started = Date()
        let rootPath = root.standardizedFileURL.path
        var rootStat = Darwin.stat()
        guard lstat(rootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw LocalDiskScannerError.cannotOpen(rootPath)
        }

        let pathCopy = strdup(rootPath)
        defer { free(pathCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard
            let stream = paths.withUnsafeMutableBufferPointer({ buffer in
                fts_open(buffer.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
            })
        else { throw LocalDiskScannerError.cannotOpen(rootPath) }
        defer { fts_close(stream) }

        // fts_children describes the argument list until the first fts_read
        // returns the root itself; only then does it list the root's entries.
        guard let rootEntry = fts_read(stream), Int32(rootEntry.pointee.fts_info) == FTS_D else {
            throw LocalDiskScannerError.cannotOpen(rootPath)
        }
        var engine = DiskScanEngine(
            rootName: root.lastPathComponent,
            rootFlags: SiblingFlagsReader.flags(of: stream),
            options: options
        )
        var seenLinks = Set<LinkIdentity>()
        var openLevels: [Int16] = []

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            let level = entry.pointee.fts_level
            let statPointer = entry.pointee.fts_statp
            switch info {
            case FTS_D:
                let name = entryName(entry)
                if let statPointer, statPointer.pointee.st_flags & datalessFlag != 0 {
                    engine.addSkippedDirectory(
                        bytes: allocated(statPointer),
                        modified: Int64(statPointer.pointee.st_mtimespec.tv_sec)
                    )
                    _ = fts_set(stream, entry, FTS_SKIP)
                    continue
                }
                engine.enterDirectory(name: name, flags: SiblingFlagsReader.flags(of: stream))
                openLevels.append(level)
            case FTS_DP:
                guard level > 0, openLevels.last == level else { continue }
                openLevels.removeLast()
                engine.leaveDirectory(
                    ownBytes: statPointer.map(allocated) ?? 0,
                    ownModified: statPointer.map { Int64($0.pointee.st_mtimespec.tv_sec) } ?? 0
                )
            case FTS_DNR, FTS_ERR, FTS_NS:
                // fts reports a directory it cannot read as FTS_D first and
                // then again as FTS_DNR, with no post-order visit, so the
                // frame opened for it is closed here.
                if openLevels.last == level {
                    openLevels.removeLast()
                    engine.markUnreadable()
                    engine.leaveDirectory(
                        ownBytes: statPointer.map(allocated) ?? 0,
                        ownModified: statPointer.map { Int64($0.pointee.st_mtimespec.tv_sec) } ?? 0
                    )
                } else if info == FTS_DNR {
                    engine.enterDirectory(name: entryName(entry), flags: DiskClassifier.SiblingFlags())
                    engine.markUnreadable()
                    engine.leaveDirectory(ownBytes: statPointer.map(allocated) ?? 0, ownModified: 0)
                } else if level > 0 {
                    engine.markUnreadable()
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statPointer else { continue }
                var bytes = allocated(statPointer)
                if statPointer.pointee.st_nlink > 1 {
                    let identity = LinkIdentity(device: statPointer.pointee.st_dev, inode: statPointer.pointee.st_ino)
                    if !seenLinks.insert(identity).inserted { bytes = 0 }
                }
                let kind: DiskEntryKind =
                    switch info {
                    case FTS_F: .file
                    case FTS_SL, FTS_SLNONE: .symlink
                    default: .other
                    }
                engine.addEntry(
                    name: bytes >= options.retainFloorBytes ? entryName(entry) : "",
                    entryKind: kind,
                    bytes: bytes,
                    modified: Int64(statPointer.pointee.st_mtimespec.tv_sec)
                )
            default:
                continue
            }
        }

        let (rootNode, findings) = engine.finish(
            rootOwnBytes: UInt64(max(0, rootStat.st_blocks)) * 512,
            rootModified: Int64(rootStat.st_mtimespec.tv_sec)
        )
        return DiskScan(
            deviceID: deviceID,
            scannedAt: Date(),
            rootPath: rootPath,
            durationSeconds: Date().timeIntervalSince(started),
            unreadableCount: engine.unreadableCount,
            fullDiskAccess: fullDiskAccess(),
            volume: volume(at: rootPath),
            root: rootNode,
            findings: findings,
            scannerVersion: scannerVersion
        )
    }

    static func volume(at path: String) -> DiskVolume? {
        var status = Darwin.statvfs()
        guard statvfs(path, &status) == 0 else { return nil }
        let unit = UInt64(status.f_frsize > 0 ? status.f_frsize : status.f_bsize)
        return DiskVolume(
            totalBytes: UInt64(status.f_blocks) * unit,
            freeBytes: UInt64(status.f_bfree) * unit,
            availableBytes: UInt64(status.f_bavail) * unit
        )
    }

    /// The privacy database is itself protected by Full Disk Access, so
    /// opening it for reading is the test; it never shows a prompt.
    /// Whether this process may read what macOS keeps behind Full Disk
    /// Access. Which protected paths exist differs by release and by which
    /// apps have run, so the first one found decides.
    static func fullDiskAccess(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool? {
        let protected = [
            "Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari", "Library/Mail",
            "Library/Messages",
        ]
        for path in protected {
            let descriptor = open(home.appendingPathComponent(path).path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return nil
    }

    private struct LinkIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func allocated(_ statPointer: UnsafeMutablePointer<stat>) -> UInt64 {
        UInt64(max(0, statPointer.pointee.st_blocks)) * 512
    }

    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        let offset = MemoryLayout<FTSENT>.offset(of: \.fts_name) ?? 0
        let pointer = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self)
        return String(cString: pointer)
    }

    private enum SiblingFlagsReader {
        static func flags(of stream: UnsafeMutablePointer<FTS>) -> DiskClassifier.SiblingFlags {
            var flags = DiskClassifier.SiblingFlags()
            var child = fts_children(stream, FTS_NAMEONLY)
            while let current = child {
                flags.note(entryName(current))
                child = current.pointee.fts_link
            }
            return flags
        }
    }
}
