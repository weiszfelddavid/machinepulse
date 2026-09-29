import CoreGraphics
import Foundation

public struct DiskTreemapOptions: Sendable {
    /// Levels drawn below the viewed directory.
    public var maxDepth = 2
    public var padding: Double = 1
    public var paddingOuter: Double = 2
    /// Tiles smaller than this in either dimension are not drawn.
    public var minTile: Double = 5
    public var header: Double = 14
    public var headerInner: Double = 12
    /// A directory is subdivided only when its name band fits.
    public var minHeaderWidth: Double = 44

    public init() {}
}

public struct DiskTile: Hashable, Sendable, Identifiable {
    public var id: String { crumbs.map(String.init).joined(separator: ".") + (isRemainder ? ".rest" : "") }
    public let rect: CGRect
    public let crumbs: [Int]
    public let depth: Int
    public let isRemainder: Bool
    public let name: String
    public let bytes: UInt64
    public let kind: DiskKind
    public let reclaim: DiskReclaimReason?
    public let isDirectory: Bool
    /// Whether the tile shows its children below a name band.
    public let hasHeader: Bool

    public init(
        rect: CGRect, crumbs: [Int], depth: Int, isRemainder: Bool, name: String, bytes: UInt64,
        kind: DiskKind, reclaim: DiskReclaimReason?, isDirectory: Bool, hasHeader: Bool
    ) {
        self.rect = rect
        self.crumbs = crumbs
        self.depth = depth
        self.isRemainder = isRemainder
        self.name = name
        self.bytes = bytes
        self.kind = kind
        self.reclaim = reclaim
        self.isDirectory = isDirectory
        self.hasHeader = hasHeader
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk), ported from
/// disktree's `treemap.rs`. Tiles come parent before children so painting
/// in order is correct, and a hit test searches from the end for the deepest
/// tile. A directory's remainder — entries the scan did not retain — becomes
/// one tile so no area is silently dropped.
public enum DiskTreemap {
    public static func layout(
        _ node: DiskNode,
        in rect: CGRect,
        crumbs: [Int] = [],
        options: DiskTreemapOptions = DiskTreemapOptions()
    ) -> [DiskTile] {
        var tiles: [DiskTile] = []
        let inner = rect.insetBy(dx: options.paddingOuter, dy: options.paddingOuter)
        place(node, crumbs: crumbs, in: inner, depth: 0, options: options, into: &tiles)
        return tiles
    }

    public static func hit(_ tiles: [DiskTile], at point: CGPoint) -> DiskTile? {
        tiles.last { $0.rect.contains(point) }
    }

    private struct Item {
        let index: Int?
        let weight: Double
    }

    private static func place(
        _ node: DiskNode,
        crumbs: [Int],
        in rect: CGRect,
        depth: Int,
        options: DiskTreemapOptions,
        into tiles: inout [DiskTile]
    ) {
        var items = node.children.enumerated().compactMap { index, child in
            child.bytes > 0 ? Item(index: index, weight: Double(child.bytes)) : nil
        }
        if node.remainderBytes > 0 { items.append(Item(index: nil, weight: Double(node.remainderBytes))) }
        items.sort { $0.weight > $1.weight }
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return }

        for (item, tileRect) in squarify(items, in: rect) {
            guard tileRect.width >= options.minTile, tileRect.height >= options.minTile else { continue }
            guard let index = item.index else {
                tiles.append(
                    DiskTile(
                        rect: tileRect, crumbs: crumbs, depth: depth, isRemainder: true,
                        name: "\(node.remainderCount) smaller entries", bytes: node.remainderBytes,
                        kind: node.kind, reclaim: node.reclaim, isDirectory: false, hasHeader: false))
                continue
            }
            let child = node.children[index]
            let childCrumbs = crumbs + [index]
            let header = depth == 0 ? options.header : options.headerInner
            let subdivides =
                child.isDirectory && depth + 1 < options.maxDepth
                && (!child.children.isEmpty || child.remainderBytes > 0)
                && tileRect.width >= options.minHeaderWidth
                && tileRect.height - header >= options.minTile * 3
            tiles.append(
                DiskTile(
                    rect: tileRect, crumbs: childCrumbs, depth: depth, isRemainder: false,
                    name: child.name, bytes: child.bytes, kind: child.kind, reclaim: child.reclaim,
                    isDirectory: child.isDirectory, hasHeader: subdivides))
            if subdivides {
                let below = CGRect(
                    x: tileRect.minX + options.padding,
                    y: tileRect.minY + header,
                    width: tileRect.width - 2 * options.padding,
                    height: tileRect.height - header - options.padding
                )
                place(child, crumbs: childCrumbs, in: below, depth: depth + 1, options: options, into: &tiles)
            }
        }
    }

    private static func squarify(_ items: [Item], in rect: CGRect) -> [(Item, CGRect)] {
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var free = rect
        var row: [Item] = []
        var placed: [(Item, CGRect)] = []

        func worst(_ row: [Item], side: Double) -> Double {
            let area = row.reduce(0) { $0 + $1.weight * scale }
            guard area > 0, side > 0 else { return .infinity }
            var ratio = 0.0
            for item in row {
                let itemArea = item.weight * scale
                let value = max(side * side * itemArea / (area * area), area * area / (side * side * itemArea))
                ratio = max(ratio, value)
            }
            return ratio
        }

        func layoutRow(_ row: [Item]) {
            let area = row.reduce(0) { $0 + $1.weight * scale }
            guard area > 0 else { return }
            if free.width >= free.height {
                let width = min(Double(free.width), area / Double(free.height))
                var y = Double(free.minY)
                for item in row {
                    let height = item.weight * scale / width
                    placed.append((item, CGRect(x: Double(free.minX), y: y, width: width, height: height)))
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: free.width - width, height: free.height)
            } else {
                let height = min(Double(free.height), area / Double(free.width))
                var x = Double(free.minX)
                for item in row {
                    let width = item.weight * scale / height
                    placed.append((item, CGRect(x: x, y: Double(free.minY), width: width, height: height)))
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: free.height - height)
            }
        }

        for item in items {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
            } else {
                layoutRow(row)
                row = [item]
            }
            if free.width <= 0 || free.height <= 0 { break }
        }
        if !row.isEmpty, free.width > 0, free.height > 0 { layoutRow(row) }
        return placed
    }
}
