# Contributing

MachinePulse is MIT licensed. Small, focused changes are easiest to review.

Before opening a change, read [AGENTS.md](AGENTS.md): it lists the commands that must be green, the house rules, and the invariants a change must keep. In short: monitoring stays read-only and agentless, authentication stays in Tailscale and OpenSSH, no third-party runtime dependency, deterministic tests beside every rule, and nothing private in the repository.

Use the [issue forms](https://github.com/weiszfelddavid/machinepulse/issues/new/choose) for bugs and ideas, and [private vulnerability reporting](https://github.com/weiszfelddavid/machinepulse/security/advisories/new) for security problems.
