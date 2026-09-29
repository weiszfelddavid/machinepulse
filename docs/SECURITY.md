# Security and privacy

## Trust model

MachinePulse has no login, identity, or credential store. Tailscale decides which devices exist and whether they are reachable. OpenSSH decides whether a remote machine can be read, with the user's own configuration, keys, agent, and host-key policy. The app never asks for, reads, copies, or stores a private key or password.

## What is read

On this Mac: kernel statistics, the volume, one `ps` table, the current user's TCP listeners and their working directories through `lsof` and `ps`, and, only when the user presses Scan, directory listings and `lstat` results below the home directory.

On a remote machine, through a collector streamed to `sh` over SSH that writes no file and starts no process:

- `/proc` CPU, memory, pressure, disk, network, uptime, and boot identifiers; the root filesystem's capacity and a bounded identity used only to segment history
- one `ps` table, reduced to five names per sort key
- at most 128 listening TCP rows from `ss`, reduced to 16 workloads with four listeners each; baseline SSH, DNS, and Tailscale listeners are dropped
- state of the explicitly configured expected systemd units, and the failed-unit list
- at most 16 cgroup-v2 records read from named files below `/sys/fs/cgroup`, each capped at 8 KiB, never a walk of the tree
- current-boot kernel journal rows matching OOM kills, at most 256, and only after the kernel's OOM counter has changed
- on a Mac: `sysctl`, `vm_stat`, `netstat -ibn`, `ioreg` block-storage counters, and `ps`
- on Scan: the home directory's entries on one filesystem, symlinks unfollowed, cloud-only folders unopened, keeping names, allocated sizes, counts, and last-write times of the largest entries four levels deep

Never read, anywhere: command lines, environment variables, file contents, credential paths, or a process's working directory on a remote machine.

Monitoring reveals operational metadata to the user of this Mac. Grant SSH access accordingly.

## What is never done

- No persistent agent, service, port, package, user, or file on a remote machine. One multiplexed SSH connection per machine, socket in an app-owned 0700 directory, closed within a minute of monitoring stopping.
- No mutating command over SSH: nothing is started, stopped, restarted, deleted, or configured remotely, including by the Storage section, which reads and never writes.
- No telemetry, analytics, or upload. Logging goes to the macOS unified log. Diagnostics reach the pasteboard only when the user asks.
- No listening server. Outbound work is the local Tailscale CLI and SSH to targets the user enabled.
- No Screen Recording, Accessibility, Input Monitoring, camera, or microphone permission. The XDR overlay outputs a uniform colour and never reads pixels; screenshots can include it, and the UI says so.
- No privilege escalation, daemon, LaunchAgent, or helper. Launch at login is the standard `SMAppService` login item, off until the user turns it on, visible and revocable in System Settings.

The one mutating action is **Stop** on a project server owned by the current user on this Mac. It requires a second explicit confirmation, re-verifies UID, PID, start time, identity, project path, and port immediately before acting, sends `SIGTERM` only, and never `SIGKILL`.

## Local data

Everything stays in `~/Library/Application Support/MachinePulse/machinepulse.sqlite3`. Schema changes are additive; the database is never deleted or rewritten by an upgrade.

A copied diagnostic can contain device names, tailnet DNS names and addresses, process and service names, listeners, cgroup paths, limits, counters, measurements, thresholds, and incident history, but never credentials or key material. The cleanup prompt contains directory paths and sizes. Review both before sharing. Collection errors are sanitized before they reach a report: one line, at most 200 characters, tokens naming SSH key files redacted, no traceback or SSH arguments.

The Storage scan runs with the app's own access. Without Full Disk Access it does not see Mail, Safari, other apps' containers, or the Trash; it reports them as unreadable and does not request the permission itself.

## Repository

No database, diagnostic, hostname, alias, address, cgroup path, process ID, private path, certificate, or key belongs in the repository. Fixtures use invented names. Local builds are ad-hoc signed; the project publishes no binary, signing workflow, or notarization.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/weiszfelddavid/machinepulse/security/advisories/new), not a public issue. Include the macOS version, the MachinePulse version and build, and minimal reproduction steps, without exploit details or a diagnostic containing device or tailnet identifiers.
