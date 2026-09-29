import Foundation
import Testing
@testable import MachinePulseCore

struct DiscoveryTests {
    @Test func decodesTailnetDevices() throws {
        let url = try #require(Bundle.module.url(forResource: "tailscale-status", withExtension: "json"))
        let devices = try TailscaleDiscovery.decodeStatus(Data(contentsOf: url))

        #expect(devices.map(\.name) == ["Example Mac", "example-vps", "nas", "Pixel", "old-laptop"])
        #expect(devices.map(\.connection) == [.local, .direct, .relay, .idle, .offline])
        #expect(devices.map(\.platform) == [.macOS, .linux, .linux, .android, .windows])
        #expect(devices[0].isLocal)
        let vps = try #require(devices.first(where: { $0.id == "vps-id" }))
        #expect(vps.addresses.first == "100.64.0.10")
        #expect(vps.dnsName == "example-vps.example.ts.net")
        #expect(vps.lastSeen.map(ISO8601DateFormatter().string(from:)) == "2026-08-07T12:34:56Z")
        #expect(devices[2].lastSeen == nil)
        #expect(devices[3].dnsName == nil)
        #expect(devices[4].lastSeen.map(ISO8601DateFormatter().string(from:)) == "2026-08-01T08:00:00Z")
    }

    @Test func aStoppedBackendIsAnErrorNotAnEmptyTailnet() {
        #expect(throws: TailscaleDiscoveryError.self) {
            try TailscaleDiscovery.decodeStatus(Data(#"{"BackendState": "Stopped"}"#.utf8))
        }
    }

    @Test func parsesOnlyLiteralSSHHostAliases() {
        let config = """
            Host example-vps backup
              HostName 100.64.0.10
            Host *.example.com
              User ubuntu
            Host !blocked wildcard?
            """
        #expect(SSHConfigResolver.parseLiteralAliases(config) == ["backup", "example-vps"])
    }
}
