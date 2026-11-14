import Foundation

/// A herdr window on this Mac: the terminal client of a herdr session.
public struct HerdrClient: Equatable, Sendable {
    public let pid: Int32
    public let tty: String
    /// The SSH target of `herdr --remote`; nil for a session on this Mac.
    public let remoteTarget: String?

    public init(pid: Int32, tty: String, remoteTarget: String? = nil) {
        self.pid = pid
        self.tty = tty
        self.remoteTarget = remoteTarget
    }

    /// Reads `ps -A -o pid= -o tty= -o args=`. Only a process with a terminal
    /// can be a window: the headless server has none.
    public static func clients(inProcessList output: String) -> [HerdrClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard
                fields.count >= 3,
                let pid = Int32(fields[0]),
                !["?", "??"].contains(fields[1]),
                (fields[2] as NSString).lastPathComponent == "herdr"
            else { return nil }
            let arguments = Array(fields.dropFirst(3))
            let attaches =
                arguments.first.map { $0.hasPrefix("-") } ?? true
                || arguments.starts(with: ["session", "attach"])
            guard attaches else { return nil }
            let remote = arguments.firstIndex(of: "--remote").flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            return HerdrClient(pid: pid, tty: fields[1], remoteTarget: remote)
        }
    }

    /// The window most likely to show a session. For this Mac (`machineNames`
    /// nil), a local window. For another machine, a `--remote` window to one
    /// of its names, else a local window, which can show saved machines. The
    /// newest window wins.
    public static func window(for machineNames: [String]?, among clients: [HerdrClient]) -> HerdrClient? {
        let local = clients.filter { $0.remoteTarget == nil }
        guard let machineNames else { return local.max { $0.pid < $1.pid } }
        let names = Set(machineNames.map(hostName))
        let remote = clients.filter { $0.remoteTarget.map { names.contains(hostName($0)) } ?? false }
        return (remote.isEmpty ? local : remote).max { $0.pid < $1.pid }
    }

    private static func hostName(_ target: String) -> String {
        let host = target.split(separator: "@").last.map(String.init) ?? target
        return (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
    }
}
