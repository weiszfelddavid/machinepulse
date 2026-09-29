# Development

## Toolchain

macOS 15 or later, Swift 6.2 or later, and XcodeGen 2.46 or newer to regenerate the project. Xcode always works; the Command Line Tools work on macOS 15 and 26, but the macOS 27 SDK declares `@State` and the other SwiftUI wrappers as macros whose plugin ships only with Xcode, so a macOS 27 build host needs Xcode selected with `xcode-select`. The app has no third-party runtime dependency. Tests pin Swift Testing and its Swift Syntax build dependency to exact commits in `Package.resolved` because the Command Line Tools distribution can omit the Foundation overlay; neither is linked into the app.

## Commands

The gates, all of which must be green, are listed in [AGENTS.md](../AGENTS.md). `./scripts/verify.sh` builds, runs the verifier against live Tailscale, lints with the strict formatter, and syntax-checks the collector. `swift test` runs the deterministic suite against temporary databases and trees only. CI runs everything except the verifier.

`project.yml` is the source of truth for the Xcode project; run `xcodegen generate` after changing targets, resources, or bundle metadata and commit the result. `./scripts/build-app.sh` writes `dist/MachinePulse.app`; `./scripts/install-app.sh` builds, quits the running app, replaces `~/Applications/MachinePulse.app`, and relaunches it; `./scripts/uninstall-app.sh` quits it, drops its login item, and removes it, with `--purge` also removing the database and preferences.

## Environment variables

| Variable | Where | Effect |
| --- | --- | --- |
| `MACHINEPULSE_SSH_TARGET` | `verify.sh`, verifier | streams the shipped collector to that host, read-only, and validates the response |
| `MACHINEPULSE_VERIFY_DISK_SCAN` | verifier | scans this Mac's home through the real scanner, and the SSH target's home through the collector's disk-scan mode |
| `MACHINEPULSE_VERIFY_DATABASE_COPY` | verifier | opens a SQLite backup, never the live database, to check migration |
| `MACHINEPULSE_CONFIGURATION` | `build-app.sh` | `debug` or `release` (default) |
| `MACHINEPULSE_OUTPUT_DIRECTORY`, `MACHINEPULSE_INSTALL_DIRECTORY` | scripts | where the bundle is written or installed |
| `MACHINEPULSE_CODESIGN_IDENTITY` | `build-app.sh` | sign with an identity instead of ad hoc |
| `MACHINEPULSE_PREVIEW_SCENARIO` | debug app | render a deterministic fixture instead of polling (below) |
| `MACHINEPULSE_PREVIEW_SECTION` | debug app | open the fixture in `overview`, `vitals`, `displays`, `workloads`, or `storage` |
| `MACHINEPULSE_PREVIEW_DISPLAY_SCENARIO` | debug app | `available`, `active`, `battery`, or `thermal` fake displays |
| `MACHINEPULSE_PREVIEW_LARGE_TEXT`, `MACHINEPULSE_PREVIEW_REDUCE_MOTION`, `MACHINEPULSE_PREVIEW_APPEARANCE` | debug app | accessibility text size, no badge pulse, a light or dark hint |
| `MACHINEPULSE_MODE=disk-scan`, `MACHINEPULSE_DISK_ROOT` | collector | run the disk scan instead of a sample, optionally from another root |

To scan a remote machine by hand, read-only:

```sh
{ printf "MACHINEPULSE_MODE='disk-scan'\nexport MACHINEPULSE_MODE\n"; cat Sources/MachinePulseApp/Resources/collector.sh; } \
  | ssh your-host sh -s | python3 -m json.tool | head
```

To check migration against your own history, back it up first and pass only the copy:

```sh
sqlite3 "$HOME/Library/Application Support/MachinePulse/machinepulse.sqlite3" ".backup '/tmp/machinepulse-copy.sqlite3'"
MACHINEPULSE_VERIFY_DATABASE_COPY=/tmp/machinepulse-copy.sqlite3 swift run MachinePulseVerifier
```

## Fixtures

Debug builds render deterministic, non-polling fixtures that open no database and write no preference:

```sh
MACHINEPULSE_CONFIGURATION=debug ./scripts/build-app.sh
MACHINEPULSE_PREVIEW_SCENARIO=warning MACHINEPULSE_PREVIEW_SECTION=storage ./dist/MachinePulse.app/Contents/MacOS/MachinePulse
```

Scenarios: `empty`, `loading`, `healthy`, `warning`, `critical`, `clearing`, `recovered`, `unreachable`, `collection-unavailable`, `collection-failed`, `collection-recovered`, `oom`, `disk-growth`, `expected-unit`, `servers`. Every scenario carries a storage scan modelled on a busy development home; Linux scenarios carry workload and cgroup rows; `servers` renders two invented local project rows. Use the system Appearance setting for a real light and dark pass; the appearance variable is only a hint.

`swift run MachinePulseXDRFixture` opens a window that alternates static and changing content (Space toggles, Esc quits) for soaking the overlay with a fixed boost level set in the installed app. Never automate power, lid, login, or thermal transitions.

## Tests

`swift test --filter <Suite>` runs one suite. `CollectorContractTests` extract the Python program from the shipped `collector.sh`, import it, and run it against injected `ps`, `ss`, `systemctl`, journal, cgroup, `sysctl`, `vm_stat`, `netstat`, and `ioreg` output and a real temporary tree for the disk scan, so they never read a live machine. `DiskUsageTests` drive the scan engine with synthetic trees and the real `fts` scanner with a temporary tree that has a hardlink, a symlink, and an unreadable directory. Migration tests use temporary databases.

## Releasing

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`, regenerate the project so `Config/MachinePulse-Info.plist` follows, add the version to `CHANGELOG.md`, and tag the commit. The project publishes source only; the tag is the release.
