import Foundation
import Testing
@testable import MachinePulseCore

struct CollectorContractTests {
    @Test func parsesSingleWordCommandsWithCorrectValuesAndOrder() async throws {
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "1.5", "rss": "100", "comm": "nginx"],
                    ["pcpu": "12.5", "rss": "2048", "comm": "php-fpm"],
                    ["pcpu": "3.0", "rss": "4096", "comm": "postgres"],
                ])
            ], fakeExecutables: ["ps": Self.fakePSSource])
        #expect(output.topCPUProcesses.map(\.name) == ["php-fpm", "postgres", "nginx"])
        #expect(output.topCPUProcesses.map(\.cpuPercent) == [12.5, 3.0, 1.5])
        #expect(output.topCPUProcesses.map(\.residentBytes) == ([2048 * 1024, 4096 * 1024, 100 * 1024] as [UInt64]))
        #expect(output.topMemoryProcesses.map(\.name) == ["postgres", "php-fpm", "nginx"])
    }

    @Test func preservesMultipleInternalSpacesInCommandNames() async throws {
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "1.0", "rss": "64", "comm": "Google Chrome Helper (Renderer)"],
                    ["pcpu": "0.5", "rss": "32", "comm": "spaced  twice   thrice"],
                    ["pcpu": "0.4", "rss": "11272", "comm": "Web Content"],
                ])
            ], fakeExecutables: ["ps": Self.fakePSSource])
        #expect(
            output.topCPUProcesses.map(\.name) == [
                "Google Chrome Helper (Renderer)", "spaced  twice   thrice", "Web Content",
            ])
        #expect(output.topCPUProcesses.last?.residentBytes == 11272 * 1024)
    }

    @Test func skipsMalformedRowsWithoutInvalidatingTheSample() async throws {
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "not-a-number", "rss": "77", "comm": "broken-cpu"],
                    ["pcpu": "1.0", "rss": "0.4 11272", "comm": "broken-rss"],
                    ["pcpu": "1.0", "rss": "", "comm": "vanished mid-listing"],
                    ["pcpu": "2.5", "rss": "1024", "comm": "healthy"],
                    ["pcpu": "-4", "rss": "10", "comm": "negative-cpu"],
                ])
            ], fakeExecutables: ["ps": Self.fakePSSource])
        #expect(output.topCPUProcesses.map(\.name) == ["healthy"])
        #expect(output.topMemoryProcesses.map(\.name) == ["healthy"])
    }

    @Test func limitsToTheTopFiveValidEntriesAfterValidationAndSorting() async throws {
        // Malformed rows come first and the busiest processes come last, so a
        // parser that truncated to five raw lines before validating and sorting
        // would miss them.
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "abc", "rss": "1", "comm": "malformed-one"],
                    ["pcpu": "def", "rss": "2", "comm": "malformed-two"],
                    ["pcpu": "1.0", "rss": "10", "comm": "low-one"],
                    ["pcpu": "2.0", "rss": "20", "comm": "low-two"],
                    ["pcpu": "3.0", "rss": "30", "comm": "mid-one"],
                    ["pcpu": "4.0", "rss": "40", "comm": "mid-two"],
                    ["pcpu": "5.0", "rss": "50", "comm": "high-one"],
                    ["pcpu": "99.0", "rss": "999999", "comm": "busiest listed last"],
                ])
            ], fakeExecutables: ["ps": Self.fakePSSource])
        #expect(output.topCPUProcesses.count == 5)
        #expect(
            output.topCPUProcesses.map(\.name) == ["busiest listed last", "high-one", "mid-two", "mid-one", "low-two"])
        #expect(
            output.topMemoryProcesses.map(\.name) == [
                "busiest listed last", "high-one", "mid-two", "mid-one", "low-two",
            ])
    }

    @Test func handlesAnEmptyProcessListing() async throws {
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes", environment: ["MACHINEPULSE_FAKE_PS_ROWS": try jsonString([])],
            fakeExecutables: ["ps": Self.fakePSSource])
        #expect(output.topCPUProcesses.isEmpty)
        #expect(output.topMemoryProcesses.isEmpty)
    }

    @Test func skipsNonFiniteNumericValuesThatWouldBreakJSON() async throws {
        // float() accepts these spellings, and json.dumps would emit NaN /
        // Infinity — tokens strict JSON decoding rejects for the whole sample.
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "nan", "rss": "10", "comm": "nan-cpu"],
                    ["pcpu": "inf", "rss": "20", "comm": "inf-cpu"],
                    ["pcpu": "-inf", "rss": "30", "comm": "negative-inf-cpu"],
                    ["pcpu": "Infinity", "rss": "40", "comm": "spelled-out-inf"],
                    ["pcpu": "1.0", "rss": "50", "comm": "healthy"],
                ])
            ], fakeExecutables: ["ps": Self.fakePSSource])
        #expect(output.topCPUProcesses.map(\.name) == ["healthy"])
        #expect(output.topMemoryProcesses.map(\.name) == ["healthy"])
    }

    @Test func survivesAFailingPSExecutable() async throws {
        let output: CollectorProcessOutput = try await runCollectorMode(
            "processes", fakeExecutables: ["ps": "#!/bin/sh\nexit 1"])
        #expect(output.topCPUProcesses.isEmpty)
        #expect(output.topMemoryProcesses.isEmpty)
    }

    @Test func parsesSystemAndCgroupOOMContext() async throws {
        let baseMicroseconds: Int64 = 1_700_000_000_000_000
        let systemEntries: [[String: Any]] = [
            journalEntry(
                microseconds: baseMicroseconds,
                message: "oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=postgres,pid=91"
            ),
            journalEntry(
                microseconds: baseMicroseconds + 500_000,
                message: "Out of memory: Killed process 91 (postgres) total-vm:1000kB"
            ),
        ]
        let systemEvents: [OOMEventMetric] = try await runCollectorMode(
            "oom-parse",
            environment: ["MACHINEPULSE_FAKE_JOURNAL_ENTRIES": jsonString(systemEntries)]
        )
        #expect(systemEvents.count == 1)
        #expect(systemEvents.first?.constraint == .system)
        #expect(systemEvents.first?.victimProcess == "postgres")
        #expect(systemEvents.first?.processID == 91)

        let cgroupEntries: [[String: Any]] = [
            journalEntry(
                microseconds: baseMicroseconds,
                message: "memory: usage 524288kB, limit 524288kB, failcnt 1"
            ),
            journalEntry(
                microseconds: baseMicroseconds + 200_000,
                message:
                    "oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),task_memcg=/system.slice/worker.service,task=php,pid=42"
            ),
            journalEntry(
                microseconds: baseMicroseconds + 400_000,
                message: "Memory cgroup out of memory: Killed process 42 (php) total-vm:1000kB"
            ),
        ]
        let cgroupEvents: [OOMEventMetric] = try await runCollectorMode(
            "oom-parse",
            environment: ["MACHINEPULSE_FAKE_JOURNAL_ENTRIES": jsonString(cgroupEntries)]
        )
        let cgroup = try #require(cgroupEvents.first)
        #expect(cgroup.constraint == .cgroup)
        #expect(cgroup.cgroup == "/system.slice/worker.service")
        #expect(cgroup.memoryUsageBytes == 524_288 * 1_024)
        #expect(cgroup.memoryLimitBytes == 524_288 * 1_024)
    }

    @Test func malformedAndMissingOOMRowsStayBoundedAndDecodable() async throws {
        let events: [OOMEventMetric] = try await runCollectorMode(
            "oom-parse",
            environment: [
                "MACHINEPULSE_FAKE_JOURNAL_ENTRIES": jsonString([
                    ["MESSAGE": "Killed process without usable fields"],
                    ["__REALTIME_TIMESTAMP": "bad", "MESSAGE": "Killed process 1 (bad)"],
                    journalEntry(microseconds: 1_700_000_000_000_000, message: "ordinary kernel message"),
                ])
            ]
        )
        #expect(events.isEmpty)
    }

    @Test func unavailableOOMJournalIsExplicitWhileNoOOMIsAvailable() async throws {
        let unavailable: OOMDriverOutput = try await runCollectorMode(
            "oom-events",
            fakeExecutables: ["journalctl": "#!/bin/sh\nexit 1\n"]
        )
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.event == nil)

        let empty: OOMDriverOutput = try await runCollectorMode(
            "oom-events",
            fakeExecutables: ["journalctl": "#!/bin/sh\nexit 0\n"]
        )
        #expect(empty.status == .available)
        #expect(empty.count == 0)
        #expect(empty.event == nil)
    }

    @Test func diskScanMeasuresAFixtureTreeOnceAndJudgesFindings() async throws {
        let mib = 1 << 20
        let snapshot: DiskScanSnapshot = try await runCollectorMode(
            "disk-scan",
            environment: [
                "MACHINEPULSE_DISK_ROOT": "%WORKSPACE%/home",
                "MACHINEPULSE_DISK_OPTIONS": try jsonString([
                    "retainFloorBytes": 64 * 1_024, "findingFloorBytes": mib, "now": 1_800_000_000,
                ]),
            ],
            fixtureFiles: [
                "home/src/app/Cargo.toml": String(repeating: "x", count: 100),
                "home/Cargo.toml": String(repeating: "x", count: 100),
                "home/target/root.bin": String(repeating: "x", count: mib),
                "home/src/app/target/big.bin": String(repeating: "x", count: 2 * mib),
                "home/.cache/blob.bin": String(repeating: "x", count: 3 * mib),
                "home/Documents/doc.pdf": String(repeating: "x", count: mib),
                "home/Downloads/.keep": "",
            ],
            prepare: { workspace in
                let home = workspace.appendingPathComponent("home")
                #expect(
                    link(
                        home.appendingPathComponent("Documents/doc.pdf").path,
                        home.appendingPathComponent("Documents/copy.pdf").path) == 0)
                try FileManager.default.createSymbolicLink(
                    at: home.appendingPathComponent("link"),
                    withDestinationURL: home.appendingPathComponent("src"))
                let locked = home.appendingPathComponent("Library/Mail")
                try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                try Data(repeating: 0x61, count: 4_096).write(to: locked.appendingPathComponent("secret"))
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            }
        )
        #expect(snapshot.scannerVersion == "mac-agentless-disk-v1")
        #expect(snapshot.root.directories == 9)
        #expect(snapshot.root.files == 9)
        #expect(snapshot.unreadableCount == 1)
        #expect(snapshot.root.bytes > UInt64(7 * mib))
        #expect(snapshot.root.bytes < UInt64(7 * mib) + 512 * 1_024)
        #expect(snapshot.volume != nil)
        #expect(snapshot.findings.map(\.path) == [".cache", "src/app/target", "target"])
        #expect(snapshot.findings.map(\.reclaim) == [.regenerable, .buildOutput, .buildOutput])
        let target = try #require(snapshot.root.child(named: "src")?.child(named: "app")?.child(named: "target"))
        #expect(target.reclaim == .buildOutput)
        #expect(target.kind == .code)
        #expect(target.children.map(\.name) == ["big.bin"])
        #expect(snapshot.root.child(named: ".cache")?.kind == .cache)
        #expect(snapshot.root.child(named: "link") == nil)
        #expect(snapshot.root.child(named: "Downloads") == nil)
    }

    @Test func diskClassificationTablesMatchTheSwiftClassifier() async throws {
        let tables: DiskTablesDriverOutput = try await runCollectorMode("disk-tables")
        #expect(tables.kinds == DiskClassifier.kindNames)
        #expect(tables.reclaims == DiskClassifier.reclaimNames)
    }

    @Test func macSnapshotReadsSystemToolsIntoTheSharedContract() async throws {
        let snapshot: CollectorSnapshot = try await runCollectorMode(
            "darwin-snapshot",
            environment: [
                "MACHINEPULSE_FAKE_PS_ROWS": try jsonString([
                    ["pcpu": "12.5", "rss": "2048", "comm": "/System/Library/CoreServices/WindowServer"],
                    [
                        "pcpu": "1.0", "rss": "4096",
                        "comm": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    ],
                ])
            ],
            fakeExecutables: [
                "ps": Self.fakePSSource,
                "sysctl": Self.fakeDarwinSysctlSource,
                "vm_stat": Self.fakeDarwinVMStatSource,
                "netstat": Self.fakeDarwinNetstatSource,
                "ioreg": Self.fakeDarwinIORegSource,
            ]
        )
        #expect(snapshot.collectorVersion == "mac-agentless-v1")
        #expect(snapshot.logicalCPUCount == 8)
        #expect(snapshot.bootID == "0BADC0DE-0000-4000-8000-000000000001")
        #expect(snapshot.uptimeSeconds > 0)
        #expect(snapshot.cpuPercent.isFinite && snapshot.cpuPercent >= 0)
        #expect(snapshot.memoryTotalBytes == 17_179_869_184)
        #expect(snapshot.memoryAvailableBytes == (100_000 + 50_000) * 16_384)
        #expect(snapshot.swapTotalBytes == 2_048 * 1_048_576)
        #expect(snapshot.swapUsedBytes == UInt64(512.5 * 1_048_576))
        #expect(snapshot.swapInBytesTotal == 1_000 * 16_384)
        #expect(snapshot.swapOutBytesTotal == 2_000 * 16_384)
        #expect(snapshot.memoryPressureLevel == .warning)
        #expect(snapshot.networkReceiveBytesTotal == 102_000)
        #expect(snapshot.networkTransmitBytesTotal == 41_000)
        #expect(snapshot.diskReadBytesTotal == 5_000_001)
        #expect(snapshot.diskWriteBytesTotal == 3_000_002)
        #expect(snapshot.diskTotalBytes > 0)
        #expect(snapshot.topCPUProcesses.map(\.name) == ["WindowServer", "Google Chrome"])
        #expect(snapshot.topMemoryProcesses.first?.name == "Google Chrome")
        #expect(snapshot.failedServices.isEmpty)
        #expect(snapshot.remoteWorkloads == nil)
        #expect(snapshot.cpuPressure == nil)
        #expect(snapshot.oomKillCount == 0)
        #expect(snapshot.oomCollectionStatus == nil)
        #expect(snapshot.rootFilesystemID?.hasPrefix("dev:") == true)
    }

    @Test func macSnapshotStaysDecodableWhenSystemToolsFail() async throws {
        let snapshot: CollectorSnapshot = try await runCollectorMode(
            "darwin-snapshot",
            fakeExecutables: [
                "ps": "#!/bin/sh\nexit 1\n",
                "sysctl": "#!/bin/sh\necho 'hw.ncpu: 4'\nexit 1\n",
                "vm_stat": "#!/bin/sh\nexit 0\n",
                "netstat": "#!/bin/sh\nexit 1\n",
                "ioreg": "#!/bin/sh\necho 'not a plist'\n",
            ]
        )
        #expect(snapshot.logicalCPUCount == 4)
        #expect(snapshot.memoryTotalBytes == 0)
        #expect(snapshot.memoryAvailableBytes == 0)
        #expect(snapshot.swapTotalBytes == 0)
        #expect(snapshot.networkReceiveBytesTotal == 0)
        #expect(snapshot.diskReadBytesTotal == 0)
        #expect(snapshot.uptimeSeconds == 0)
        #expect(snapshot.memoryPressureLevel == nil)
        #expect(snapshot.bootID == nil)
        #expect(snapshot.topCPUProcesses.isEmpty)
    }

    @Test func journalIsReadOnlyWhenTheKernelKillCounterMarkChanges() async throws {
        let vmstat = ["proc/vmstat": "nr_free_pages 1024\noom_kill 7\n"]
        let readableJournal = ["journalctl": "#!/bin/sh\nexit 0\n"]
        let brokenJournal = ["journalctl": "#!/bin/sh\nexit 1\n"]

        let first: OOMContextDriverOutput = try await runCollectorMode(
            "oom-context",
            environment: ["MACHINEPULSE_FAKE_BOOT_ID": "boot-1"],
            fakeExecutables: readableJournal,
            fixtureFiles: vmstat
        )
        #expect(first.mark == "boot-1:7")
        #expect(first.oomEvidenceUnchanged == false)
        #expect(first.oomCollectionStatus == .available)

        // The journal would fail here, so unchanged evidence proves it was not read.
        let unchanged: OOMContextDriverOutput = try await runCollectorMode(
            "oom-context",
            environment: ["MACHINEPULSE_FAKE_BOOT_ID": "boot-1", "MACHINEPULSE_OOM_KILL_MARK": "boot-1:7"],
            fakeExecutables: brokenJournal,
            fixtureFiles: vmstat
        )
        #expect(unchanged.mark == "boot-1:7")
        #expect(unchanged.oomEvidenceUnchanged == true)
        #expect(unchanged.oomCollectionStatus == nil)
        #expect(unchanged.oomKillCount == 0)

        let newKill: OOMContextDriverOutput = try await runCollectorMode(
            "oom-context",
            environment: ["MACHINEPULSE_FAKE_BOOT_ID": "boot-1", "MACHINEPULSE_OOM_KILL_MARK": "boot-1:6"],
            fakeExecutables: brokenJournal,
            fixtureFiles: vmstat
        )
        #expect(newKill.oomEvidenceUnchanged == false)
        #expect(newKill.oomCollectionStatus == .unavailable)

        let rebooted: OOMContextDriverOutput = try await runCollectorMode(
            "oom-context",
            environment: ["MACHINEPULSE_FAKE_BOOT_ID": "boot-2", "MACHINEPULSE_OOM_KILL_MARK": "boot-1:7"],
            fakeExecutables: readableJournal,
            fixtureFiles: vmstat
        )
        #expect(rebooted.mark == "boot-2:7")
        #expect(rebooted.oomEvidenceUnchanged == false)

        let withoutCounter: OOMContextDriverOutput = try await runCollectorMode(
            "oom-context",
            environment: ["MACHINEPULSE_FAKE_BOOT_ID": "boot-1", "MACHINEPULSE_OOM_KILL_MARK": "boot-1:7"],
            fakeExecutables: readableJournal,
            fixtureFiles: ["proc/vmstat": "nr_free_pages 1024\n"]
        )
        #expect(withoutCounter.mark == nil)
        #expect(withoutCounter.oomEvidenceUnchanged == false)
        #expect(withoutCounter.oomCollectionStatus == .available)
    }

    @Test func collectsExplicitExpectedServicesAndTimers() async throws {
        let specifications = [
            try #require(ExpectedSystemdUnit(name: "api.service")),
            try #require(ExpectedSystemdUnit(name: "backup.timer")),
            try #require(ExpectedSystemdUnit(name: "worker.service")),
            try #require(ExpectedSystemdUnit(name: "broken.service")),
            try #require(ExpectedSystemdUnit(name: "missing.timer")),
        ]
        let output = """
            Id=api.service
            LoadState=loaded
            ActiveState=active
            SubState=running

            Id=backup.timer
            LoadState=loaded
            ActiveState=active
            SubState=waiting

            Id=worker.service
            LoadState=loaded
            ActiveState=inactive
            SubState=dead

            Id=broken.service
            LoadState=loaded
            ActiveState=failed
            SubState=failed

            Id=missing.timer
            LoadState=not-found
            ActiveState=inactive
            SubState=dead
            """
        let encoded = try JSONEncoder().encode(specifications).base64EncodedString()
        let result: ExpectedUnitDriverOutput = try await runCollectorMode(
            "expected-units",
            environment: [
                "MACHINEPULSE_EXPECTED_UNITS_B64": encoded,
                "MACHINEPULSE_FAKE_SYSTEMCTL_OUTPUT": output,
            ],
            fakeExecutables: ["systemctl": Self.fakeSystemctlSource]
        )
        let units = try #require(result.units)
        #expect(units.map(\.state) == [.active, .active, .inactive, .failed, .missing])
        #expect(units[1].kind == .timer)
        #expect(units[1].substate == "waiting")
    }

    @Test func expectedUnitCollectionFailureDoesNotCreateMissingUnits() async throws {
        let specification = try #require(ExpectedSystemdUnit(name: "api.service"))
        let encoded = try JSONEncoder().encode([specification]).base64EncodedString()
        let result: ExpectedUnitDriverOutput = try await runCollectorMode(
            "expected-units",
            environment: ["MACHINEPULSE_EXPECTED_UNITS_B64": encoded],
            fakeExecutables: ["systemctl": "#!/bin/sh\nexit 1\n"]
        )
        #expect(result.units == nil)
    }

    @Test func validatesExpectedUnitNamesAndTypes() {
        #expect(ExpectedSystemdUnit(name: "api@blue.service") != nil)
        #expect(ExpectedSystemdUnit(name: "backup.timer") != nil)
        #expect(ExpectedSystemdUnit(name: "api") == nil)
        #expect(ExpectedSystemdUnit(name: "../../api.service") == nil)
        #expect(ExpectedSystemdUnit(name: "api service.service") == nil)
    }

    @Test func groupsSystemdWebListenersAndClassifiesTheirBindings() async throws {
        let output: RemoteWorkloadDriverOutput = try await runCollectorMode(
            "workloads-parse",
            environment: [
                "MACHINEPULSE_FAKE_SS_OUTPUT": """
                LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=101,fd=7))
                LISTEN 0 128 100.64.0.10:8000 0.0.0.0:* users:((\"nginx\",pid=101,fd=8))
                LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))
                LISTEN 0 128 100.64.0.10:8443 0.0.0.0:* users:((\"tailscaled\",pid=2,fd=4))
                """,
                "MACHINEPULSE_FAKE_UNIT_MAP": try jsonString([
                    "2": "tailscaled.service", "101": "dashboard.service",
                ]),
                "MACHINEPULSE_FAKE_UPTIME_MAP": try jsonString(["101": 3_600]),
            ]
        )
        let workload = try #require(output.workloads.first)
        #expect(output.workloads.count == 1)
        #expect(workload.id == "dashboard.service")
        #expect(workload.systemdUnit == "dashboard.service")
        #expect(workload.processName == "nginx")
        #expect(workload.uptimeSeconds == 3_600)
        #expect(workload.listeners.map(\.binding) == [.allInterfaces, .tailnet])
        #expect(workload.listeners.map(\.webProtocol) == [.https, .http])
    }

    @Test func preservesLoopbackAndAmbiguousListenersWithoutInventingURLs() async throws {
        let output: RemoteWorkloadDriverOutput = try await runCollectorMode(
            "workloads-parse",
            environment: [
                "MACHINEPULSE_FAKE_SS_OUTPUT": """
                LISTEN 0 128 127.0.0.1:5432 0.0.0.0:* users:((\"postgres\",pid=202,fd=5))
                LISTEN 0 128 127.0.0.1:9090 0.0.0.0:*
                """,
                "MACHINEPULSE_FAKE_UNIT_MAP": try jsonString(["202": "postgresql.service"]),
            ]
        )
        #expect(output.workloads.count == 2)
        #expect(output.workloads.allSatisfy { $0.listeners.first?.binding == .loopback })
        #expect(output.workloads.allSatisfy { $0.listeners.first?.webProtocol == nil })
        #expect(output.workloads.contains { $0.name == "Listener on port 9090" })
    }

    @Test func expectedServicesJoinTheInventoryWhileTimersStayOut() async throws {
        let expected: [[String: String]] = [
            ["name": "worker.service", "kind": "service", "state": "active", "substate": "running"],
            ["name": "backup.timer", "kind": "timer", "state": "active", "substate": "waiting"],
        ]
        let output: RemoteWorkloadDriverOutput = try await runCollectorMode(
            "workloads-parse",
            environment: ["MACHINEPULSE_FAKE_EXPECTED_METRICS": try jsonString(expected)]
        )
        #expect(output.workloads.map(\.name) == ["worker.service"])
        #expect(output.workloads.first?.state == .active)
        #expect(output.workloads.first?.listeners.isEmpty == true)
    }

    @Test func emptyWorkloadEvidenceProducesAnEmptyBoundedInventory() async throws {
        let output: RemoteWorkloadDriverOutput = try await runCollectorMode("workloads-parse")
        #expect(output.workloads.isEmpty)
    }

    @Test func workloadInventoryAndPerWorkloadListenersStayBounded() async throws {
        var lines: [String] = []
        var units: [String: String] = [:]
        for index in 0..<24 {
            let pid = 1_000 + index
            units[String(pid)] = "example-\(index).service"
            lines.append(
                "LISTEN 0 128 127.0.0.1:\(10_000 + index) 0.0.0.0:* users:((\"worker\",pid=\(pid),fd=3))"
            )
        }
        for index in 0..<8 {
            lines.append(
                "LISTEN 0 128 127.0.0.1:\(20_000 + index) 0.0.0.0:* users:((\"worker\",pid=1000,fd=\(index + 4)))"
            )
        }
        let output: RemoteWorkloadDriverOutput = try await runCollectorMode(
            "workloads-parse",
            environment: [
                "MACHINEPULSE_FAKE_SS_OUTPUT": lines.joined(separator: "\n"),
                "MACHINEPULSE_FAKE_UNIT_MAP": try jsonString(units),
            ]
        )
        #expect(output.workloads.count == 16)
        #expect(output.workloads.allSatisfy { $0.listeners.count <= 4 })
    }

    @Test func collectsConfiguredCgroupV2ControlsAndCumulativeEvidence() async throws {
        let output: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "api.service",
                    "systemdUnit": "api.service",
                    "cgroupPath": "/system.slice/api.service",
                ])
            ],
            fixtureFiles: configuredCgroupFiles(prefix: "cgroup/system.slice/api.service")
        )
        let control = output.control
        #expect(control.availability == .available)
        #expect(control.id == "/system.slice/api.service")
        #expect(control.memoryCurrentBytes.value == 400_000_000)
        #expect(control.memoryPeakBytes.value == 600_000_000)
        #expect(control.memoryHigh.state == .configured)
        #expect(control.memoryHigh.value == 800_000_000)
        #expect(control.memoryMax.value == 1_000_000_000)
        #expect(control.memoryEvents.high.value == 3)
        #expect(control.memoryEvents.oomKill.value == 1)
        #expect(control.cpuQuota.state == .configured)
        #expect(control.cpuQuota.quotaMicroseconds == 200_000)
        #expect(control.cpuQuota.periodMicroseconds == 100_000)
        #expect(control.cpuStat.throttledPeriods.value == 4)
        #expect(control.cpuStat.throttledMicroseconds.value == 1_250_000)
        #expect(control.ioWeight.value == 100)
        #expect(control.ioPressure.someAverage10 == 2.5)
        #expect(control.ioPressure.fullAverage10 == 0.5)
        #expect(control.tasksCurrent.value == 12)
        #expect(control.tasksMax.value == 512)
    }

    @Test func preservesUnlimitedControlsInsteadOfInventingNumericLimits() async throws {
        var files = configuredCgroupFiles(prefix: "cgroup/system.slice/worker.service")
        files["cgroup/system.slice/worker.service/memory.high"] = "max\n"
        files["cgroup/system.slice/worker.service/memory.max"] = "max\n"
        files["cgroup/system.slice/worker.service/cpu.max"] = "max 100000\n"
        files["cgroup/system.slice/worker.service/pids.max"] = "max\n"
        let output: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "worker.service",
                    "systemdUnit": "worker.service",
                    "cgroupPath": "/system.slice/worker.service",
                ])
            ],
            fixtureFiles: files
        )
        #expect(output.control.memoryHigh.state == .unlimited)
        #expect(output.control.memoryHigh.value == nil)
        #expect(output.control.memoryMax.state == .unlimited)
        #expect(output.control.cpuQuota.state == .unlimited)
        #expect(output.control.cpuQuota.quotaMicroseconds == nil)
        #expect(output.control.cpuQuota.periodMicroseconds == 100_000)
        #expect(output.control.tasksMax.state == .unlimited)
    }

    @Test func browserScopeIdentityAndMissingControllersRemainExplicit() async throws {
        let scope = "/user.slice/user-1000.slice/app.slice/example-browser.scope"
        let output: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "chromium",
                    "systemdUnit": "example-browser.scope",
                    "cgroupPath": scope,
                ])
            ],
            fixtureFiles: ["cgroup/cgroup.controllers": "cpu io memory pids\n"]
        )
        #expect(output.control.name == "chromium")
        #expect(output.control.systemdUnit == "example-browser.scope")
        #expect(output.control.cgroupPath == scope)
        #expect(output.control.availability == .unavailable)

        let unsupported: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "legacy.service",
                    "systemdUnit": "legacy.service",
                    "cgroupPath": "/system.slice/legacy.service",
                ])
            ]
        )
        #expect(unsupported.control.availability == .unsupported)
        #expect(unsupported.control.memoryMax.state == .unsupported)
        #expect(unsupported.control.ioPressure.availability == .unsupported)
    }

    @Test func permissionFailureAndTraversalDoNotEscapeTheBoundedCgroupReader() async throws {
        let prefix = "cgroup/system.slice/api.service"
        let permissionDenied: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "api.service",
                    "systemdUnit": "api.service",
                    "cgroupPath": "/system.slice/api.service",
                ]),
                "MACHINEPULSE_FAKE_DENIED_CGROUP_FILE": "memory.current",
            ],
            fixtureFiles: configuredCgroupFiles(prefix: prefix)
        )
        #expect(permissionDenied.control.availability == .available)
        #expect(permissionDenied.control.memoryCurrentBytes.availability == .unavailable)
        #expect(permissionDenied.control.memoryCurrentBytes.value == nil)

        let traversal: ResourceControlDriverOutput = try await runCollectorMode(
            "resource-control",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_CANDIDATE": try jsonString([
                    "name": "escape.service",
                    "systemdUnit": "escape.service",
                    "cgroupPath": "/../etc",
                ])
            ],
            fixtureFiles: ["cgroup/cgroup.controllers": "cpu io memory pids\n"]
        )
        #expect(traversal.control.availability == .unavailable)
    }

    @Test func selectsOnlyBoundedRelevantServicesAgentsAndBrowserScopes() async throws {
        var workloads: [[String: String]] = []
        var controlGroups: [String: String] = [:]
        for index in 0..<24 {
            let unit = "service-\(index).service"
            workloads.append(["name": unit, "systemdUnit": unit])
            controlGroups[unit] = "/system.slice/\(unit)"
        }
        let processCandidates: [[String: String]] = [
            [
                "name": "chromium",
                "systemdUnit": "example-browser.scope",
                "cgroupPath": "/user.slice/example-browser.scope",
            ],
            [
                "name": "php",
                "systemdUnit": "session-13.scope",
                "cgroupPath": "/user.slice/session-13.scope",
            ],
        ]
        let bounded: ResourceCandidatesDriverOutput = try await runCollectorMode(
            "resource-candidates",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_WORKLOADS": try jsonString(workloads),
                "MACHINEPULSE_FAKE_RESOURCE_PROCESSES": try jsonString(processCandidates),
                "MACHINEPULSE_FAKE_CONTROL_GROUPS": try jsonString(controlGroups),
            ]
        )
        #expect(bounded.candidates.count == 16)
        #expect(bounded.candidates.contains { $0.name == "chromium" })

        let scoped: ResourceCandidatesDriverOutput = try await runCollectorMode(
            "resource-candidates",
            environment: [
                "MACHINEPULSE_FAKE_RESOURCE_PROCESSES": try jsonString(processCandidates),
                "MACHINEPULSE_FAKE_CONTROL_GROUPS": "{}",
            ]
        )
        #expect(scoped.candidates.count == 1)
        #expect(scoped.candidates.first?.name == "chromium")
        #expect(scoped.candidates.first?.systemdUnit == "example-browser.scope")
    }

    // MARK: - Harness

    private struct CollectorProcessOutput: Decodable {
        let topCPUProcesses: [ProcessMetric]
        let topMemoryProcesses: [ProcessMetric]
    }

    private struct OOMDriverOutput: Decodable {
        let count: Int
        let event: OOMEventMetric?
        let status: OOMCollectionStatus
    }

    private struct OOMContextDriverOutput: Decodable {
        let mark: String?
        let oomKillCount: Int
        let oomCollectionStatus: OOMCollectionStatus?
        let oomEvidenceUnchanged: Bool
    }

    private struct ExpectedUnitDriverOutput: Decodable {
        let units: [ExpectedUnitMetric]?
    }

    private struct RemoteWorkloadDriverOutput: Decodable {
        let workloads: [RemoteWorkloadMetric]
    }

    private struct ResourceControlDriverOutput: Decodable {
        let control: WorkloadResourceControlMetric
    }

    private struct ResourceCandidatesDriverOutput: Decodable {
        let candidates: [ResourceCandidate]
    }

    private struct DiskTablesDriverOutput: Decodable {
        let kinds: [String: DiskKind]
        let reclaims: [String: DiskReclaimReason]
    }

    private struct ResourceCandidate: Decodable {
        let name: String
        let systemdUnit: String?
        let cgroupPath: String?
    }

    private func runCollectorMode<Output: Decodable>(
        _ mode: String,
        environment: [String: String] = [:],
        fakeExecutables: [String: String] = [:],
        fixtureFiles: [String: String] = [:],
        prepare: ((URL) throws -> Void)? = nil
    ) async throws -> Output {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachinePulseCollectorMode-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let collectorURL = workspace.appendingPathComponent("collector.py")
        try extractEmbeddedPython().write(to: collectorURL, atomically: true, encoding: .utf8)
        let driverURL = workspace.appendingPathComponent("driver.py")
        try Self.driverSource.write(to: driverURL, atomically: true, encoding: .utf8)
        for (name, source) in fakeExecutables {
            let url = binDirectory.appendingPathComponent(name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for (relativePath, contents) in fixtureFiles {
            let url = workspace.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try prepare?(workspace)

        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        var commandEnvironment = environment.mapValues {
            $0.replacingOccurrences(of: "%WORKSPACE%", with: workspace.path)
        }
        commandEnvironment["PATH"] = "\(binDirectory.path):\(currentPath)"
        commandEnvironment["MACHINEPULSE_TEST_MODE"] = mode
        commandEnvironment["MACHINEPULSE_TEST_WORKSPACE"] = workspace.path
        let result = try await CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["python3", driverURL.path, collectorURL.path],
            environment: commandEnvironment
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Output.self, from: result.standardOutput)
    }

    private func journalEntry(microseconds: Int64, message: String) -> [String: Any] {
        ["__REALTIME_TIMESTAMP": String(microseconds), "MESSAGE": message]
    }

    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func configuredCgroupFiles(prefix: String) -> [String: String] {
        [
            "cgroup/cgroup.controllers": "cpu io memory pids\n",
            "\(prefix)/memory.current": "400000000\n",
            "\(prefix)/memory.peak": "600000000\n",
            "\(prefix)/memory.high": "800000000\n",
            "\(prefix)/memory.max": "1000000000\n",
            "\(prefix)/memory.events": "low 0\nhigh 3\nmax 2\noom 1\noom_kill 1\n",
            "\(prefix)/cpu.max": "200000 100000\n",
            "\(prefix)/cpu.weight": "100\n",
            "\(prefix)/cpu.stat":
                "usage_usec 82000000\nuser_usec 61000000\nsystem_usec 21000000\nnr_periods 4200\nnr_throttled 4\nthrottled_usec 1250000\n",
            "\(prefix)/io.weight": "default 100\n8:0 200\n",
            "\(prefix)/io.pressure":
                "some avg10=2.50 avg60=1.00 avg300=0.50 total=100\nfull avg10=0.50 avg60=0.10 avg300=0.05 total=20\n",
            "\(prefix)/pids.current": "12\n",
            "\(prefix)/pids.max": "512\n",
        ]
    }

    private func extractEmbeddedPython() throws -> String {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MachinePulseApp/Resources/collector.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let openingMarker = "<<'PY'\n"
        let closingMarker = "\nPY"
        let start = try #require(script.range(of: openingMarker)).upperBound
        let end = try #require(script.range(of: closingMarker, options: .backwards)).lowerBound
        return String(script[start..<end])
    }

    private static let driverSource = """
        import importlib.util
        import json
        import os
        import sys

        specification = importlib.util.spec_from_file_location("collector", sys.argv[1])
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        mode = os.environ.get("MACHINEPULSE_TEST_MODE", "processes")
        if mode == "oom-parse":
            entries = json.loads(os.environ.get("MACHINEPULSE_FAKE_JOURNAL_ENTRIES", "[]"))
            print(json.dumps(module.parse_oom_entries(entries)))
        elif mode == "oom-events":
            count, last_at, event, status = module.oom_events()
            print(json.dumps({"count": count, "lastAt": last_at, "event": event, "status": status}))
        elif mode == "expected-units":
            print(json.dumps({"units": module.expected_units()}))
        elif mode == "workloads-parse":
            listeners = module.parse_listening_workloads(
                os.environ.get("MACHINEPULSE_FAKE_SS_OUTPUT", ""),
                json.loads(os.environ.get("MACHINEPULSE_FAKE_UNIT_MAP", "{}")),
                json.loads(os.environ.get("MACHINEPULSE_FAKE_UPTIME_MAP", "{}")),
            )
            expected = json.loads(os.environ.get("MACHINEPULSE_FAKE_EXPECTED_METRICS", "[]"))
            print(json.dumps({"workloads": module.merge_expected_workloads(listeners, expected)}))
        elif mode == "resource-control":
            candidate = json.loads(os.environ.get("MACHINEPULSE_FAKE_RESOURCE_CANDIDATE", "{}"))
            root = os.path.join(os.environ["MACHINEPULSE_TEST_WORKSPACE"], "cgroup")
            denied = os.environ.get("MACHINEPULSE_FAKE_DENIED_CGROUP_FILE")
            reader = module.read_cgroup_file
            if denied:
                def reader(path):
                    if os.path.basename(path) == denied:
                        return "unavailable", None
                    return module.read_cgroup_file(path)
            print(json.dumps({"control": module.collect_resource_control(candidate, root, reader)}))
        elif mode == "resource-candidates":
            workloads = json.loads(os.environ.get("MACHINEPULSE_FAKE_RESOURCE_WORKLOADS", "[]"))
            io_processes = []
            process_candidates = json.loads(os.environ.get("MACHINEPULSE_FAKE_RESOURCE_PROCESSES", "[]"))
            control_groups = json.loads(os.environ.get("MACHINEPULSE_FAKE_CONTROL_GROUPS", "{}"))
            module.systemd_control_groups = lambda units: control_groups
            print(json.dumps({"candidates": module.resource_control_candidates(
                workloads, io_processes, process_candidates
            )}))
        elif mode == "darwin-snapshot":
            print(json.dumps(module.collect_darwin()))
        elif mode == "disk-scan":
            options = json.loads(os.environ.get("MACHINEPULSE_DISK_OPTIONS", "{}"))
            print(json.dumps(module.disk_scan(os.environ["MACHINEPULSE_DISK_ROOT"], options)))
        elif mode == "disk-tables":
            print(json.dumps({"kinds": module.DISK_KIND_NAMES, "reclaims": module.DISK_RECLAIM_NAMES}))
        elif mode == "oom-context":
            vmstat = os.path.join(os.environ["MACHINEPULSE_TEST_WORKSPACE"], "proc/vmstat")
            mark = module.oom_kill_mark(os.environ.get("MACHINEPULSE_FAKE_BOOT_ID"), vmstat)
            context = module.oom_context(mark, os.environ.get("MACHINEPULSE_OOM_KILL_MARK"))
            context["mark"] = mark
            print(json.dumps(context))
        else:
            table = module.process_table()
            print(json.dumps({
                "topCPUProcesses": module.top_processes(table, "cpuPercent"),
                "topMemoryProcesses": module.top_processes(table, "residentBytes"),
            }))
        """

    private static let fakeDarwinSysctlSource = """
        #!/bin/sh
        cat <<'OUT'
        hw.memsize: 17179869184
        hw.ncpu: 8
        kern.boottime: { sec = 1700000000, usec = 0 } Tue Nov 14 22:13:20 2023
        kern.bootsessionuuid: 0BADC0DE-0000-4000-8000-000000000001
        kern.memorystatus_vm_pressure_level: 2
        vm.swapusage: total = 2048.00M  used = 512.50M  free = 1535.50M  (encrypted)
        OUT
        """

    private static let fakeDarwinVMStatSource = """
        #!/bin/sh
        cat <<'OUT'
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               100000.
        Pages active:                             200000.
        Pages inactive:                           150000.
        Pages wired down:                          50000.
        "Translation faults":                  123456789.
        File-backed pages:                         50000.
        Anonymous pages:                          300000.
        Swapins:                                    1000.
        Swapouts:                                   2000.
        OUT
        """

    private static let fakeDarwinNetstatSource = """
        #!/bin/sh
        cat <<'OUT'
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        lo0        16384 <Link#1>                            100     0       5000      100     0       5000     0
        lo0        16384 127           127.0.0.1            100     -       5000      100     -       5000     -
        en0        1500  <Link#4>      aa:bb:cc:dd:ee:ff   1000     0     100000      500     0      40000     0
        en0        1500  192.168.1     192.168.1.10        1000     -     100000      500     -      40000     -
        utun3      1500  <Link#20>                            10     0       2000        5     0       1000     0
        OUT
        """

    private static let fakeDarwinIORegSource = """
        #!/bin/sh
        cat <<'OUT'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
          <dict>
            <key>IOClass</key><string>ExampleBlockStorageDriver</string>
            <key>Statistics</key>
            <dict>
              <key>Bytes (Read)</key><integer>5000000</integer>
              <key>Bytes (Write)</key><integer>3000000</integer>
            </dict>
            <key>IORegistryEntryChildren</key>
            <array>
              <dict>
                <key>Statistics</key>
                <dict>
                  <key>Bytes (Read)</key><integer>1</integer>
                  <key>Bytes (Write)</key><integer>2</integer>
                </dict>
              </dict>
            </array>
          </dict>
        </array>
        </plist>
        OUT
        """

    private static let fakeSystemctlSource = """
        #!/usr/bin/env python3
        import os
        import sys
        sys.stdout.write(os.environ.get("MACHINEPULSE_FAKE_SYSTEMCTL_OUTPUT", ""))
        sys.exit(0)
        """

    private static let fakePSSource = """
        #!/usr/bin/env python3
        import json
        import os
        import sys

        output_format = ""
        arguments = sys.argv[1:]
        index = 0
        while index < len(arguments):
            if arguments[index] in ("-eo", "-o") and index + 1 < len(arguments):
                output_format = arguments[index + 1]
                index += 1
            index += 1
        columns = [column.rstrip("=") for column in output_format.split(",") if column]
        rows = json.loads(os.environ.get("MACHINEPULSE_FAKE_PS_ROWS", "[]"))
        for index, row in enumerate(rows, start=1):
            print(" ".join(str(row.get(column, index if column == "pid" else "")) for column in columns))
        """
}
