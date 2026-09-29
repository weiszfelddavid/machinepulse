import Foundation

public protocol MetricSource: Sendable {
    var deviceID: String { get }
    func collect() async throws -> MetricSample
}

public enum MetricSourceError: LocalizedError, Sendable, Equatable {
    case sshTransport(String)
    case collectorExit(code: Int32, String)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case let .sshTransport(message): "SSH did not connect: \(message)"
        case let .collectorExit(code, message): "The metric collector exited with status \(code): \(message)"
        case let .invalidPayload(message): "The metric collector returned invalid data: \(message)"
        }
    }

    public var collectionFailure: MetricCollectionFailure {
        switch self {
        case let .sshTransport(message): .sshUnavailable(message)
        case let .collectorExit(_, message): .collectorFailed(message)
        case let .invalidPayload(message): .invalidPayload(message)
        }
    }
}
