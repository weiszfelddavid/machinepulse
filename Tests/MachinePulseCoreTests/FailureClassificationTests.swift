import Foundation
import Testing
@testable import MachinePulseCore

struct FailureClassificationTests {
    @Test func tailscaleOfflineRemainsUnreachable() {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: false,
            failure: .sshUnavailable("Connection timed out"),
            offlineMessage: "Last seen 2 hours ago"
        )
        #expect(report.state == .unreachable)
        #expect(report.issues.first?.id == "connectivity")
        #expect(report.issues.first?.kind == .connectivity)
        #expect(report.issues.first?.title == "Machine is unreachable")
        #expect(report.issues.first?.explanation == "Last seen 2 hours ago")
    }

    @Test func sshFailureWhileOnlineIsACollectionWarningNotConnectivity() {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: true,
            failure: .sshUnavailable("Permission denied (publickey).")
        )
        #expect(report.state == .warning)
        #expect(report.issues.first?.id == "metrics-collection")
        #expect(report.issues.first?.kind == .collection)
        #expect(report.issues.first?.title == "Metrics collection unavailable")
        #expect(report.issues.first?.explanation.contains("reachable through Tailscale") == true)
    }

    @Test func missingConfigurationIsACollectionWarning() {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: true,
            failure: .notConfigured("Choose an SSH target in Settings to collect Linux metrics.")
        )
        #expect(report.state == .warning)
        #expect(report.issues.first?.kind == .collection)
        #expect(report.issues.first?.title == "Metrics collection unavailable")
    }

    @Test func remoteCollectorExitIsACollectorFailureNotConnectivity() {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: true,
            failure: .collectorFailed("ValueError: invalid literal for int() with base 10: '0.4 11272'")
        )
        #expect(report.state == .warning)
        #expect(report.issues.first?.title == "Metrics collection failed")
        #expect(report.issues.first?.kind == .collection)
        #expect(!(report.issues.contains { $0.kind == .connectivity }))
    }

    @Test func invalidPayloadIsACollectorFailureNotConnectivity() {
        let report = HealthEvaluator.collectionFailure(
            deviceID: "vps",
            isReachableThroughTailscale: true,
            failure: .invalidPayload("The data couldn’t be read because it isn’t in the correct format.")
        )
        #expect(report.state == .warning)
        #expect(report.issues.first?.title == "Metrics collection failed")
        #expect(report.issues.first?.kind == .collection)
    }

    @Test func metricSourceErrorsMapToTypedCollectionFailures() {
        #expect(
            MetricCollectionFailure(error: MetricSourceError.sshTransport("Connection refused"))
                == .sshUnavailable("Connection refused"))
        #expect(
            MetricCollectionFailure(error: MetricSourceError.collectorExit(code: 1, "ValueError: bad literal"))
                == .collectorFailed("ValueError: bad literal"))
        #expect(
            MetricCollectionFailure(error: MetricSourceError.invalidPayload("missing key"))
                == .invalidPayload("missing key"))
        #expect(
            MetricCollectionFailure(error: CocoaError(.fileReadUnknown), isLocalSource: true)
                == .localCollection(FailureSanitizer.sanitize(CocoaError(.fileReadUnknown).localizedDescription)))
    }

    @Test func sanitizerReducesATracebackToItsFinalLine() {
        let traceback = """
            Traceback (most recent call last):
              File "<stdin>", line 187, in <module>
              File "<stdin>", line 178, in processes
            ValueError: invalid literal for int() with base 10: '0.4 11272'
            """
        let sanitized = FailureSanitizer.sanitize(traceback)
        #expect(sanitized == "ValueError: invalid literal for int() with base 10: '0.4 11272'")
        #expect(!(sanitized.contains("Traceback")))
        #expect(!(sanitized.contains("\n")))
    }

    @Test func sanitizerBoundsLengthAndRedactsKeyPaths() {
        let long = String(repeating: "x", count: 600)
        let sanitized = FailureSanitizer.sanitize(long)
        #expect(sanitized.count <= FailureSanitizer.maximumLength)
        #expect(sanitized.hasSuffix("…"))

        for keyError in [
            "Load key '/Users/example/.ssh/id_ed25519': Permission denied",
            "Load key '/Users/example/keys/production.pem': Permission denied",
            "Load key '/etc/keys/deploy.key': Permission denied",
            "Load key '/Users/example/backup_rsa': Permission denied",
        ] {
            let redacted = FailureSanitizer.sanitize(keyError)
            #expect(!(redacted.contains("id_ed25519")))
            #expect(!(redacted.contains("production")))
            #expect(!(redacted.contains("deploy")))
            #expect(!(redacted.contains("backup")))
            #expect(redacted.contains("(key path)"))
            #expect(redacted.contains("Permission denied"))
        }
    }

    @Test func offlineMobileDevicesStayQuietWhileServersStayUnreachable() {
        let offlinePhone = MachineDevice(
            id: "phone",
            name: "Pixel",
            platform: .android,
            isOnline: false,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let phoneReport = HealthEvaluator.presenceReport(for: offlinePhone)
        #expect(phoneReport.state == .healthy)
        #expect(phoneReport.issues.isEmpty)
        #expect(phoneReport.summary.hasPrefix("Offline"))

        let offlineTablet = MachineDevice(id: "tablet", name: "iPad", platform: .iOS, isOnline: false)
        #expect(HealthEvaluator.presenceReport(for: offlineTablet).state == .healthy)

        let offlineServer = MachineDevice(id: "server", name: "vps", platform: .linux, isOnline: false)
        let serverReport = HealthEvaluator.presenceReport(for: offlineServer)
        #expect(serverReport.state == .unreachable)
        #expect(serverReport.issues.first?.kind == .connectivity)

        let onlinePhone = MachineDevice(id: "phone", name: "Pixel", platform: .android, isOnline: true)
        #expect(HealthEvaluator.presenceReport(for: onlinePhone).summary == "Online on your tailnet")
    }
}
