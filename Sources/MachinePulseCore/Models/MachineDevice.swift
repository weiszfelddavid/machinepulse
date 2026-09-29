import Foundation

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case linux
    case macOS
    case iOS
    case android
    case windows
    case unknown

    public var supportsFullMetrics: Bool {
        self == .linux || self == .macOS
    }

    public init(tailscaleValue: String) {
        switch tailscaleValue.lowercased() {
        case "linux": self = .linux
        case "macos", "darwin": self = .macOS
        case "ios": self = .iOS
        case "android": self = .android
        case "windows": self = .windows
        default: self = .unknown
        }
    }
}

public enum ConnectionKind: String, Codable, Sendable {
    case local
    case direct
    case relay
    case idle
    case offline
    case unknown
}

public enum MonitoringMode: String, Codable, Sendable {
    case presence
    case deep
}

public struct MachineDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let dnsName: String?
    public let addresses: [String]
    public let platform: DevicePlatform
    public let isLocal: Bool
    public let isOnline: Bool
    public let lastSeen: Date?
    public let connection: ConnectionKind
    public let receivedBytes: UInt64
    public let transmittedBytes: UInt64

    public var collectsOverSSH: Bool {
        !isLocal && platform.supportsFullMetrics
    }

    public init(
        id: String,
        name: String,
        dnsName: String? = nil,
        addresses: [String] = [],
        platform: DevicePlatform,
        isLocal: Bool = false,
        isOnline: Bool,
        lastSeen: Date? = nil,
        connection: ConnectionKind = .unknown,
        receivedBytes: UInt64 = 0,
        transmittedBytes: UInt64 = 0
    ) {
        self.id = id
        self.name = name
        self.dnsName = dnsName
        self.addresses = addresses
        self.platform = platform
        self.isLocal = isLocal
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.connection = connection
        self.receivedBytes = receivedBytes
        self.transmittedBytes = transmittedBytes
    }

    /// Mobile devices sleep, roam, and run out of battery as a matter of
    /// course; an offline phone is expected, not an incident.
    public var isMobile: Bool {
        platform == .iOS || platform == .android
    }
}
