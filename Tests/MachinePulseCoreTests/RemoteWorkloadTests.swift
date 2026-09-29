import Foundation
import Testing
@testable import MachinePulseCore

struct RemoteWorkloadTests {
    @Test func wildcardWebListenerUsesTheMachinesTailnetName() throws {
        let device = MachineDevice(
            id: "machine",
            name: "machine",
            dnsName: "machine.example.ts.net.",
            addresses: ["100.64.0.10"],
            platform: .linux,
            isOnline: true
        )
        let workload = RemoteWorkloadMetric(
            id: "dashboard.service",
            name: "dashboard.service",
            state: .active,
            listeners: [
                WorkloadListenerMetric(
                    address: "0.0.0.0",
                    port: 8_443,
                    binding: .allInterfaces,
                    webProtocol: .https
                )
            ]
        )
        #expect(workload.browserURL(for: device)?.absoluteString == "https://machine.example.ts.net:8443")
    }

    @Test func explicitTailnetAndPublicWebListenersRemainConcrete() throws {
        let device = MachineDevice(
            id: "machine",
            name: "machine",
            platform: .linux,
            isOnline: true
        )
        let tailnet = RemoteWorkloadMetric(
            id: "tailnet",
            name: "tailnet",
            state: .active,
            listeners: [
                WorkloadListenerMetric(
                    address: "127.0.0.1",
                    port: 3_000,
                    binding: .loopback,
                    webProtocol: .http
                ),
                WorkloadListenerMetric(
                    address: "100.64.0.10",
                    port: 8_000,
                    binding: .tailnet,
                    webProtocol: .http
                ),
            ]
        )
        let publicWeb = RemoteWorkloadMetric(
            id: "public",
            name: "public",
            state: .active,
            listeners: [
                WorkloadListenerMetric(
                    address: "203.0.113.10",
                    port: 443,
                    binding: .publicAddress,
                    webProtocol: .https
                )
            ]
        )
        #expect(tailnet.browserURL(for: device)?.absoluteString == "http://100.64.0.10:8000")
        #expect(publicWeb.browserURL(for: device)?.absoluteString == "https://203.0.113.10:443")
    }

    @Test func loopbackPrivateAndNonWebListenersAreNeverOpened() {
        let device = MachineDevice(
            id: "machine",
            name: "machine",
            dnsName: "machine.example.ts.net",
            platform: .linux,
            isOnline: true
        )
        for listener in [
            WorkloadListenerMetric(
                address: "127.0.0.1", port: 8_000, binding: .loopback, webProtocol: .http),
            WorkloadListenerMetric(
                address: "10.0.0.5", port: 8_000, binding: .privateNetwork, webProtocol: .http),
            WorkloadListenerMetric(address: "100.64.0.10", port: 5_432, binding: .tailnet),
        ] {
            let workload = RemoteWorkloadMetric(
                id: listener.id,
                name: "example",
                state: .active,
                listeners: [listener]
            )
            #expect(workload.browserURL(for: device) == nil)
        }
    }

    @Test func staleWorkloadEvidenceDoesNotOpenWhenTheMachineIsOffline() {
        let device = MachineDevice(
            id: "machine",
            name: "machine",
            dnsName: "machine.example.ts.net",
            platform: .linux,
            isOnline: false
        )
        let workload = RemoteWorkloadMetric(
            id: "web",
            name: "web",
            state: .active,
            listeners: [
                WorkloadListenerMetric(
                    address: "0.0.0.0",
                    port: 443,
                    binding: .allInterfaces,
                    webProtocol: .https
                )
            ]
        )
        #expect(workload.browserURL(for: device) == nil)
    }

    @Test func legacySamplesDecodeWithoutRemoteWorkloadData() throws {
        let sample = MetricSample(
            deviceID: "machine",
            hostname: "machine",
            uptimeSeconds: 1,
            cpuPercent: 1,
            logicalCPUCount: 1,
            loadAverage1: 0,
            loadAverage5: 0,
            loadAverage15: 0,
            memoryTotalBytes: 1,
            memoryAvailableBytes: 1,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            diskTotalBytes: 1,
            diskUsedBytes: 0
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        object.removeValue(forKey: "remoteWorkloads")
        object.removeValue(forKey: "workloadResourceControls")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MetricSample.self, from: legacyData)
        #expect(decoded.remoteWorkloads == nil)
        #expect(decoded.workloadResourceControls == nil)
    }
}
