import Foundation

/// What a directory *is*, and whether its space can be had back, judged from
/// names. The rules are ported from disktree (`classify.rs`, MIT, Tobi
/// Lütke): a directory's own name wins, otherwise it inherits its parent's
/// kind; reclaimable space is inherited too, so everything under a cache is
/// reclaimable. Where a name alone is too common to trust, a sibling or the
/// parent's kind decides: `target` is only build output beside `Cargo.toml`.
/// The name tables are data so a test can hold them equal to the collector's.
public enum DiskClassifier {
    /// The names a directory listing is checked for, so a child can be judged
    /// by what stands beside it without keeping the whole listing.
    public struct SiblingFlags: Hashable, Sendable {
        public var hasCargoManifest = false
        public var hasPackageManifest = false
        public var hasApplicationSupport = false
        public var hasObjects = false
        public var hasRefs = false
        public var hasHead = false

        public init() {}

        public mutating func note(_ name: String) {
            switch name {
            case "Cargo.toml": hasCargoManifest = true
            case "package.json": hasPackageManifest = true
            case "Application Support": hasApplicationSupport = true
            case "objects": hasObjects = true
            case "refs": hasRefs = true
            case "HEAD": hasHead = true
            default: break
            }
        }

        /// A git object store by its shape, whatever it is called: a bare
        /// repository, or a `.git` directory, has `objects`, `refs` and `HEAD`.
        public var isGitStore: Bool { hasObjects && hasRefs && hasHead }
    }

    static let kindNames: [String: DiskKind] = table([
        (
            .code,
            [
                "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces", "github.com",
                "gitlab.com", "sites", "development",
            ]
        ),
        (
            .agentScratch,
            [
                ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini", ".continue", ".windsurf",
                ".microsandbox", ".omp", ".agents", ".openai", "tries", "worktrees", "experiments", "scratch",
                "playground",
            ]
        ),
        (
            .toolchain,
            [
                ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno", "go", ".gradle",
                ".m2", ".platformio", "mise", ".mise", ".pyenv", ".nvm", ".gem", "gem", ".rbenv", ".espressif",
                ".arduino15", ".config", ".vscode", ".zig", ".rye", ".conda", "anaconda3", "miniconda3", ".opam",
                ".ghcup", ".stack", ".julia", ".dotnet", ".android", ".sdkman", ".volta", ".yarn", ".java",
                ".nuget", "xcode", "coresimulator",
            ]
        ),
        (
            .synced,
            [
                "sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega", ".stversions",
                "mobile documents", "cloudstorage", "iclouddrive",
            ]
        ),
        (.git, [".git"]),
        (
            .media,
            [
                "pictures", "photos", "music", "videos", "movies", "steam", "steamlibrary", "steamapps", "emulation",
                "models", ".ollama", ".lmstudio", "games", "wineprefix",
            ]
        ),
        (.documents, ["documents", "desktop", "downloads", "books", "notes", "obsidian", "public", "templates"]),
        (
            .cache,
            [
                ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__", "node_modules",
                "trash", ".trash", "tmp", ".tmp", "deriveddata", "ios devicesupport", "watchos devicesupport",
                "temp", "$recycle.bin", "npm-cache", "v3-cache", "inetcache", "d3dscache", "dxcache", "glcache",
                "crashdumps",
            ]
        ),
    ])

    static let reclaimNames: [String: DiskReclaimReason] = table([
        (
            .regenerable,
            [
                ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "npm-cache", "v3-cache",
                "inetcache", "d3dscache", "dxcache", "glcache", "ios devicesupport", "watchos devicesupport",
            ]
        ),
        (.syncHistory, [".stversions"]),
        (.packageStore, [".pnpm-store", "pnpm"]),
        (
            .buildOutput,
            [
                "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".parcel-cache",
                "deriveddata",
            ]
        ),
        (.trash, ["trash", ".trash", "$recycle.bin"]),
        (.temporary, ["tmp", ".tmp", "temp", "crashdumps"]),
    ])

    private static func table<Value>(_ groups: [(Value, [String])]) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: groups.flatMap { value, names in names.map { ($0, value) } })
    }

    /// The kind a directory name announces on its own, if any.
    public static func kind(ofName name: String) -> DiskKind? {
        let lower = name.lowercased()
        if lower.hasPrefix("onedrive - ") || lower.hasPrefix("dropbox (") {
            return .synced
        }
        return kindNames[lower]
    }

    /// Whether a directory's space can be had back, judged from its name, the
    /// kind of the directory holding it, and its siblings' names.
    public static func reclaim(
        ofName name: String,
        parent: DiskKind,
        siblings: SiblingFlags
    ) -> DiskReclaimReason? {
        let lower = name.lowercased()
        if let reason = reclaimNames[lower] { return reason }
        switch lower {
        case "logs" where siblings.hasApplicationSupport: return .temporary
        case "target" where siblings.hasCargoManifest: return .buildOutput
        case "node_modules" where siblings.hasPackageManifest: return .reinstallable
        case "layers" where parent == .agentScratch: return .sandboxLayers
        case "snapshots" where parent == .agentScratch: return .snapshots
        default: return nil
        }
    }

    /// What a directory is, given what its parent is: its own name wins, a
    /// git store is git by its shape, otherwise it inherits.
    public static func kind(
        ofDirectory name: String,
        ownFlags: SiblingFlags,
        parent: DiskKind
    ) -> DiskKind {
        kind(ofName: name) ?? (ownFlags.isGitStore ? .git : parent)
    }

    /// The kind of an unknown top-level directory, from what fills it: the
    /// first recognisable name down the largest children, a few levels deep.
    public static func dominantChildKind(of node: DiskNode) -> DiskKind? {
        var node = node
        for _ in 0..<3 {
            if let recognised = node.children.lazy
                .filter(\.isDirectory)
                .compactMap({ child in kind(ofName: child.name) ?? (child.kind == .git ? .git : nil) })
                .first
            {
                return recognised
            }
            guard let largest = node.children.first(where: \.isDirectory) else { return nil }
            node = largest
        }
        return nil
    }
}
