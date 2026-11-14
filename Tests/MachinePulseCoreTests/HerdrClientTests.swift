import Testing
@testable import MachinePulseCore

struct HerdrClientTests {
    static let processList = """
          501 ttys002  herdr
          502 ??       /home/example/.local/bin/herdr server
          503 ttys003  /home/example/.local/bin/herdr --remote example@example-vps.example.ts.net
          504 ttys004  herdr session attach work
          505 ttys005  herdr agent list
          506 ttys006  -zsh
          507 ttys007  herdr --session review
        """

    @Test func windowsAreHerdrProcessesWithATerminalThatAttachToASession() {
        let clients = HerdrClient.clients(inProcessList: Self.processList)
        #expect(clients.map(\.pid) == [501, 503, 504, 507])
        #expect(clients.first { $0.pid == 503 }?.remoteTarget == "example@example-vps.example.ts.net")
        #expect(clients.first { $0.pid == 501 }?.tty == "ttys002")
    }

    @Test func aSessionOnThisMacOpensTheNewestLocalWindow() {
        let clients = HerdrClient.clients(inProcessList: Self.processList)
        #expect(HerdrClient.window(for: nil, among: clients)?.pid == 507)
    }

    @Test func aSessionOnAnotherMachinePrefersAWindowAttachedToIt() {
        let clients = HerdrClient.clients(inProcessList: Self.processList)
        #expect(HerdrClient.window(for: ["example-vps", "Example-VPS.example.ts.net"], among: clients)?.pid == 503)
        #expect(HerdrClient.window(for: ["example-nas"], among: clients)?.pid == 507)
        #expect(HerdrClient.window(for: ["example-nas"], among: []) == nil)
    }
}
