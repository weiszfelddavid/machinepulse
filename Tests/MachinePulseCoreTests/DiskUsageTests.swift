import Foundation
import Testing
@testable import MachinePulseCore

/// The classification, findings, bounds and layout rules ported from
/// disktree, exercised through the same engine the scanners drive.
struct DiskUsageTests {
    private static let gib: UInt64 = 1_024 * 1_024 * 1_024
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private indirect enum Entry {
        case dir(String, [Entry])
        case file(String, UInt64, daysOld: Int = 1)

        var name: String {
            switch self {
            case let .dir(name, _), let .file(name, _, _): name
            }
        }
    }

    private static func flags(of children: [Entry]) -> DiskClassifier.SiblingFlags {
        var flags = DiskClassifier.SiblingFlags()
        for child in children { flags.note(child.name) }
        return flags
    }

    private static func feed(_ entries: [Entry], into engine: inout DiskScanEngine) {
        for entry in entries {
            switch entry {
            case let .file(name, bytes, daysOld):
                engine.addEntry(
                    name: name, entryKind: .file, bytes: bytes,
                    modified: Int64(now.timeIntervalSince1970) - Int64(daysOld) * 86_400)
            case let .dir(name, children):
                engine.enterDirectory(name: name, flags: flags(of: children))
                feed(children, into: &engine)
                engine.leaveDirectory(ownBytes: 0, ownModified: 0)
            }
        }
    }

    private static func scan(
        _ children: [Entry],
        rootName: String = "tobi",
        configure: (inout DiskScanOptions) -> Void = { _ in }
    ) -> (root: DiskNode, findings: [DiskFinding]) {
        var options = DiskScanOptions()
        options.now = now
        options.retainFloorBytes = 1
        options.findingFloorBytes = 64 * 1_024 * 1_024
        configure(&options)
        var engine = DiskScanEngine(rootName: rootName, rootFlags: flags(of: children), options: options)
        feed(children, into: &engine)
        return engine.finish(rootOwnBytes: 0, rootModified: 0)
    }

    private static func home() -> DiskNode {
        scan([
            .dir("src", [.dir("tries", [.dir("2026-09-01", [.file("a", 1)])])]),
            .dir(".cache", [.dir("kache", [.dir("store", [.file("b", 1)])])]),
            .dir("world", [.dir(".git", [.dir("objects", [.file("c", 9)])]), .file("README", 1)]),
            .dir("rust-thing", [.file("Cargo.toml", 1), .dir("target", [.file("d", 5)])]),
            .dir("js-thing", [.dir("target", [.file("e", 5)])]),
            .dir(
                ".microsandbox",
                [.dir("cache", [.dir("layers", [.file("f", 1)])]), .dir("snapshots", [.file("g", 1)])]),
            .dir("Sync", [.dir(".stversions", [.file("h", 1)])]),
            .dir("mystery", [.file("i", 1)]),
            .dir(
                "monorepo",
                [.dir("git", [.file("HEAD", 1), .dir("refs", []), .dir("objects", [.file("pack", 50)])])]),
        ]).root
    }

    private static func named(_ node: DiskNode, _ path: [String]) throws -> DiskNode {
        var node = node
        for part in path { node = try #require(node.child(named: part)) }
        return node
    }

    @Test func namesAnnounceTheirKindAndChildrenInheritIt() throws {
        let home = Self.home()
        #expect(try Self.named(home, ["src"]).kind == .code)
        #expect(try Self.named(home, ["src", "tries"]).kind == .agentScratch)
        #expect(try Self.named(home, ["src", "tries", "2026-09-01"]).kind == .agentScratch)
        #expect(try Self.named(home, ["src", "tries", "2026-09-01", "a"]).kind == .agentScratch)
    }

    @Test func anUnknownTopLevelDirectoryTakesItsLargestKnownChild() throws {
        let home = Self.home()
        #expect(try Self.named(home, ["world"]).kind == .git)
        #expect(try Self.named(home, ["world", "README"]).kind == .git)
        #expect(try Self.named(home, ["mystery"]).kind == .other)
        #expect(try Self.named(home, ["monorepo"]).kind == .git)
        #expect(try Self.named(home, ["monorepo", "git"]).kind == .git)
    }

    @Test func cachesAreReclaimableAllTheWayDown() throws {
        let home = Self.home()
        #expect(try Self.named(home, [".cache"]).reclaim == .regenerable)
        #expect(try Self.named(home, [".cache", "kache", "store"]).reclaim == .regenerable)
        #expect(try Self.named(home, ["Sync", ".stversions"]).reclaim == .syncHistory)
        #expect(try Self.named(home, ["src"]).reclaim == nil)
    }

    @Test func reclaimableBytesCountEachHatchedTileOnce() {
        let home = Self.home()
        #expect(home.reclaimableBytes == 9)
        #expect(home.child(named: ".microsandbox")?.reclaimableBytes == 2)
        #expect(home.child(named: "js-thing")?.reclaimableBytes == 0)
    }

    @Test func targetIsBuildOutputOnlyBesideACargoManifest() throws {
        let home = Self.home()
        #expect(try Self.named(home, ["rust-thing", "target"]).reclaim == .buildOutput)
        #expect(try Self.named(home, ["js-thing", "target"]).reclaim == nil)
    }

    @Test func sandboxLayersAndSnapshotsAreReclaimableOnlyInSandboxState() throws {
        let home = Self.home()
        #expect(try Self.named(home, [".microsandbox", "cache", "layers"]).reclaim != nil)
        #expect(try Self.named(home, [".microsandbox", "snapshots"]).reclaim == .snapshots)
        #expect(
            DiskClassifier.reclaim(ofName: "snapshots", parent: .documents, siblings: DiskClassifier.SiblingFlags())
                == nil)
    }

    @Test func macOSDeveloperLeftoversAreReclaimableAndItsRisksAreNot() {
        let none = DiskClassifier.SiblingFlags()
        var library = DiskClassifier.SiblingFlags()
        library.note("Application Support")
        #expect(DiskClassifier.reclaim(ofName: "DerivedData", parent: .toolchain, siblings: none) == .buildOutput)
        #expect(DiskClassifier.reclaim(ofName: "iOS DeviceSupport", parent: .toolchain, siblings: none) == .regenerable)
        #expect(DiskClassifier.reclaim(ofName: "Logs", parent: .other, siblings: library) == .temporary)
        #expect(DiskClassifier.reclaim(ofName: "logs", parent: .code, siblings: none) == nil)
        #expect(DiskClassifier.reclaim(ofName: "Archives", parent: .toolchain, siblings: none) == nil)
        #expect(DiskClassifier.reclaim(ofName: "Backup", parent: .other, siblings: none) == nil)
        #expect(DiskClassifier.kind(ofName: "Mobile Documents") == .synced)
        #expect(DiskClassifier.kind(ofName: "Developer") == nil)
        #expect(DiskClassifier.kind(ofName: "Xcode") == .toolchain)
        #expect(DiskClassifier.kind(ofName: "OneDrive - Contoso") == .synced)
        #expect(DiskClassifier.kind(ofName: "$Recycle.Bin") == .cache)
        #expect(DiskClassifier.reclaim(ofName: "Temp", parent: .other, siblings: none) == .temporary)
    }

    @Test func aSteamLibraryOnAnotherDriveIsMediaNotItsTempFolder() throws {
        let root = Self.scan(
            [
                .dir(
                    "SteamLibrary",
                    [
                        .dir(
                            "steamapps",
                            [.dir("temp", [.file("partial", 1)]), .dir("common", [.file("game.pak", 1_000)])])
                    ])
            ], rootName: "data"
        ).root
        let library = try Self.named(root, ["SteamLibrary"])
        #expect(library.kind == .media)
        let common = try Self.named(root, ["SteamLibrary", "steamapps", "common"])
        #expect(common.kind == .media)
        #expect(common.reclaim == nil)
    }

    private static func findingsHome() -> (root: DiskNode, findings: [DiskFinding]) {
        scan([
            .dir(".cache", [.dir("kache", [.file("blob", 5 * gib)])]),
            .dir(
                ".codex",
                [
                    .dir(
                        "worktrees",
                        [.dir("a1", [.file("x", 3 * gib, daysOld: 41)]), .dir("b2", [.file("y", 2 * gib, daysOld: 3)])]
                    )
                ]),
            .dir(
                "src",
                [
                    .dir(
                        "tries",
                        [
                            .dir("old", [.file("z", 4 * gib, daysOld: 90)]),
                            .dir("fresh", [.file("Cargo.toml", 1), .dir("target", [.file("o", gib)])]),
                        ])
                ]),
            .dir("Documents", [.file("tax.pdf", 9 * gib, daysOld: 400)]),
            .dir("tiny", [.dir(".cache", [.file("t", 1_024)])]),
        ])
    }

    @Test func rankingKeepsTheLargestFindingsFirstAndSkipsTheTiny() {
        let findings = Self.findingsHome().findings
        #expect(findings.map(\.kind) == [.reclaimable, .worktrees, .staleExperiments, .reclaimable])
        #expect(findings[0].path == ".cache")
        #expect(findings[0].reclaim == .regenerable)
        #expect(findings[0].bytes == 5 * Self.gib)
        #expect(findings[1].path == ".codex/worktrees")
        #expect(findings[1].count == 2)
        #expect(findings[1].oldestDays == 41)
        #expect(findings[2].path == "src/tries")
        #expect(findings[2].bytes == 4 * Self.gib)
        #expect(findings[2].count == 1)
        #expect(findings[3].path == "src/tries/fresh/target")
        #expect(findings[3].reclaim == .buildOutput)
        #expect(!(findings.contains { $0.path.hasPrefix("Documents") }))
        #expect(!(findings.contains { $0.path.hasPrefix("tiny") }))
    }

    @Test func findingsNeverNestAndTheLimitKeepsTheLargest() {
        let (_, findings) = Self.scan(
            [
                .dir(
                    ".cache",
                    [.dir("outer", [.dir("cache", [.file("inner", 2 * Self.gib)])]), .file("blob", Self.gib)]),
                .dir("Downloads", [.file("big.iso", 8 * Self.gib)]),
            ]
        ) { $0.maxFindings = 1 }
        #expect(findings.count == 1)
        #expect(findings[0].path == ".cache")
        #expect(findings[0].bytes == 3 * Self.gib)
    }

    @Test func aStaleExperimentIsJudgedWholeAndItsCachesGoWithIt() {
        let (_, findings) = Self.scan([
            .dir(
                "experiments",
                [
                    .dir(
                        "old",
                        [.dir(".cache", [.file("c", 2 * Self.gib, daysOld: 60)]), .file("z", Self.gib, daysOld: 90)]),
                    .dir("fresh", [.dir(".cache", [.file("d", Self.gib, daysOld: 2)])]),
                ])
        ])
        #expect(findings.map(\.path) == ["experiments", "experiments/fresh/.cache"])
        #expect(findings[0].kind == .staleExperiments)
        #expect(findings[0].bytes == 3 * Self.gib)
    }

    @Test func retentionKeepsTheLargestChildrenWithinTheDepthBoundAndAccountsTheRest() throws {
        let (root, _) = Self.scan(
            [
                .dir(
                    "src",
                    [
                        .file("big", 1_000), .file("mid", 500), .file("small", 10), .file("tiny", 1),
                        .dir("deep1", [.dir("deep2", [.dir("deep3", [.dir("deep4", [.file("x", 700)])])])]),
                    ])
            ]
        ) { options in
            options.maxChildren = 2
            options.maxDepth = 3
            options.retainFloorBytes = 5
        }
        let src = try Self.named(root, ["src"])
        #expect(src.bytes == 2_211)
        #expect(src.files == 5)
        #expect(src.directories == 4)
        #expect(src.children.map(\.name) == ["big", "deep1"])
        #expect(src.remainderBytes == 511)
        #expect(src.remainderCount == 3)
        let deep2 = try Self.named(root, ["src", "deep1", "deep2"])
        #expect(deep2.bytes == 700)
        #expect(deep2.children.isEmpty)
        #expect(deep2.remainderBytes == 700)
        #expect(deep2.remainderCount == 3)
    }

    @Test func theFinalFloorMergesSmallSharesIntoTheRemainder() throws {
        let (root, _) = Self.scan([
            .dir("big", [.file("a", 4_096 * 1_000)]),
            .dir("small", [.file("b", 1)]),
        ])
        #expect(root.children.map(\.name) == ["big"])
        #expect(root.remainderBytes == 1)
        #expect(root.remainderCount == 2)
    }

    @Test func unreadableDirectoriesStayInTheTreeWithUnknownContents() throws {
        var options = DiskScanOptions()
        options.retainFloorBytes = 1
        var engine = DiskScanEngine(rootName: "home", rootFlags: DiskClassifier.SiblingFlags(), options: options)
        engine.enterDirectory(name: "Library", flags: DiskClassifier.SiblingFlags())
        engine.markUnreadable()
        engine.leaveDirectory(ownBytes: 4_096, ownModified: 0)
        engine.addSkippedDirectory(bytes: 4_096, modified: 0)
        let (root, _) = engine.finish(rootOwnBytes: 0, rootModified: 0)
        #expect(engine.unreadableCount == 1)
        #expect(root.directories == 2)
        #expect(root.children.first?.readError == true)
    }

    @Test func squarifiedTilesStayInsideTheirParentAndDoNotOverlap() throws {
        let (root, _) = Self.scan([
            .dir("a", [.file("a1", 6_000), .file("a2", 3_000), .file("a3", 1_000)]),
            .dir("b", [.file("b1", 4_000)]),
            .dir("c", [.file("c1", 2_000)]),
            .file("d", 500),
        ])
        var options = DiskTreemapOptions()
        options.minTile = 2
        let frame = CGRect(x: 0, y: 0, width: 380, height: 240)
        let tiles = DiskTreemap.layout(root, in: frame, options: options)
        #expect(!(tiles.isEmpty))
        for tile in tiles {
            #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect))
        }
        let topLevel = tiles.filter { $0.depth == 0 }
        for (index, left) in topLevel.enumerated() {
            for right in topLevel.dropFirst(index + 1) {
                #expect(!(left.rect.insetBy(dx: 0.01, dy: 0.01).intersects(right.rect)))
            }
        }
        let aTile = topLevel.first { $0.name == "a" }
        let a = try #require(aTile)
        #expect(a.hasHeader)
        let nested = tiles.filter { $0.depth == 1 && $0.crumbs.first == a.crumbs.first }
        #expect(nested.count == 3)
        for tile in nested { #expect(a.rect.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect)) }
        let hitTile = DiskTreemap.hit(tiles, at: CGPoint(x: nested[0].rect.midX, y: nested[0].rect.midY))
        let hit = try #require(hitTile)
        #expect(hit.crumbs == nested[0].crumbs)
        let area = topLevel.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        let inner = frame.insetBy(dx: options.paddingOuter, dy: options.paddingOuter)
        #expect(area > Double(inner.width * inner.height) * 0.98)
    }

    @Test func theRemainderBecomesOneTileSoNoAreaIsDropped() throws {
        var node = DiskNode(name: "home", entryKind: .directory, bytes: 1_000, files: 3, directories: 1)
        node.children = [DiskNode(name: "big", entryKind: .directory, bytes: 600, files: 1, directories: 0)]
        node.remainderBytes = 400
        node.remainderCount = 2
        let tiles = DiskTreemap.layout(node, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        let remainderTile = tiles.first(where: \.isRemainder)
        let remainder = try #require(remainderTile)
        #expect(remainder.bytes == 400)
        #expect(remainder.name == "2 smaller entries")
    }

    @Test func theCleanupPromptListsEveryFindingWithItsSizeAndTheRules() {
        let scan = DiskScan(
            deviceID: "d", scannedAt: Self.now, rootPath: "/home/me", durationSeconds: 1, unreadableCount: 0,
            volume: DiskVolume(totalBytes: 500 << 30, freeBytes: 12 << 30, availableBytes: 10 << 30),
            root: DiskNode(name: "me", entryKind: .directory, bytes: 9 << 30, files: 2, directories: 2),
            findings: [
                DiskFinding(path: "src/old/target", bytes: 5 << 30, kind: .reclaimable, reclaim: .buildOutput),
                DiskFinding(path: ".codex/worktrees", bytes: 4 << 30, kind: .worktrees, count: 3, oldestDays: 41),
                DiskFinding(path: "x\n/home/me", bytes: 1 << 20, kind: .reclaimable, reclaim: .temporary),
            ],
            scannerVersion: "test"
        )
        let prompt = DiskCleanupComposer.prompt(scan: scan, machineName: "vps", platformName: "Linux")
        #expect(prompt.contains("scanned /home/me and found 9.0 GiB in 2 files"))
        #expect(prompt.contains("9.0 GiB in all"))
        #expect(prompt.contains("10 GiB available of 500 GiB"))
        #expect(prompt.contains("- /home/me/src/old/target  (5.0 GiB, build output)"))
        #expect(prompt.contains("- /home/me/.codex/worktrees  (4.0 GiB, 3 worktrees · oldest 41 days)"))
        #expect(prompt.contains("escaped, find by hand: /home/me/x\\n/home/me"))
        #expect(!(prompt.split(separator: "\n").contains { $0 == "/home/me" }))
        #expect(prompt.contains("git status"))
        #expect(prompt.contains("Do not delete anything else"))
    }

    @Test func sizesUseBinaryUnitsWithOneDecimalBelowTen() {
        #expect(SizeFormat.bytes(0) == "0 B")
        #expect(SizeFormat.bytes(1_536) == "1.5 KiB")
        #expect(SizeFormat.bytes(512 * 1_024 * 1_024) == "512 MiB")
        #expect(SizeFormat.bytes(Self.gib + 400 * 1_024 * 1_024) == "1.4 GiB")
        #expect(SizeFormat.count(9_999) == "9999")
        #expect(SizeFormat.count(12_000) == "12.0k")
        #expect(SizeFormat.count(2_500_000) == "2.5M")
    }

    @Test func localScannerMeasuresATemporaryTreeOnce() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseDiskScan-\(UUID().uuidString)", isDirectory: true)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manager = FileManager.default
        try manager.createDirectory(
            at: home.appendingPathComponent("src/app/target"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try manager.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        func write(_ path: String, bytes: Int) throws {
            try Data(repeating: 0x61, count: bytes).write(to: home.appendingPathComponent(path))
        }
        try write("src/app/Cargo.toml", bytes: 100)
        try manager.createDirectory(at: home.appendingPathComponent("target"), withIntermediateDirectories: true)
        try write("Cargo.toml", bytes: 100)
        try write("target/root.bin", bytes: 1 << 20)
        try write("src/app/target/big.bin", bytes: 2 << 20)
        try write(".cache/blob.bin", bytes: 3 << 20)
        try write("Documents/doc.pdf", bytes: 1 << 20)
        #expect(
            link(
                home.appendingPathComponent("Documents/doc.pdf").path,
                home.appendingPathComponent("Documents/copy.pdf").path) == 0)
        try manager.createSymbolicLink(
            at: home.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent("src"))
        let locked = home.appendingPathComponent("Library/Mail")
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try write("Library/Mail/secret", bytes: 4_096)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        var options = DiskScanOptions()
        options.retainFloorBytes = 64 * 1_024
        options.findingFloorBytes = 1 << 20
        let scan = try LocalDiskScanner.scan(deviceID: "local", root: home, options: options)

        #expect(scan.rootPath == home.standardizedFileURL.path)
        #expect(scan.root.directories == 9)
        #expect(scan.root.files == 8)
        #expect(scan.root.bytes > UInt64(7 << 20))
        #expect(scan.root.bytes < UInt64(7 << 20) + 512 * 1_024)
        #expect(scan.unreadableCount == 1)
        #expect((scan.root.child(named: "Library")?.child(named: "Mail")?.readError ?? true) == true)
        #expect(scan.volume != nil)
        #expect(scan.scannerVersion == LocalDiskScanner.scannerVersion)

        let target = try Self.named(scan.root, ["src", "app", "target"])
        #expect(target.reclaim == .buildOutput)
        #expect(target.children.map(\.name) == ["big.bin"])
        #expect(try Self.named(scan.root, [".cache"]).kind == .cache)
        #expect(scan.findings.map(\.path) == [".cache", "src/app/target", "target"])
        #expect(scan.findings.map(\.reclaim) == [.regenerable, .buildOutput, .buildOutput])
        #expect(scan.root.child(named: "Downloads") == nil)
        #expect(scan.root.child(named: "link")?.entryKind == nil)
    }

    @Test func fullDiskAccessIsJudgedByTheFirstProtectedPathThatExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseHome-\(UUID().uuidString)", isDirectory: true)
        let safari = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LocalDiskScanner.fullDiskAccess(home: home) == nil)

        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }
        #expect(LocalDiskScanner.fullDiskAccess(home: home) == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path)
        #expect(LocalDiskScanner.fullDiskAccess(home: home) == true)
    }

    @Test func storeKeepsOneScanPerMachine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseDiskStore-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MetricsStore(url: url)
        let first = DiskScan(
            deviceID: "d", scannedAt: Self.now, rootPath: "/home/me", durationSeconds: 1, unreadableCount: 2,
            volume: nil, root: DiskNode(name: "me", entryKind: .directory, bytes: 10), findings: [],
            scannerVersion: "test")
        let second = DiskScan(
            deviceID: "d", scannedAt: Self.now.addingTimeInterval(60), rootPath: "/home/me", durationSeconds: 1,
            unreadableCount: 0, volume: nil,
            root: DiskNode(
                name: "me", entryKind: .directory, bytes: 20,
                children: [
                    DiskNode(name: "x", entryKind: .file, bytes: 20, files: 1, modifiedAt: Self.now, kind: .code)
                ]),
            findings: [DiskFinding(path: "x", bytes: 20, kind: .reclaimable, reclaim: .trash)], scannerVersion: "test")
        try await store.save(first)
        try await store.save(second)
        let scans = try await store.latestDiskScans()
        #expect(scans.count == 1)
        #expect(scans.first == second)
    }
}
