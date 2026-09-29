# Architecture

A reusable core with no UI dependency, and a small SwiftUI app.

```text
Tailscale status ──→ discovery ──→ per-device preferences
                                          │
                 ┌────────────────────────┴───────────────────────┐
                 │                                                │
      this Mac (native)                        collector.sh over SSH
                 │                          (Linux machines, other Macs)
                 └───────────────→ MetricSample ←──────────────────┘
                                       │
                            HealthEvaluator (pure)
                                       │
                            IncidentStabilizer
                                       │
                    AppModel → popover, SQLite, notifications
```

## Targets

- **MachinePulseCore** — models, Tailscale discovery, SSH alias matching, metric sources, health evaluation and stabilization, capacity rollups, disk scanning and layout, diagnostics, command execution, SQLite persistence, display policy. Everything that must be correct lives here and is tested without a display.
- **MachinePulseApp** — the menu-bar scene, `AppModel` (the single observable state), views, settings, notifications, and the AppKit and Metal display adapters. `collector.sh` is bundled here as a resource.
- **MachinePulseVerifier** — a command-line check of the live environment for a machine with only the Command Line Tools.
- **MachinePulseXDRFixture** — a standalone window with static and changing content for soaking the overlay.

## Sampling

`AppModel` refreshes every ten seconds and on popover open. `MonitoringScheduler` owns the decisions: which source a device gets from its platform, locality, mode, and SSH target; retry backoff of 10, 20, 40, then 60 seconds after a failure; and when an offline full-metrics machine still needs an explicit unreachable report. Sources run concurrently so one slow machine does not delay another. `CommandRunner` runs every child process (`tailscale`, `ssh`, `ps`, `lsof`) off the cooperative thread pool with a hard deadline (`SIGTERM`, then `SIGKILL` two seconds later) and terminates it on task cancellation.

This Mac is sampled natively: `host_statistics` for CPU and memory, `sysctl` for swap and pressure level, `getifaddrs` for interface totals, `URL` resource values for the volume, and one `ps` for process leaders.

A Linux machine or another Mac runs `ssh <target> sh -s` with `collector.sh` on standard input. The script runs Python 3 in memory, emits one compact JSON object matching `CollectorSnapshot`, and exits. On Linux it reads `/proc`, `ps`, `ss`, `systemctl`, cgroup v2 files, and the current-boot kernel journal; on macOS `host_statistics` through `ctypes`, `sysctl`, `vm_stat`, `netstat`, `ioreg`, and `ps`, with the memory-pressure level and swap counters in place of PSI, workloads, and journal evidence. Preferences reach the script only through an environment preamble: the expected-unit watchlist, the previous OOM mark, and the mode. One `ControlMaster` connection per machine persists for 60 seconds of idle, so continuous sampling costs one handshake per idle period. Every row of `ps` or `ss` output is validated on its own; a malformed row is skipped, never fatal. There is deliberately no broad catch around the collector: a programming error fails loudly and is classified as a collection failure.

The Linux sample reads one `ps` table for both process leaders and cgroup candidates. It emits the kernel's cumulative `oom_kill` counter with the boot identity as a mark; while the app returns an unchanged mark, the journal is not read and the app reuses the OOM evidence it already holds, because the counter cannot stay equal across a new kill. Journal context, when read, is at most 256 matching current-boot rows reduced to time, victim, constraint, cgroup, and memory usage and limit.

Remote workloads come from at most 128 listening TCP rows grouped by stable `.service` identity or bounded process evidence, merged with watched services, capped at 16 records with four listeners each. Resource controls resolve at most 16 cgroup paths from watched or listening services plus current top contributors, read only the named `memory.*`, `cpu.*`, `io.*`, and `pids.*` files below `/sys/fs/cgroup`, each capped at 8 KiB, and keep configured, unlimited, unsupported, and unavailable distinct.

## Health

`HealthEvaluator` is a pure function from a sample, its predecessor, and thresholds to a report. Mac memory health follows the pressure level and active swap; Linux memory health combines utilization and pressure; Linux `some` and `full` pressure are classified separately. `WorkloadHealthEvaluator` judges cgroup consequences from adjacent-sample deltas and refuses a delta across a reboot, identity change, reset, missing value, or a gap over 60 seconds. It suppresses a workload I/O finding that a host finding already represents, and the host evaluator suppresses a journal OOM that a cgroup counter already reported.

`IncidentStabilizer` owns the counters: two samples to warn, three clear samples to recover, twelve for Linux pressure, immediate for critical, unreachable, OOM, failed service, and collection. Each active issue ID is one `HealthIncident` whose `observationContext` keeps the latest observation apart from the peak. Aggregate health is the most severe report among enabled machines; notifications compare stabilized aggregates.

Reachability and observability are separate. Tailscale presence is the only authority on reachable; a failed refresh on an online machine becomes a typed `MetricCollectionFailure` (not configured, SSH transport with OpenSSH exit 255, collector exit, invalid payload, local failure) and a `metrics-collection` warning. `FailureSanitizer` reduces any error to one line of at most 200 characters with key paths redacted.

## Disk composition

`DiskScanEngine` builds a bounded tree and the findings from a pre-order walk without holding a filesystem in memory. The scanner reports each directory it enters with six sibling flags read from its listing (`Cargo.toml`, `package.json`, `Application Support`, `objects`, `refs`, `HEAD`), every entry, and each directory it leaves. Kinds are assigned top-down by name and inherited; reclaim reasons are inherited too, with the sibling and parent checks that make `target`, `node_modules`, `Logs`, `layers`, and `snapshots` trustworthy. An unknown top-level directory takes the kind of its largest recognizable child up to three levels down. Sizes, counts, and last writes aggregate bottom-up. Entries at most four levels deep and at least 4 MiB are retained, 96 per directory; after the walk a floor of 1/2048 of the scan folds small shares into each directory's remainder. Findings are judged when a directory closes: a topmost reclaimable directory, an agent `worktrees` directory, or the stale children of `tries` and `experiments`, each at least 64 MiB, twelve at most. Rules and constants are ported from disktree.

`LocalDiskScanner` drives the engine with `fts`: physical walk, one filesystem, `st_blocks × 512`, hardlinks charged once by `(dev, ino)` when `nlink > 1`, symlinks never followed, a directory flagged `SF_DATALESS` never listed. `fts` reports an unreadable directory as a pre-order visit followed by `FTS_DNR` with no post-order visit, and reports the argument list from `fts_children` until the first read has returned the root; both are handled explicitly. The remote path is the same engine in the collector's `disk-scan` mode over the same SSH connection with a 15-minute deadline. `DiskTreemap` is a squarified layout with name bands, subdividing a directory only when its band fits, and the popover paints it in one `Canvas`.

## Persistence

`MetricsStore` is an actor over the system SQLite library in WAL mode. Payloads are JSON in per-device tables: `metric_samples` for one day, `capacity_hourly_rollups` for about 90 days under a 64 MiB payload budget, `health_incidents` for 30 days, `disk_scans` as the latest scan per machine. `AppModel` holds only the two-hour disk-trend window of samples in memory. The store prunes hourly and rewrites the file when a quarter of it is free pages. Schema changes are additive; the database is never deleted or recreated, and older incident payloads decode unchanged. Preferences and last health states are small `UserDefaults` values.

`CapacityRollupBuilder` is a pure reducer to hourly segments, split on a reboot, host or filesystem identity change, collector change, or a gap over two minutes, with nearest-rank percentiles and event deltas taken only between compatible adjacent samples. `DiskGrowthAnalyzer` reads the two-hour window and returns no trend across a gap over five minutes or a filesystem-size change.

## Presentation

One sorted list of machine cards, projected through the five sections; there is no parallel dashboard state. `MachineCardExpansionState` keeps expansion across projections, expands a new incident once, and respects a manual collapse until a different incident begins. Copied diagnostics pair a readable summary with a versioned JSON snapshot that encodes the complete models, so new fields are included without a second list. The 15-minute chart and the treemap are painted with paths in one view each, with no chart dependency.

## Local displays

`LocalDisplaySessionManager` in the core is pure policy: per-display sessions, headroom clamping, the 2× cap, timeout, battery, thermal, session, and removal rules. Only preferences are stored; a new manager starts with no session. `SystemLocalDisplayController` in the app derives stable identities from public display metadata, re-enumerates `NSScreen.screens` on every change, and reconciles once per second only while controls are visible or a session is active. `XDROverlayController` keeps one click-through window and one EDR `MTKView` per active display, presenting a uniform clear pass at 10 fps; the policy poll changes geometry or level in place and never re-presents a drawable, because replacing drawables made the composite blink. Ordinary brightness is not read: the supported IOKit parameter reports a constant on Apple silicon and its setter reports unsupported, and the private frameworks and DDC are deliberately not used.
