import Foundation

public enum TailscaleDiscoveryError: LocalizedError, Sendable {
    case unavailable
    case notRunning(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Tailscale is not installed or its command-line tool is unavailable."
        case let .notRunning(state):
            "Tailscale is not connected (\(state))."
        case let .invalidResponse(message):
            "Tailscale returned an invalid device list: \(message)"
        }
    }
}

public actor TailscaleDiscovery {
    private let executable: String?

    public init(executable: String? = ExecutableLocator.tailscale) {
        self.executable = executable
    }

    public func discover() async throws -> [MachineDevice] {
        guard let executable else {
            throw TailscaleDiscoveryError.unavailable
        }

        let result = try await CommandRunner.run(
            executable: executable,
            arguments: ["status", "--json"],
            timeout: 10
        )
        return try Self.decodeStatus(result.standardOutput)
    }

    public static func decodeStatus(_ data: Data) throws -> [MachineDevice] {
        let status: StatusDocument
        do {
            status = try JSONDecoder().decode(StatusDocument.self, from: data)
        } catch {
            throw TailscaleDiscoveryError.invalidResponse(error.localizedDescription)
        }

        guard status.backendState.lowercased() == "running" else {
            throw TailscaleDiscoveryError.notRunning(status.backendState)
        }

        var devices: [MachineDevice] = []
        if let local = status.selfNode {
            devices.append(local.machineDevice(isLocal: true))
        }
        devices.append(contentsOf: (status.peers ?? [:]).values.map { $0.machineDevice(isLocal: false) })

        return devices.sorted {
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private struct StatusDocument: Decodable {
    let backendState: String
    let selfNode: TailscaleNode?
    let peers: [String: TailscaleNode]?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peers = "Peer"
    }
}

/// The subset of `tailscale status --json` a device needs. A node without an
/// ID is a decoding error, never a device with an invented identity.
private struct TailscaleNode: Decodable {
    let id: String
    let hostName: String
    let dnsName: String?
    let addresses: [String]?
    let os: String?
    let online: Bool?
    let active: Bool?
    let lastSeen: String?
    let currentAddress: String?
    let relay: String?
    let receivedBytes: UInt64?
    let transmittedBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case addresses = "TailscaleIPs"
        case os = "OS"
        case online = "Online"
        case active = "Active"
        case lastSeen = "LastSeen"
        case currentAddress = "CurAddr"
        case relay = "Relay"
        case receivedBytes = "RxBytes"
        case transmittedBytes = "TxBytes"
    }

    func machineDevice(isLocal: Bool) -> MachineDevice {
        let parsedLastSeen: Date? = {
            guard let lastSeen, !lastSeen.hasPrefix("0001-") else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: lastSeen)
        }()

        let online = online ?? false
        let active = active ?? false
        let connection: ConnectionKind
        if isLocal {
            connection = .local
        } else if !online {
            connection = .offline
        } else if active, let currentAddress, !currentAddress.isEmpty {
            connection = .direct
        } else if active, let relay, !relay.isEmpty {
            connection = .relay
        } else {
            connection = .idle
        }

        return MachineDevice(
            id: id,
            name: hostName,
            dnsName: dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            addresses: addresses ?? [],
            platform: DevicePlatform(tailscaleValue: os ?? "unknown"),
            isLocal: isLocal,
            isOnline: isLocal || online,
            lastSeen: parsedLastSeen,
            connection: connection,
            receivedBytes: receivedBytes ?? 0,
            transmittedBytes: transmittedBytes ?? 0
        )
    }
}
