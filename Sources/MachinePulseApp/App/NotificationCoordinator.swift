import Foundation
import MachinePulseCore
import UserNotifications

actor NotificationCoordinator {
    static let agentCategory = "AGENT_SESSION"
    static let deviceIDKey = "deviceID"
    static let sessionIDKey = "sessionID"

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func postTransition(deviceName: String, old: HealthState, report: HealthReport) async {
        let content = UNMutableNotificationContent()
        content.title =
            report.state == .healthy
            ? "\(deviceName) recovered"
            : "\(deviceName): \(report.state.title)"
        content.body =
            report.state == .healthy
            ? "MachinePulse reports that the machine is healthy again."
            : report.summary
        content.sound = report.state == .critical ? .defaultCritical : .default
        content.threadIdentifier = report.deviceID
        content.categoryIdentifier = "MACHINE_HEALTH"

        let request = UNNotificationRequest(
            identifier: "\(report.deviceID)-\(report.state.rawValue)-\(Int(report.evaluatedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// One notification per session: a newer one replaces the older.
    func postAgentAttention(_ attention: AgentAttention, machineName: String?) async {
        let session = attention.session
        let content = UNMutableNotificationContent()
        switch attention.kind {
        case let .finished(duration):
            content.title = "\(session.agent.displayName) finished"
            content.body = "The task took \(Self.duration(duration)). Click to open its terminal."
        case .needsApproval:
            content.title = "\(session.agent.displayName) needs approval"
            content.body = "The session is blocked until you answer. Click to open its terminal."
        }
        content.subtitle = [session.projectName, machineName].compactMap(\.self).joined(separator: " · ")
        content.sound = .default
        content.threadIdentifier = "agents"
        content.categoryIdentifier = Self.agentCategory
        content.userInfo = [Self.deviceIDKey: attention.deviceID, Self.sessionIDKey: session.id]

        let request = UNNotificationRequest(
            identifier: "agent-\(attention.deviceID)-\(session.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Routes a click on an agent notification to the session's terminal.
final class AgentNotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let open: @MainActor (String, String) -> Void

    init(open: @escaping @MainActor (String, String) -> Void) {
        self.open = open
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard
            response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let deviceID = userInfo[NotificationCoordinator.deviceIDKey] as? String,
            let sessionID = userInfo[NotificationCoordinator.sessionIDKey] as? String
        else { return }
        await open(deviceID, sessionID)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == NotificationCoordinator.agentCategory
            ? [.banner, .list, .sound] : []
    }
}
