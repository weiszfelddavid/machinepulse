import Foundation
import MachinePulseCore
import UserNotifications

actor NotificationCoordinator {
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
}
