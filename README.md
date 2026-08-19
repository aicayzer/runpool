# runpool

On-demand self-hosted GitHub Actions runner pools for macOS.

Runners come up when jobs queue and stand down when nothing has run for a while. Nothing sits in the background for a repository you are not touching, and nothing starts at login.

```
runpool register acme --org acme-inc --count 4
runpool schedule install
runpool status
```

That is the whole setup. After it, pushes just work.

## Why this exists

GitHub-hosted Actions minutes are metered and macOS is billed at ten times the Linux rate. Running CI on a Mac you already own removes the meter entirely, because self-hosted minutes are free and drawn from a separate allowance.

The official runner makes that harder than it should be:

- **It configures exactly one runner.** There is no concept of a pool, and no count.
- **There is no way to change capacity afterwards.** A pool of four is four separate installations, so resizing means creating or destroying whole runners.
- **It runs forever once started.** GitHub's own guidance discourages persistent always-on runners, and offers nothing that stands them down.
- **Nothing cleans up.** Work directories, diagnostics, superseded binaries and package stores accumulate until the disk is full.

Every mature tool that solves this assumes Kubernetes, a cloud provider API, or ephemeral virtual machines. **One Mac running a few pools has no off-the-shelf answer**, which is the gap runpool fills.

## Install

Requires macOS on Apple Silicon, and an authenticated [`gh`](https://cli.github.com).

```bash
brew install aicayzer/tap/runpool
```

Or from source, which keeps the repository where you cloned it and symlinks `runpool` onto your PATH, so `git pull` updates the tool with no reinstall:

```bash
git clone https://github.com/aicayzer/runpool.git
cd runpool && ./install.sh
```

## Concepts

**A pool is a set of runners bound to one GitHub scope.** GitHub offers repository, organisation and enterprise scopes and **no user-account scope**, which is the single most surprising thing about self-hosted runners. An organisation shares one pool across all its repositories; a personal repository needs its own, and cannot borrow an organisation's.

**Capacity and routing are separate, deliberately.** Which runner a job lands on is decided by the workflow's `runs-on`. runpool decides only whether the runners are running. A workflow pointed at a pool that happens to be down simply waits for it, rather than silently rerouting to a hosted runner that costs ten times as much.

## Commands

| | |
|---|---|
| `register <pool> --repo OWNER/REPO\|--org ORG [--count N]` | Create a pool and configure its runners |
| `set-count <pool> N` | Change a pool's runner count after registration |
| `up` / `down <pool>` | Bring a pool online, or stand it down |
| `status [--json]` | Local state alongside what GitHub actually sees |
| `pools` | List registered pools |
| `reregister <pool>` | Recreate GitHub registrations, keeping the local install |
| `remove <pool>` | Deregister and delete a pool |
| `clean [pool]` | Prune work directories, temp, diagnostics, old binaries, caches |
| `pause` / `resume` | Global kill switch |
| `schedule install\|remove` | The background agents that drive everything above |

## How on-demand works

`schedule install` writes two launch agents.

- **A tick every 60 seconds.** It brings up any pool with queued work, stands down pools idle past the threshold, checks for contention, and checks that registrations are still live. Only *stopped* pools are polled, so during active work it makes no API calls at all.
- **A clean at 04:00.** It skips any pool with a job running, and retries later once things are genuinely idle rather than waiting another day.

First job after a quiet spell waits about a minute for its pool to come up. Everything after that is immediate.

## `status` tells you what GitHub thinks

```
GLOBAL: active
  acme       org  acme-inc              running 4/4  busy 2  github 4/4
  sideproj   repo me/side-project       running 0/2  busy 0  github 0/2
```

**The GitHub column is not decoration.** GitHub prunes the registration of a runner that has not connected for a long time. The local install is unaffected and still looks entirely healthy: it starts, it connects, and it picks up nothing, so jobs queue forever against a pool that reports as running. Reporting only the local view hid exactly that for three weeks. `runpool reregister <pool>` fixes it.

`status --json` gives the same thing machine-readably.

## Notifications are optional and external

runpool detects. It does not deliver.

Set `RUNPOOL_NOTIFY_CMD` to any command that reads one JSON object on stdin:

```json
{
  "source": "runpool",
  "severity": "warning",
  "title": "CI contention on my-mac: load 163, 5 jobs",
  "key": "runpool/contention/my-mac",
  "detail": "A timing-sensitive test failing right now is more likely to be the machine than a defect.",
  "fields": { "Load average": "163", "Jobs running": "5" }
}
```

Unset, runpool reports nothing and works exactly as well. There is no mail sending here, no address routing, no severity policy and no dedup window, because none of that is this tool's business. `contrib/notify-webhook.sh` is a reference implementation.

**Two things are reported**, both about the pool's own health: the machine being too contended to trust a result, and runners that are running but unreachable. Failed workflow runs are deliberately *not* reported, because watching CI results is a job for something that does not depend on this laptop being awake.

## Things worth knowing

- **Public repositories are refused at registration.** A pull request from an untrusted fork runs its own workflow file, so wiring one to a self-hosted runner hands any stranger a shell on your machine. This is a refusal, not a warning.
- **`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including here. Reach for that before accepting hosted spend.
- **Concurrency is bounded by your cores, not by runner count.** A single test job commonly forks one worker per core, so a handful in parallel can oversubscribe a machine badly enough to time out tests that are not actually broken. If red runs come and go, lower the count before suspecting the code.
- **Per-runner package caches are load-bearing.** All runners share one HOME, so each gets its own pnpm store and npm cache. Without that, concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine**, by Apple's licence and enforced by the Virtualization framework. If you need more than two parallel macOS jobs, that whole family of tools is unavailable to you, which is part of why this one exists.

## macOS only

launchd, `sysctl`, `~/Library` paths and the `osx-arm64` runner build. This is not an oversight: Linux and Windows are well served by [actions-runner-controller](https://github.com/actions/actions-runner-controller), [garm](https://github.com/cloudbase/garm) and others, and generalising would mean competing where there is no gap.

## For agents

`AGENTS.md` covers working on this repository. `skills/runpool/` is an agent skill for *using* it: wiring a repository to local CI, choosing a scope, and diagnosing a job that queues and never starts. Install it with your agent's usual skill mechanism, or point at the directory.

## Licence

MIT.
