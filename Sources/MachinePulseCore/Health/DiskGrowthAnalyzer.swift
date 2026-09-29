import Foundation

public enum DiskGrowthState: String, Codable, Hashable, Sendable {
    case stable
    case growing
    case shrinking
    case temporarySpike
}

public struct DiskGrowthTrend: Codable, Hashable, Sendable {
    public let state: DiskGrowthState
    public let changeBytes: Int64
    public let peakAboveBaselineBytes: UInt64
    public let startedAt: Date
    public let endedAt: Date
    public let sampleCount: Int

    public init(
        state: DiskGrowthState,
        changeBytes: Int64,
        peakAboveBaselineBytes: UInt64,
        startedAt: Date,
        endedAt: Date,
        sampleCount: Int
    ) {
        self.state = state
        self.changeBytes = changeBytes
        self.peakAboveBaselineBytes = peakAboveBaselineBytes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sampleCount = sampleCount
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public enum DiskGrowthAnalyzer {
    public static let defaultWindow: TimeInterval = 2 * 60 * 60

    public static func analyze(
        samples: [MetricSample],
        window: TimeInterval = DiskGrowthAnalyzer.defaultWindow,
        minimumSpan: TimeInterval = 15 * 60,
        maximumGap: TimeInterval = 5 * 60
    ) -> DiskGrowthTrend? {
        guard let latest = samples.max(by: { $0.timestamp < $1.timestamp }), latest.diskTotalBytes > 0 else {
            return nil
        }
        let cutoff = latest.timestamp.addingTimeInterval(-window)
        let ordered =
            samples
            .filter { $0.timestamp >= cutoff && $0.timestamp <= latest.timestamp }
            .sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 3 else { return nil }

        var compatibleSuffix: [MetricSample] = []
        for sample in ordered.reversed() {
            guard volumeSizeMatches(sample.diskTotalBytes, latest.diskTotalBytes) else { break }
            if let newer = compatibleSuffix.last,
                newer.timestamp.timeIntervalSince(sample.timestamp) > maximumGap
            {
                break
            }
            compatibleSuffix.append(sample)
        }
        compatibleSuffix.reverse()
        guard
            compatibleSuffix.count >= 3,
            let first = compatibleSuffix.first,
            let last = compatibleSuffix.last,
            last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan
        else { return nil }

        let bucketSize = max(1, compatibleSuffix.count / 5)
        let baseline = median(compatibleSuffix.prefix(bucketSize).map(\.diskUsedBytes))
        let recent = median(compatibleSuffix.suffix(bucketSize).map(\.diskUsedBytes))
        let peak = compatibleSuffix.map(\.diskUsedBytes).max() ?? recent
        let meaningfulChange = max(UInt64(64 * 1_024 * 1_024), latest.diskTotalBytes / 1_000)
        let change = signedDifference(recent, baseline)
        let peakAboveBaseline = peak >= baseline ? peak - baseline : 0

        let state: DiskGrowthState
        if change > Int64(clamping: meaningfulChange) {
            state = .growing
        } else if change < -Int64(clamping: meaningfulChange) {
            state = .shrinking
        } else if peakAboveBaseline > meaningfulChange {
            state = .temporarySpike
        } else {
            state = .stable
        }
        return DiskGrowthTrend(
            state: state,
            changeBytes: change,
            peakAboveBaselineBytes: peakAboveBaseline,
            startedAt: first.timestamp,
            endedAt: last.timestamp,
            sampleCount: compatibleSuffix.count
        )
    }

    private static func volumeSizeMatches(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
        let larger = max(lhs, rhs)
        guard larger > 0 else { return false }
        let difference = lhs >= rhs ? lhs - rhs : rhs - lhs
        return difference <= larger / 100
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        return ordered[ordered.count / 2]
    }

    private static func signedDifference(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        if lhs >= rhs { return Int64(clamping: lhs - rhs) }
        return -Int64(clamping: rhs - lhs)
    }
}
