import Foundation

public enum RunningServerKind: String, Codable, Hashable, Sendable {
    case web
    case service
}

public struct RunningServer: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let processID: Int32
    public let userID: UInt32
    public let processName: String
    public let command: String
    public let projectName: String
    public let projectPath: String
    public let host: String
    public let port: UInt16
    public let startedAt: Date
    public let kind: RunningServerKind
    public let scheme: String?

    public init(
        processID: Int32,
        userID: UInt32,
        processName: String,
        command: String,
        projectName: String,
        projectPath: String,
        host: String,
        port: UInt16,
        startedAt: Date,
        kind: RunningServerKind,
        scheme: String? = nil
    ) {
        self.id = "\(processID):\(port):\(Int(startedAt.timeIntervalSince1970))"
        self.processID = processID
        self.userID = userID
        self.processName = processName
        self.command = command
        self.projectName = projectName
        self.projectPath = projectPath
        self.host = host
        self.port = port
        self.startedAt = startedAt
        self.kind = kind
        self.scheme = scheme
    }

    public var address: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public var browserURL: URL? {
        guard kind == .web, let scheme else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = Int(port)
        return components.url
    }

    public func hasSameProcessIdentity(as other: RunningServer) -> Bool {
        processID == other.processID
            && userID == other.userID
            && startedAt == other.startedAt
            && processName == other.processName
            && command == other.command
            && projectPath == other.projectPath
    }
}
