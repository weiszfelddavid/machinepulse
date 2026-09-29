# Changelog

## Unreleased

- Docs: on macOS 27 the Command Line Tools cannot build the app, since the SDK's SwiftUI macros need the plugin that ships only with Xcode. Found by the first install from source on a macOS 27 Mac.

## 0.5.16 (38)

- On macOS 15 the popover closed at the section change after a View Workloads or View Storage click; those two buttons no longer take keyboard focus.

## 0.5.15 (37)

- The Storage summary leads with how full the volume is and what is free, then used of total and how much can be had back; what was scanned, its size, file count, and age follow.

## 0.5.14 (36)

- Each saved sample updates the hour's capacity rollup from the samples already in memory instead of re-reading and decoding the whole hour from the database.
- SSH compression: the collector script goes up four times smaller and the sample comes back eight times smaller.
- A remote storage scan runs at the lowest CPU priority.

## 0.5.13 (35)

- Without the Tailscale CLI, MachinePulse monitors this Mac; the tailnet message stays until Tailscale is installed.
- Launch at login stays off until switched on in Settings; nothing registers itself.
- `scripts/uninstall-app.sh` removes the app and its login item; `--purge` also removes the database and preferences.
- Resource-scoped processes cover browsers and the common coding agents.

## 0.5.12 (34)

- Detailed samples are kept for one day instead of seven; nothing reads past the two-hour analysis window and the hourly rollups. The store prunes every hour, not only at launch, and gives the file back to the disk once a quarter of it is free pages.
- The Full Disk Access hint shows on macOS 27, where the per-user TCC database no longer exists: the probe tries the protected folders in turn.
- The disk classification tables are data in both the collector and the Swift classifier, held equal by a test.
- Prepared for open source: AGENTS.md, CI, this changelog, docs rewritten, and tests on Swift Testing with one file per subject.

## 0.5.11 (33)

- **Storage**: press Scan on this Mac or a full-metrics machine for a treemap of the home directory by kind of data, reclaimable space hatched, and a Worth a look list of caches, build output, agent worktrees, and stale experiments. Scans run on request only and are kept one per machine. Copy cleanup prompt hands the list to a coding agent; MachinePulse deletes nothing. Rules ported from disktree.
- The `fts` scanner closes the frame of a directory it cannot read and reads the root's own listing for sibling checks.

## 0.5.10 (32)

- Full metrics for another Mac on the tailnet through the same streamed collector.
- The Linux sample reads one process table instead of four and reuses kernel OOM evidence while the kernel's kill counter is unchanged.
- The app keeps only the two-hour analysis window of detailed samples in memory.
- Build and install scripts replace the app bundle instead of merging into it.

## 0.5.9 (31)

- Balanced thresholds and the 12-sample pressure recovery window confirmed against two Linux production profiles; no change needed.
- Overview, Vitals, and Workloads projections with progressive disclosure; a recovered incident stays featured for five minutes.

## 0.5.8

- Hourly capacity history for up to 90 days under a 64 MiB budget, with typical-hour P50/P95/P99 and explicit compatibility boundaries.

## 0.5.7

- Limit-aware workload health: memory high/max/OOM events, CPU throttling under a quota, task exhaustion, workload I/O pressure, and persistently failed watched services become findings; configuration alone never does.

## 0.5.4 to 0.5.6

- Focused machine views and a menu-bar status badge.
- Read-only remote Linux workload inventory: systemd services, listeners, and bindings.
- Bounded cgroup-v2 resource-control telemetry.

## 0.5.3 (25)

- Source and issue links in Settings, structured issue forms, private vulnerability reporting.

## Before 0.5.3

- Incident-first popover with peak evidence that survives recovery.
- Agentless Linux collector with PSI, OOM context, failed services, and an expected-unit watchlist.
- Optional XDR Boost for compatible local displays, made stable over changing content in 0.5.1.
- Quiet presence for phones and tablets, one multiplexed SSH connection per machine, structured logging.
- Local project workloads with Open, Copy URL, and a confirmed graceful Stop.
- Reachability and collection failures kept apart; retry backoff.
