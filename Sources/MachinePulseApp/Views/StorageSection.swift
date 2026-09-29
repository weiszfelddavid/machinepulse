import AppKit
import MachinePulseCore
import SwiftUI

struct StorageSection: View {
    @Bindable var model: AppModel
    let device: MachineDevice
    @State private var crumbs: [Int] = []
    @State private var selectedTile: DiskTile?

    private var scan: DiskScan? { model.diskScans[device.id] }
    private var activity: AppModel.DiskScanActivity? { model.diskScanActivity[device.id] }
    private var isScanning: Bool { activity?.isScanning == true }
    private var viewedNode: DiskNode? {
        guard let scan else { return nil }
        return scan.root.resolve(crumbs) ?? scan.root
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Storage", systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button(scan == nil ? "Scan" : "Rescan") { model.scanDisk(for: device) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Walks the home directory once and keeps the result until the next scan.")
                }
            }
            .padding(.horizontal, 2)

            if case let .failed(message) = activity {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .warningBox()
            }

            if let scan, let node = viewedNode {
                summary(scan)
                breadcrumbs(scan)
                DiskTreemapView(node: node, crumbs: crumbs, selected: $selectedTile) { target in
                    crumbs = target
                    selectedTile = nil
                }
                .frame(height: 236)
                legend
                if let tile = selectedTile { selection(tile, in: scan) }
                findings(scan)
                actions(scan)
                access(scan)
            } else if !isScanning {
                Text(
                    "Not scanned yet. A scan walks the home directory once, keeps the largest entries, and takes seconds to a minute. Nothing is deleted."
                )
                .emptyStateBox()
            }
        }
        .onChange(of: scan?.scannedAt) { _, _ in
            crumbs = []
            selectedTile = nil
        }
    }

    private func summary(_ scan: DiskScan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let volume = scan.volume {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(MetricFormat.percent(SizeFormat.share(volume.usedBytes, of: volume.totalBytes))) full")
                    Text("\(SizeFormat.bytes(volume.availableBytes)) free")
                }
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                Text(
                    "\(SizeFormat.bytes(volume.usedBytes)) used of \(SizeFormat.bytes(volume.totalBytes)) · \(SizeFormat.bytes(scan.reclaimableBytes)) can be had back"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("\(SizeFormat.bytes(scan.reclaimableBytes)) can be had back")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Text(
                "Scanned \(scan.rootPath): \(SizeFormat.bytes(scan.totalBytes)) in \(SizeFormat.count(scan.fileCount)) files · \(RelativeTime.phrase(since: scan.scannedAt))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func breadcrumbs(_ scan: DiskScan) -> some View {
        HStack(spacing: 4) {
            if !crumbs.isEmpty {
                Button {
                    crumbs.removeLast()
                    selectedTile = nil
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
            Text(trail(scan))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let node = viewedNode, !crumbs.isEmpty {
                Text(SizeFormat.bytes(node.bytes))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private func trail(_ scan: DiskScan) -> String {
        var names = [scan.root.name]
        var node = scan.root
        for index in crumbs where node.children.indices.contains(index) {
            node = node.children[index]
            names.append(node.name)
        }
        return names.joined(separator: " › ")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach([Array(DiskKind.legend.prefix(4)), Array(DiskKind.legend.suffix(4))], id: \.self) { row in
                HStack(spacing: 9) {
                    ForEach(row, id: \.self) { kind in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DiskPalette.color(for: kind, depth: 0))
                                .frame(width: 8, height: 8)
                            Text(kind.label)
                        }
                    }
                }
            }
            Text("Hatched tiles can be had back: caches, build output, sync history, sandbox state.")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }

    private func selection(_ tile: DiskTile, in scan: DiskScan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(tile.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(
                    "\(SizeFormat.bytes(tile.bytes)) · \(String(format: "%.0f%%", SizeFormat.share(tile.bytes, of: scan.totalBytes))) of scan"
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(tile.kind.label)
                if let reclaim = tile.reclaim {
                    Text("· \(reclaim.label)")
                        .foregroundStyle(.orange)
                }
                if let node = scan.root.resolve(tile.crumbs), !tile.isRemainder {
                    if let modified = node.modifiedAt {
                        Text("· last write \(RelativeTime.phrase(since: modified))")
                    }
                    if node.isDirectory {
                        Text("· \(SizeFormat.count(node.files)) files")
                    }
                    if node.readError {
                        Text("· unreadable")
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if tile.isDirectory, !tile.isRemainder, let node = scan.root.resolve(tile.crumbs),
                    !node.children.isEmpty || node.remainderBytes > 0
                {
                    Button("Open") {
                        crumbs = tile.crumbs
                        selectedTile = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func findings(_ scan: DiskScan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Worth a look", systemImage: "sparkle.magnifyingglass")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(scan.findings.isEmpty ? "nothing large enough" : SizeFormat.bytes(scan.worthALookBytes))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(scan.findings.isEmpty ? Color.secondary : Color.orange)
            }
            if scan.findings.isEmpty {
                Text("No caches, build output, worktrees, or stale experiments of 64 MiB or more.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(scan.findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.orange)
                        .frame(width: 2, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.path)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(finding.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(SizeFormat.bytes(finding.bytes))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func actions(_ scan: DiskScan) -> some View {
        HStack(spacing: 14) {
            if !scan.findings.isEmpty {
                CopyButton(title: "Copy cleanup prompt") {
                    model.copyCleanupPrompt(for: device)
                    return true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .help(
                    "A prompt for a coding agent to review these paths carefully. MachinePulse never deletes anything.")
            }
            Spacer()
            Text(
                "took \(String(format: "%.0f", scan.durationSeconds)) s\(scan.unreadableCount > 0 ? " · \(scan.unreadableCount) unreadable" : "")"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func access(_ scan: DiskScan) -> some View {
        if scan.fullDiskAccess == false {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                Text("Without Full Disk Access, Mail, Safari, other apps' data and the Trash count as unreadable.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

enum DiskPalette {
    static func color(for kind: DiskKind, depth: Int) -> Color {
        let brightness = depth == 0 ? 0.56 : 0.68
        switch kind {
        case .code: return Color(hue: 0.60, saturation: 0.48, brightness: brightness)
        case .agentScratch: return Color(hue: 0.08, saturation: 0.52, brightness: brightness)
        case .toolchain: return Color(hue: 0.36, saturation: 0.42, brightness: brightness)
        case .synced: return Color(hue: 0.50, saturation: 0.42, brightness: brightness)
        case .git: return Color(hue: 0.97, saturation: 0.45, brightness: brightness)
        case .media: return Color(hue: 0.78, saturation: 0.42, brightness: brightness)
        case .documents: return Color(hue: 0.60, saturation: 0.06, brightness: brightness)
        case .cache: return Color(hue: 0.15, saturation: 0.50, brightness: brightness)
        case .other: return Color(hue: 0.60, saturation: 0.04, brightness: brightness - 0.08)
        }
    }
}

/// The mosaic is painted, not composed of views: hundreds of tiles belong in
/// one canvas, and labels are clipped to their own tile.
private struct DiskTreemapView: View {
    let node: DiskNode
    let crumbs: [Int]
    @Binding var selected: DiskTile?
    let onOpen: ([Int]) -> Void

    var body: some View {
        GeometryReader { proxy in
            let tiles = DiskTreemap.layout(node, in: CGRect(origin: .zero, size: proxy.size), crumbs: crumbs)
            Canvas { context, _ in
                for tile in tiles { draw(tile, in: context) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                guard let tile = DiskTreemap.hit(tiles, at: location), tile.isDirectory, !tile.isRemainder else {
                    return
                }
                onOpen(tile.crumbs)
            }
            .onTapGesture { location in
                selected = DiskTreemap.hit(tiles, at: location)
            }
            .accessibilityLabel(accessibilitySummary(tiles))
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func draw(_ tile: DiskTile, in context: GraphicsContext) {
        let rect = tile.rect
        let fill = DiskPalette.color(for: tile.kind, depth: tile.depth)
        context.fill(Path(rect), with: .color(tile.isRemainder ? fill.opacity(0.45) : fill))
        if tile.reclaim != nil {
            var hatch = context
            hatch.clip(to: Path(rect))
            var stripes = Path()
            var offset = -rect.height
            while offset < rect.width {
                stripes.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                stripes.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
                offset += 6
            }
            hatch.stroke(stripes, with: .color(.white.opacity(0.28)), lineWidth: 1)
        }
        if tile.hasHeader {
            context.fill(
                Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: tile.depth == 0 ? 14 : 12)),
                with: .color(.black.opacity(0.18)))
        }
        if selected == tile {
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white), lineWidth: 1.5)
        }
        guard rect.width >= 28, rect.height >= 12 else { return }
        var labels = context
        labels.clip(to: Path(rect.insetBy(dx: 2, dy: 0)))
        let size: CGFloat = tile.depth == 0 ? 9.5 : 8.5
        let name = labels.resolve(
            Text(tile.name).font(.system(size: size, weight: .semibold)).foregroundStyle(.white.opacity(0.92)))
        labels.draw(name, at: CGPoint(x: rect.minX + 3, y: rect.minY + 1.5), anchor: .topLeading)
        let bytes = labels.resolve(
            Text(SizeFormat.bytes(tile.bytes)).font(.system(size: size - 1)).foregroundStyle(.white.opacity(0.75)))
        let nameWidth = name.measure(in: rect.size).width
        let bytesWidth = bytes.measure(in: rect.size).width
        let fitsBesideName = rect.width >= nameWidth + bytesWidth + 12
        let fitsBelowName = rect.height >= 26 && rect.width >= bytesWidth + 6 && !tile.hasHeader
        if fitsBesideName {
            labels.draw(bytes, at: CGPoint(x: rect.maxX - 3, y: rect.minY + 1.5), anchor: .topTrailing)
        } else if fitsBelowName {
            labels.draw(bytes, at: CGPoint(x: rect.minX + 3, y: rect.minY + size + 4), anchor: .topLeading)
        }
    }

    private func accessibilitySummary(_ tiles: [DiskTile]) -> String {
        let top = tiles.filter { $0.depth == 0 }.prefix(5).map { "\($0.name) \(SizeFormat.bytes($0.bytes))" }
        return "Treemap of \(node.name): " + top.joined(separator: ", ")
    }
}
