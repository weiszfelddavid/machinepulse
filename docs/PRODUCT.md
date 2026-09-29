# Product behavior

MachinePulse answers four questions in order: is a machine healthy now, which incident is active or just recovered, what evidence explains it, and what is the safest next action. Workloads and storage answer two more without changing health: what is running there, and where the disk space went.

## Machine states

- **Healthy now** keeps the card collapsed. The whole header is the expand control; the chevron only shows state.
- **Needs attention** names the highest-severity active incident and expands the card once when the incident begins. A deliberate collapse is respected until a different incident begins.
- **Unreachable** is reserved for a computer Tailscale reports offline. It is immediate and recommends checking Tailscale. Phones and tablets are exempt: they show "Offline · last seen …" with no incident, notification, or badge, because mobile devices sleep and roam.
- **Metrics collection unavailable / failed** is a warning for a machine that is online but whose SSH access, configuration, or collector cannot produce a valid sample. The last successful sample stays on the card, labeled as such, and the state recovers on the next good sample. The explanation is one sanitized line.
- **Clearing** means the latest sample no longer shows a previously active issue and MachinePulse is waiting through that issue's quiet window. The current reading and the remaining clear samples are shown; the peak stays as history.
- **Recovered** keeps duration, peak, and retained evidence without keeping health elevated. A recovered incident stays featured for five minutes, then lives on in history and diagnostics.
- **Loading** separates discovery from waiting for a first full-metrics sample.

Severity is always written as text; colour is supporting information. The menu-bar pulse gains an orange dot for a warning and a red dot for critical or unreachable, breathing slowly unless Reduce Motion is on. Notifications fire only when a machine's stabilized health changes.

## Incidents

Continuously sampled warnings activate after two matching samples; a critical sample activates immediately. Ordinary thresholds recover after three clear samples. Linux CPU, memory, and I/O pressure recover after 12 clear samples, about two minutes, so a brief recurrence stays in one incident. Unreachable, OOM, failed-service, and collection observations are immediate; a collection incident clears after one good sample.

An incident is keyed by machine and issue. It records the latest observation and the peak separately: time, measurement, threshold, severity, explanation, evidence, and clearing progress. The card labels current telemetry independently, so a recovered CPU peak cannot be mistaken for the current value.

Linux pressure "some" (at least one task waited) and "full" (all tasks waited) are evaluated independently; either can drive severity and the explanation names both. When I/O pressure is elevated, the sample keeps the process and systemd unit that led same-sample I/O activity, labeled as correlation, not cause.

A new OOM names the killed process when the journal exposes it and says whether the limit was system-wide or a cgroup. Missing journal access is stated as unavailable, never read as zero kills, and a temporary loss of access does not replay an old kill as new.

The expected-unit watchlist is opt-in per machine: up to 12 explicit `.service` or `.timer` names. Active services and waiting timers are healthy; inactive, failed, or missing units become unit-specific warnings after two samples and recover after three. The watchlist is observation only.

## Alert sensitivity

| Preset | CPU | Linux RAM | Linux swap | Disk | Pressure |
| --- | --- | --- | --- | --- | --- |
| Quiet | 85 / 97% | 88 / 97% | 65% | 88 / 97% | 12 / 35% |
| Balanced | 75 / 92% | 80 / 93% | 50% | 80 / 93% | 8 / 25% |
| Sensitive | 65 / 85% | 72 / 88% | 40% | 72 / 88% | 5 / 18% |

Warning and critical are written warning / critical. Any edited value makes a **Custom** preset, normalized so warning stays below critical. Changes apply from the next sample, so dragging a control is never counted as repeated observations. Mac memory follows system pressure and active swap movement, not a percentage, and Mac RAM matches Activity Monitor. OOM and failed-service rules are not configurable.

## The panel

The panel is 400 points wide and stays compact while every card is collapsed. A segmented control chooses one projection of the same cards: **Overview**, **Vitals**, **Displays**, **Workloads**, **Storage**. A machine that cannot provide the chosen section is omitted; when none can, one line says why. Full-metrics machines come first, then presence-only devices; within a group, recent problems come first, then names.

**Overview** shows the featured incident in its compact form (title, state, timing, peak), with **Incident details** for the explanation, evidence, and next step, then current readings, the network rate, uptime, the incident-relevant process, a collapsed capacity summary, and hand-offs to Workloads and Storage. **Open SSH** and **Copy diagnostic** are inline text actions; the diagnostic leads with a readable summary and includes a JSON snapshot of every captured field. Refresh and **Stop monitoring…** are in the overflow menu; stopping needs confirmation and preserves history. **Collapse All** in the footer closes the cards visible in the current projection.

**Vitals** owns current telemetry, a 15-minute chart placed by timestamp with gaps broken, process leaders, expected units, capacity history, and recent incidents. The chart shows CPU and RAM and, for a pressure incident, the "some" and "full" lines of the featured resource with their thresholds.

Current storage shows used, free, and total. With at least 15 minutes of compatible samples, the last two hours are classified as steady, growing, shrinking, or a temporary spike; history is discarded across a gap or a filesystem-size change, and no time-until-full is ever estimated.

Capacity history collapses to two notable signals and an evidence-confidence label. Opened, it separates host utilization, host saturation, throughput, workload consequences, and evidence quality, as typical-hour P50/P95/P99 over up to 90 days of hourly summaries. A reboot, identity change, collector change, or gap longer than two minutes starts a new segment. **Copy summary** states the window, coverage, boundaries, and limits; the history compares periods and never forecasts or recommends a machine size.

## Workloads

On this Mac, every ten seconds MachinePulse lists TCP listeners owned by the current user whose working directory belongs to a recognizable code project. System apps, helpers, PHP-FPM workers, other users, and directories outside a project are left out. Each row shows project, process, running time, and address. A recognized web process gets **Open** and **Copy URL**; anything else gets **Copy address**.

**Stop…** reveals **Cancel** and **Stop server** inside the card. Confirming rediscovers the listener and verifies UID, PID, start time, identity, project path, and port before sending `SIGTERM`, waits up to three seconds for the process's listeners to close, reports if one remains, and never force-quits. Stopping any card of a process stops that process.

On a full-metrics Linux machine the section lists at most 16 systemd services and listeners with loopback, tailnet, private, public, or all-interface bindings, four listeners each, and offers **Open** only for a recognized web endpoint with a usable host. Watched services stay visible without a listener. Where cgroup v2 exists, a service's current memory and configured limits open with its row; counters, weights, and cgroup identity sit behind a technical disclosure; up to four other current consumers form one collapsed group.

Limits are information until the workload shows a harmful result: two or more new `memory.high` events warn; a new memory max, OOM, or OOM kill is critical; memory at 90% of a configured limit warns only while the host is under memory pressure; a CPU quota warns at 20% throttled periods and is critical at 50%; reaching `TasksMax` warns; a watched service failed in two adjacent samples is critical. Counter deltas need adjacent samples from the same boot and cgroup identity. Workload findings are separate records but the machine's state, badge, and notification use one maximum severity. Remote workloads never expose stop, restart, or configuration actions.

## Storage

Nothing happens until **Scan**. A scan walks the home directory once, takes seconds to about a minute, and stays on the card until the next scan.

The card leads with how full the volume is and what is free, then used of total as `df` reports it and how much of the scanned tree can be had back, then what was scanned, its size and file count, and the scan age. The treemap sizes entries by what they allocate on disk, four levels deep, with each directory's tail merged into one "smaller entries" tile. Colour is the kind of data: code, agent scratch, toolchains, synced, git, media, documents, cache. A hatch means the space can be had back: caches, build output beside its manifest, installed dependencies, sync history, package stores, sandbox layers and snapshots, trash, temporary files. One click selects a tile; a double-click or **Open** goes into a directory and **Up** comes back.

**Worth a look** lists the largest things that could plausibly go: topmost reclaimable directories, agent `worktrees` directories with count and oldest age, and `tries` or `experiments` entries untouched for 30 days. Findings never nest, nothing under 64 MiB is listed, and documents are never suggested.

MachinePulse never deletes, trashes, or empties anything. **Copy cleanup prompt** writes a prompt for a coding agent that names each path with its size and reason and requires it to check each path first, look for git work that exists nowhere else, prefer a tool's own clean command, prefer the trash, and treat names as data. On this Mac without Full Disk Access, Mail, Safari, other apps' data, and the Trash count as unreadable and the card says where to grant it.

## Displays

Local controls are off by default and appear inside the expanded This Mac card. Ordinary brightness belongs to macOS: the row only opens Displays Settings, because the system exposes no trustworthy value. **XDR Boost** is one slider per compatible display: the minimum is off, anything above it is a boost at that level. It is capped at 2×, starts off after every launch, times out after 30 minutes by default, and stops on serious thermal state, an inactive session, missing headroom, or display removal; battery use and restoration after sleep or a lid close are allowed by default and can be turned off. A display without XDR capability is one line with no controls. The overlay can appear in screenshots and recordings; turn boost off before capturing. **Copy XDR diagnostic** records overlay identity, render counters, and lifecycle events, never pixels.

## Settings

Alert sensitivity, per-machine monitoring mode, SSH target, and watchlist, local controls, notifications, and **Launch MachinePulse at login**, a standard login item that stays off until switched on. Settings → General also opens the repository and an issue form. Updates are manual: pull, rebuild, reinstall.
