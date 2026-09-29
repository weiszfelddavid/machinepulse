import Foundation

/// Binary units, like `du -h` and disktree: one decimal below 10, none above.
public enum SizeFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

    public static func bytes(_ value: UInt64) -> String {
        var scaled = Double(value)
        var unit = 0
        while scaled >= 1_024, unit + 1 < units.count {
            scaled /= 1_024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        return scaled < 9.95
            ? String(format: "%.1f %@", scaled, units[unit])
            : String(format: "%.0f %@", scaled, units[unit])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, min(bytesPerSecond, Double(UInt64.max))))) + "/s"
    }

    public static func count(_ value: UInt64) -> String {
        let scaled = Double(value)
        if value < 10_000 { return "\(value)" }
        if scaled < 1_000_000 { return String(format: "%.1fk", scaled / 1_000) }
        if scaled < 1_000_000_000 { return String(format: "%.1fM", scaled / 1_000_000) }
        return String(format: "%.1fG", scaled / 1_000_000_000)
    }

    public static func share(_ part: UInt64, of total: UInt64) -> Double {
        total == 0 ? 0 : Double(part) / Double(total) * 100
    }
}
