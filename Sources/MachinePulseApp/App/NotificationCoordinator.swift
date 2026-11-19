import Foundation
import MachinePulseCore
import UserNotifications

/// Posts the machine-health and agent notifications. An agent notification
/// lives only while its session waits: an answer, the end of the session, or
/// a new launch removes it.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let agentCategory = "AGENT_ATTENTION"
    private var center: UNUserNotificationCenter { .current() }
    private var postedAgents: Set<String> = []
    private var openAgent: ((String) -> Void)?

    /// `openAgent` receives the attention ID of a clicked agent notification.
    func start(openAgent: @escaping (String) -> Void) {
        self.openAgent = openAgent
        center.delegate = self
        Task { await Self.removeLeftoverAgentNotifications() }
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
        try? await center.add(request)
    }

    /// Posts each attention once and removes the notifications of the
    /// attentions that no longer wait.
    func showAgents(_ attentions: [AgentAttention], machineNames: [String: String]) {
        let current = Set(attentions.map(\.id))
        removeAgents(postedAgents.subtracting(current))
        for attention in attentions where !postedAgents.contains(attention.id) {
            postAgent(attention, machineName: machineNames[attention.deviceID], failure: nil)
        }
        postedAgents = current
    }

    /// Replaces the notification of an attention, silently, with the reason
    /// its terminal could not be shown.
    func showAgentFailure(_ failure: String, for attention: AgentAttention, machineName: String?) {
        guard postedAgents.contains(attention.id) else { return }
        postAgent(attention, machineName: machineName, failure: failure)
    }

    func removeAllAgents() {
        removeAgents(postedAgents)
        postedAgents = []
    }

    private func postAgent(_ attention: AgentAttention, machineName: String?, failure: String?) {
        let content = UNMutableNotificationContent()
        content.title = attention.title
        content.subtitle = [attention.session.projectName, machineName].compactMap(\.self).joined(separator: " · ")
        content.body = failure ?? attention.summary
        content.sound = failure == nil ? .default : nil
        content.threadIdentifier = "agent/\(attention.deviceID)/\(attention.session.id)"
        content.categoryIdentifier = Self.agentCategory
        // The completion-handler form queues the request at once, so a removal
        // that follows it can never come first.
        center.add(UNNotificationRequest(identifier: attention.id, content: content, trigger: nil))
    }

    private func removeAgents(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
    }

    /// A notification from an earlier launch has no attention to remove it.
    private nonisolated static func removeLeftoverAgentNotifications() async {
        let center = UNUserNotificationCenter.current()
        let leftovers = await center.deliveredNotifications()
            .filter { $0.request.content.categoryIdentifier == agentCategory }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: leftovers)
    }

    /// MachinePulse is active while its popover is open; show them anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        guard
            request.content.categoryIdentifier == Self.agentCategory,
            response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await open(agentNotification: request.identifier)
    }

    private func open(agentNotification identifier: String) {
        openAgent?(identifier)
    }
}

extension AgentAttention {
    fileprivate var title: String {
        switch kind {
        case .finished: "\(session.agent.displayName) finished"
        case .needsApproval: "\(session.agent.displayName) needs approval"
        }
    }

    fileprivate var summary: String {
        switch kind {
        case let .finished(duration):
            "The task took \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))"
        case .needsApproval:
            "Blocked until you answer"
        }
    }
}
