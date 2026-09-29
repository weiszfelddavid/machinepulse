import Foundation

public struct SSHCandidate: Sendable {
    public let alias: String
    public let hostname: String

    public init(alias: String, hostname: String) {
        self.alias = alias
        self.hostname = hostname
    }
}

public enum SSHConfigResolver {
    public static func candidate(for device: MachineDevice, in candidates: [SSHCandidate]) -> SSHCandidate? {
        candidates.first(where: { candidate in
            let hostname = normalize(candidate.hostname)
            let deviceNames = Set(
                device.addresses.map(normalize)
                    + [device.name, device.dnsName].compactMap { $0 }.map(normalize)
            )
            return deviceNames.contains(hostname)
        })
    }

    public static func candidates(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) async -> [SSHCandidate] {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }

        var resolved: [SSHCandidate] = []
        for alias in parseLiteralAliases(contents) {
            if let candidate = await resolve(alias: alias) {
                resolved.append(candidate)
            }
        }
        return resolved
    }

    public static func parseLiteralAliases(_ contents: String) -> [String] {
        var aliases: [String] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.first?.lowercased() == "host" else { continue }
            for alias in fields.dropFirst() where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
            {
                aliases.append(alias)
            }
        }
        return Array(Set(aliases)).sorted()
    }

    private static func resolve(alias: String) async -> SSHCandidate? {
        guard
            let result = try? await CommandRunner.run(
                executable: ExecutableLocator.ssh,
                arguments: ["-G", alias],
                timeout: 5
            )
        else {
            return nil
        }

        var values: [String: String] = [:]
        for line in result.outputString.split(whereSeparator: \.isNewline) {
            let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if pair.count == 2 {
                values[String(pair[0]).lowercased()] = String(pair[1])
            }
        }

        guard let hostname = values["hostname"] else {
            return nil
        }
        // A configured RemoteCommand or forced TTY represents an interactive
        // workspace alias, not a safe target for the streamed collector.
        guard values["remotecommand"] == nil, values["requesttty"] != "force" else {
            return nil
        }
        return SSHCandidate(alias: alias, hostname: hostname)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}
