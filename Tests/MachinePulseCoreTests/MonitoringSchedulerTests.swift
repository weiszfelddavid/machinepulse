import Foundation
import Testing
@testable import MachinePulseCore

struct MonitoringSchedulerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func backoffFollowsTheDocumentedScheduleAndResetsOnSuccess() {
        var scheduler = MonitoringScheduler()
        #expect(scheduler.isDue(deviceID: "vps", now: start))

        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(10))
        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(20))
        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(40))
        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(60))
        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(60))

        scheduler.reset(deviceID: "vps")
        #expect(scheduler.isDue(deviceID: "vps", now: start))
        #expect(scheduler.recordFailure(deviceID: "vps", now: start) == start.addingTimeInterval(10))
    }

    @Test func dueGatingRespectsTheScheduledAttempt() {
        var scheduler = MonitoringScheduler()
        let next = scheduler.recordFailure(deviceID: "vps", now: start)
        #expect(!(scheduler.isDue(deviceID: "vps", now: start.addingTimeInterval(9))))
        #expect(scheduler.isDue(deviceID: "vps", now: next))
        #expect(scheduler.isDue(deviceID: "other", now: start))
    }

    @Test func offlineReportIsNeededOnlyDuringBackoffWithASource() {
        var scheduler = MonitoringScheduler()
        _ = scheduler.recordFailure(deviceID: "vps", now: start)
        let during = start.addingTimeInterval(5)

        #expect(scheduler.needsOfflineReport(deviceID: "vps", isOnline: false, hasSource: true, now: during))
        #expect(!(scheduler.needsOfflineReport(deviceID: "vps", isOnline: true, hasSource: true, now: during)))
        #expect(!(scheduler.needsOfflineReport(deviceID: "vps", isOnline: false, hasSource: false, now: during)))
        #expect(
            !(scheduler.needsOfflineReport(
                deviceID: "vps", isOnline: false, hasSource: true, now: start.addingTimeInterval(10))))
    }

    @Test func desiredSourceMapsEveryConfiguration() {
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .macOS, isLocal: true, mode: .deep, sshTarget: nil, hasCollectorScript: true) == .localMac)
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .linux, isLocal: false, mode: .deep, sshTarget: "vps-alias", hasCollectorScript: true)
                == .ssh(target: "vps-alias"))
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .linux, isLocal: false, mode: .presence, sshTarget: "vps-alias", hasCollectorScript: true)
                == .presenceOnly)
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .linux, isLocal: false, mode: .deep, sshTarget: "  ", hasCollectorScript: true)
                == .unavailable(.notConfigured("Choose an SSH target in Settings to collect metrics over SSH.")))
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .linux, isLocal: false, mode: .deep, sshTarget: "vps-alias", hasCollectorScript: false)
                == .unavailable(.notConfigured("The bundled collector script is missing.")))
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .macOS, isLocal: false, mode: .deep, sshTarget: "user@laptop", hasCollectorScript: true)
                == .ssh(target: "user@laptop"))
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .macOS, isLocal: false, mode: .deep, sshTarget: nil, hasCollectorScript: true)
                == .unavailable(.notConfigured("Choose an SSH target in Settings to collect metrics over SSH.")))
        #expect(
            MonitoringScheduler.desiredSource(
                platform: .android, isLocal: false, mode: .deep, sshTarget: "phone", hasCollectorScript: true)
                == .unavailable(.notConfigured("Deep monitoring is not available for this machine.")))
    }
}
