# Security and privacy

## Trust model

MachinePulse has no login, identity, or credential store. Tailscale decides which devices exist and whether they are reachable. OpenSSH decides whether a remote machine can be read, with the user's own configuration, keys, agent, and host-key policy. The app never asks for, reads, copies, or stores a private key or password.

## What is read

On this Mac: kernel statistics, the volume, one `ps` table, the current user's TCP listeners and their working directories through `lsof` and `ps`, the agent state files described below, and, only when the user presses Scan, directory listings and `lstat` results below the home directory. When the user opens a remote agent session, `lsof` finds the local `ssh` client by its source port, or else by the machine's address. When the user opens a session in herdr, one `ps` table with arguments finds the herdr window.

On a remote machine, through a collector streamed to `sh` over SSH that writes no file and starts no process:

- `/proc` CPU, memory, pressure, disk, network, uptime, and boot identifiers; the root filesystem's capacity and a bounded identity used only to segment history
- one `ps` table, reduced to five names per sort key
- at most 128 listening TCP rows from `ss`, reduced to 16 workloads with four listeners each; baseline SSH, DNS, and Tailscale listeners are dropped
- state of the explicitly configured expected systemd units, and the failed-unit list
- at most 16 cgroup-v2 records read from named files below `/sys/fs/cgroup`, each capped at 8 KiB, never a walk of the tree
- current-boot kernel journal rows matching OOM kills, at most 256, and only after the kernel's OOM counter has changed
- on a Mac: `sysctl`, `vm_stat`, `netstat -ibn`, `ioreg` block-storage counters, and `ps`
- at most 16 agent state files of 4 KiB or less from `~/.local/state/machinepulse/agents`, and the modification time, never the content, of the transcript that a file names
- on Scan: the home directory's entries on one filesystem, symlinks unfollowed, cloud-only folders unopened, keeping names, allocated sizes, counts, and last-write times of the largest entries four levels deep

Never read, anywhere: environment variables, file contents other than the agent state files, or credential paths. Never read on a remote machine: command lines or a process's working directory. On this Mac, command lines are read only to identify project servers and herdr windows.

## The agents plugin

The optional `machinepulse-agents` plugin runs inside Claude Code or Codex as a hook, never inside MachinePulse. It is one POSIX `sh` script in this repository.

- It writes one file for each interactive session, `<agent>-<pid>.json`, with mode 0600 in a 0700 directory. It replaces the file on each event and removes it when the session ends. On a session start it also removes the files of agent processes that no longer exist.
- The file holds the agent name, its process ID, process name as `ps` shows it, and terminal, the state and two timestamps, the working directory and transcript path from the hook input, `TERM_PROGRAM`, `TERM_SESSION_ID` or `ITERM_SESSION_ID`, `TMUX_PANE`, the source port from `SSH_CONNECTION`, and in herdr `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`. It never holds prompt or answer text.
- It reads its own process ancestors with `ps`: the agent is the first one that is not a shell. It prints nothing and always exits 0, because the agents read hook output as instructions.
- A session without a terminal writes nothing.

Monitoring reveals operational metadata to the user of this Mac. Grant SSH access accordingly.

## What is never done

- No persistent agent, service, port, package, user, or file on a remote machine. One multiplexed SSH connection per machine, socket in an app-owned 0700 directory, closed within a minute of monitoring stopping.
- No mutating command over SSH: nothing is started, stopped, restarted, deleted, or configured remotely, including by the Storage section, which reads and never writes.
- No telemetry, analytics, or upload. Logging goes to the macOS unified log. Diagnostics reach the pasteboard only when the user asks.
- No listening server. Outbound work is the local Tailscale CLI and SSH to targets the user enabled.
- No Screen Recording, Accessibility, Input Monitoring, camera, or microphone permission. The XDR overlay outputs a uniform colour and never reads pixels; screenshots can include it, and the UI says so.
- Automation (Apple Events) is used only when the user opens an agent session: one script selects the tab with that terminal device in Terminal or iTerm2. macOS asks for each terminal app once.
- When the user opens a session in herdr on this Mac, the app runs `herdr agent focus` with the user's own herdr to show that pane. It never does this for a remote machine.
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
