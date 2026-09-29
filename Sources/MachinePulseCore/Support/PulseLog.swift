import os

/// Unified-log categories. Logs stay on the Mac in the system log; MachinePulse
/// sends no telemetry anywhere.
public enum PulseLog {
    static let subsystem = "com.davidweiszfeld.MachinePulse"

    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
    public static let collection = Logger(subsystem: subsystem, category: "collection")
    public static let servers = Logger(subsystem: subsystem, category: "servers")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
