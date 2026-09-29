import Foundation

public struct HealthThresholds: Codable, Hashable, Sendable {
    public var cpuWarningPercent: Double
    public var cpuCriticalPercent: Double
    public var memoryWarningFraction: Double
    public var memoryCriticalFraction: Double
    public var swapWarningFraction: Double
    public var diskWarningFraction: Double
    public var diskCriticalFraction: Double
    public var pressureWarningAverage10: Double
    public var pressureCriticalAverage10: Double

    public init(
        cpuWarningPercent: Double = 75,
        cpuCriticalPercent: Double = 92,
        memoryWarningFraction: Double = 0.80,
        memoryCriticalFraction: Double = 0.93,
        swapWarningFraction: Double = 0.50,
        diskWarningFraction: Double = 0.80,
        diskCriticalFraction: Double = 0.93,
        pressureWarningAverage10: Double = 8,
        pressureCriticalAverage10: Double = 25
    ) {
        self.cpuWarningPercent = cpuWarningPercent
        self.cpuCriticalPercent = cpuCriticalPercent
        self.memoryWarningFraction = memoryWarningFraction
        self.memoryCriticalFraction = memoryCriticalFraction
        self.swapWarningFraction = swapWarningFraction
        self.diskWarningFraction = diskWarningFraction
        self.diskCriticalFraction = diskCriticalFraction
        self.pressureWarningAverage10 = pressureWarningAverage10
        self.pressureCriticalAverage10 = pressureCriticalAverage10
    }

    public static let balanced = HealthThresholds()
    public static let quiet = HealthThresholds(
        cpuWarningPercent: 85,
        cpuCriticalPercent: 97,
        memoryWarningFraction: 0.88,
        memoryCriticalFraction: 0.97,
        swapWarningFraction: 0.65,
        diskWarningFraction: 0.88,
        diskCriticalFraction: 0.97,
        pressureWarningAverage10: 12,
        pressureCriticalAverage10: 35
    )
    public static let sensitive = HealthThresholds(
        cpuWarningPercent: 65,
        cpuCriticalPercent: 85,
        memoryWarningFraction: 0.72,
        memoryCriticalFraction: 0.88,
        swapWarningFraction: 0.40,
        diskWarningFraction: 0.72,
        diskCriticalFraction: 0.88,
        pressureWarningAverage10: 5,
        pressureCriticalAverage10: 18
    )

    public func validated() -> HealthThresholds {
        var value = self
        value.cpuWarningPercent = min(max(value.cpuWarningPercent, 1), 99)
        value.cpuCriticalPercent = min(max(value.cpuCriticalPercent, 2), 100)
        value.memoryWarningFraction = min(max(value.memoryWarningFraction, 0.01), 0.99)
        value.memoryCriticalFraction = min(max(value.memoryCriticalFraction, 0.02), 1)
        value.swapWarningFraction = min(max(value.swapWarningFraction, 0.01), 1)
        value.diskWarningFraction = min(max(value.diskWarningFraction, 0.01), 0.99)
        value.diskCriticalFraction = min(max(value.diskCriticalFraction, 0.02), 1)
        value.pressureWarningAverage10 = min(max(value.pressureWarningAverage10, 0.1), 99.9)
        value.pressureCriticalAverage10 = min(max(value.pressureCriticalAverage10, 0.2), 100)

        if value.cpuWarningPercent >= value.cpuCriticalPercent {
            value.cpuWarningPercent = min(value.cpuWarningPercent, 99)
            value.cpuCriticalPercent = min(100, value.cpuWarningPercent + 1)
        }
        if value.memoryWarningFraction >= value.memoryCriticalFraction {
            value.memoryWarningFraction = min(value.memoryWarningFraction, 0.99)
            value.memoryCriticalFraction = min(1, value.memoryWarningFraction + 0.01)
        }
        if value.diskWarningFraction >= value.diskCriticalFraction {
            value.diskWarningFraction = min(value.diskWarningFraction, 0.99)
            value.diskCriticalFraction = min(1, value.diskWarningFraction + 0.01)
        }
        if value.pressureWarningAverage10 >= value.pressureCriticalAverage10 {
            value.pressureWarningAverage10 = min(value.pressureWarningAverage10, 99.9)
            value.pressureCriticalAverage10 = min(100, value.pressureWarningAverage10 + 0.1)
        }
        return value
    }
}

public enum HealthSensitivityPreset: String, Codable, CaseIterable, Sendable {
    case quiet
    case balanced
    case sensitive
    case custom

    public var thresholds: HealthThresholds? {
        switch self {
        case .quiet: .quiet
        case .balanced: .balanced
        case .sensitive: .sensitive
        case .custom: nil
        }
    }
}

public struct HealthThresholdSettings: Codable, Hashable, Sendable {
    public private(set) var preset: HealthSensitivityPreset
    public private(set) var thresholds: HealthThresholds

    public init(preset: HealthSensitivityPreset = .balanced, thresholds: HealthThresholds? = nil) {
        if let presetThresholds = preset.thresholds {
            self.preset = preset
            self.thresholds = presetThresholds
        } else {
            self.preset = .custom
            self.thresholds = (thresholds ?? .balanced).validated()
        }
    }

    public mutating func select(_ preset: HealthSensitivityPreset) {
        guard let thresholds = preset.thresholds else { return }
        self.preset = preset
        self.thresholds = thresholds
    }

    public mutating func update(_ keyPath: WritableKeyPath<HealthThresholds, Double>, value: Double) {
        thresholds[keyPath: keyPath] = value
        thresholds = thresholds.validated()
        preset = .custom
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case thresholds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPreset = try container.decodeIfPresent(HealthSensitivityPreset.self, forKey: .preset) ?? .custom
        let decodedThresholds = try container.decodeIfPresent(HealthThresholds.self, forKey: .thresholds) ?? .balanced
        let validated = decodedThresholds.validated()
        if let presetThresholds = decodedPreset.thresholds, presetThresholds == validated {
            preset = decodedPreset
            thresholds = presetThresholds
        } else {
            preset = .custom
            thresholds = validated
        }
    }
}
