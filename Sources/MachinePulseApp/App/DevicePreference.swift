import Foundation
import MachinePulseCore

struct DevicePreference: Codable, Hashable {
    var isEnabled = false
    var mode: MonitoringMode = .presence
    var sshTarget: String?
    var expectedUnits: [ExpectedSystemdUnit] = []

    init(
        isEnabled: Bool = false,
        mode: MonitoringMode = .presence,
        sshTarget: String? = nil,
        expectedUnits: [ExpectedSystemdUnit] = []
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.sshTarget = sshTarget
        self.expectedUnits = Array(expectedUnits.prefix(ExpectedSystemdUnit.maxWatchlistCount))
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, mode, sshTarget, expectedUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        mode = try container.decodeIfPresent(MonitoringMode.self, forKey: .mode) ?? .presence
        sshTarget = try container.decodeIfPresent(String.self, forKey: .sshTarget)
        let decoded = try container.decodeIfPresent([ExpectedSystemdUnit].self, forKey: .expectedUnits) ?? []
        expectedUnits = Array(decoded.prefix(ExpectedSystemdUnit.maxWatchlistCount))
    }
}
