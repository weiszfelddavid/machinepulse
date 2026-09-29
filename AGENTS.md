# MachinePulse — agent guide

A SwiftUI menu-bar monitor for the machines on a tailnet. Read `README.md` for the product; this file is the working contract.

## What this is

Discover machines through Tailscale, sample them (this Mac directly, Linux machines and other Macs through a collector streamed over SSH), turn samples into deterministic health, stabilize incidents so evidence survives short-lived problems, and show it all in one menu-bar panel. Monitoring is read-only; the only mutating action is a confirmed, graceful stop of a project server the user owns on this Mac.

## Commands

```sh
./scripts/verify.sh                         # build, verifier, strict formatter, collector syntax
MACHINEPULSE_SSH_TARGET=host ./scripts/verify.sh   # adds a live, read-only remote collector check
swift build -Xswiftc -warnings-as-errors
swift test                                  # deterministic; temporary databases and trees only
xcrun swift-format lint --strict --recursive Sources Tests
xcodegen generate                           # after editing project.yml; commit the result
./scripts/build-app.sh                      # dist/MachinePulse.app
./scripts/install-app.sh                    # ~/Applications, quits and relaunches the app
./scripts/uninstall-app.sh [--purge]        # removes the app and its login item; --purge adds data and preferences
```

`verify.sh` needs Tailscale running; CI runs the other gates. All of them must be green before anything is called done, and none of them may fix anything.

## House rules

- **Swift 6, warnings are errors, strict formatting.** No third-party runtime dependency; Swift Testing is the only package and it is test-only.
- **Comments say why.** The code says what. A comment earns its place only for something the code cannot show: an external contract (OpenSSH exit 255, `fts` reporting an unreadable directory twice), a hidden invariant, or a deliberate limit. Never name the caller, the task, or the incident.
- **Tests live beside the promise they make** and read as promises. Health, decoding, and scanning rules are tested against synthetic samples, real temporary trees, and the real shipped collector script, never against the user's database or a live machine.
- **Keep UI copy short and cause-oriented.** Severity is written as text; colour is supporting information.
- **Nothing private in the repository:** no database, diagnostic, hostname, alias, address, cgroup path, process ID, or personal path. Fixtures use invented names.

## Invariants

1. **Tailscale is the only authority on reachability.** A machine is unreachable only when Tailscale says it is offline. A collection failure on an online machine is a `metrics-collection` warning that keeps the last good sample on screen; it never becomes a connectivity incident.
2. **Remote collection is agentless and read-only.** `collector.sh` is streamed to `sh -s`, emits one JSON document, and exits. It writes no file, starts no process, reads no command line, environment, or file content, and the app never sends a mutating command over SSH.
3. **Health is deterministic and stabilized outside SwiftUI.** `HealthEvaluator` is pure; `IncidentStabilizer` owns the sample counters (two samples to warn, three clear samples to recover, twelve for Linux pressure, immediate for critical, unreachable, OOM, failed service, and collection). Each active issue ID is one `HealthIncident` that keeps its peak separately from its latest observation.
4. **Counters are never subtracted across a boundary.** Rates and event deltas require the same boot, the same cgroup or filesystem identity, and adjacent samples; a reboot, reset, or migration starts over.
5. **Local workloads and storage never change health.** Their presence, absence, or failure cannot create an incident, a notification, or a menu-bar badge.
6. **A storage scan runs only when asked, measures what comes back (`st_blocks × 512`), charges a hardlink once, never follows a symlink, never opens a cloud-only folder, and never deletes.** The engine keeps at most 96 children per directory, four levels deep, and judges findings when a directory closes; findings never nest.
7. **Stop is the only mutating action.** It needs a second explicit confirmation, re-verifies UID, PID, start time, identity, project path, and port, sends `SIGTERM` to a current-user process on this Mac only, and never `SIGKILL`.
8. **Display controls cannot reach monitoring.** `LocalDisplaySessionManager` is pure policy; XDR Boost starts off after every launch, is capped at 2×, times out, and yields to battery, thermal, session, and headroom rules. The overlay never reads pixels.
9. **Schema changes are additive.** The database is never deleted or recreated; stored incidents from earlier versions decode unchanged.
10. **The treemap and the chart are painted, not composed.** Hundreds of tiles belong in one `Canvas`; labels are clipped to their own tile.

## Where changes belong

| change | where |
| --- | --- |
| what a sample contains, decoding | `Sources/MachinePulseCore/Models/Metrics.swift` |
| a health rule or threshold | `Sources/MachinePulseCore/Health/HealthEvaluator.swift`, `WorkloadHealthEvaluator.swift` |
| incident lifecycle, clearing windows | `Sources/MachinePulseCore/Health/IncidentStabilizer.swift` |
| scheduling, backoff, which source a device gets | `Sources/MachinePulseCore/Health/MonitoringScheduler.swift` |
| what the remote collector reads | `Sources/MachinePulseApp/Resources/collector.sh` |
| how this Mac is sampled | `Sources/MachinePulseCore/Collectors/LocalMacMetricSource.swift` |
| SSH transport | `Sources/MachinePulseCore/Collectors/SSHMetricSource.swift` |
| storage scan rules, bounds, layout | `Sources/MachinePulseCore/DiskUsage/` |
| persistence and retention | `Sources/MachinePulseCore/Persistence/MetricsStore.swift` |
| copied diagnostics | `Sources/MachinePulseCore/Health/DiagnosticComposer.swift` |
| polling lifecycle, preferences, actions | `Sources/MachinePulseApp/App/AppModel.swift` |
| a screen or a card | `Sources/MachinePulseApp/Views/` |
| display policy | `Sources/MachinePulseCore/LocalControls/`; adapters in `Sources/MachinePulseApp/Display/` |

## Verification expectations

- Health rules, stabilization, capacity rollups, disk classification and findings, and layout are covered by deterministic tests in `Tests/MachinePulseCoreTests`.
- The shipped `collector.sh` is exercised by importing its embedded Python with injected `ps`, `ss`, `systemctl`, journal, cgroup, `sysctl`, `vm_stat`, `netstat`, and `ioreg` evidence, and its disk-scan mode against a real temporary tree.
- The `fts` scanner is tested against a real temporary tree with a hardlink, a symlink, and an unreadable directory.
- Debug builds render deterministic fixtures for every popover state (`docs/DEVELOPMENT.md`); a visual change is reviewed against them at the real 400-point width.
- `MachinePulseVerifier` checks the live environment: Tailscale discovery, local collection, local workloads, a temporary SQLite round-trip, and on request a real disk scan.
