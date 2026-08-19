<img src="assets/icon.png" width="88" alt="">

# RunPool

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

Every mature tool that solves this assumes Kubernetes, a cloud provider API, or ephemeral virtual machines. **One Mac running a few pools has no off-the-shelf answer**, which is the gap RunPool fills.

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

**Capacity and routing are separate, deliberately.** Which runner a job lands on is decided by the workflow's `runs-on`. RunPool decides only whether the runners are running. A workflow pointed at a pool that happens to be down simply waits for it, rather than silently rerouting to a hosted runner that costs ten times as much.

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
| `stats` | What jobs actually cost, from recorded telemetry |
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

`status --json` gives the same thing machine-readably, including each pool's watched repositories and the paths to its logs.

**`status --json --local` skips the GitHub query entirely**, reporting those two fields as `null`. Anything refreshing on a timer should use it: one API call per pool per minute is thousands a day, and it makes a passive readout fail whenever the network does.

**`contrib/demo-status.sh` answers `status` with invented pools**, in the same shape and needing no runners, no repositories and no GitHub account. Point anything that reads RunPool's JSON at it to develop or demonstrate against a fixed, presentable machine. It ignores every other command, so nothing it is wired to can change a real pool.

## `stats` and the runner-count question

Set `RUNPOOL_JOB_HOOK` and `RUNPOOL_TELEMETRY=1` and every job records its duration, the machine's load, and how many jobs were already running when it started. `runpool stats` reads that back.

**The obvious analysis is the wrong one.** Grouping durations by concurrency looks like it answers "does the machine slow down under load", and does not. A workflow has a fixed shape: a couple of fast gate jobs, then a fan-out of heavy ones. The heavy jobs are therefore exactly the ones running when concurrency is highest, so the table shows durations climbing steeply with concurrency on a machine that is coping perfectly well. The workload changed, not the machine.

**So `stats` does not try to answer it.** It describes what jobs cost and stops, because an analysis baked into a tool is a blind spot with a version number, and the first one here reported a contention effect that was pure artefact.

**The answer comes from the records plus GitHub.** `contrib/telemetry-join.sh` emits one row per job with duration, queue time, load and the raw timestamps, joined to what GitHub knows about the same run. Queue time is the figure that matters, because more runners help if and only if work is waiting, and it is invisible locally: the job hook only fires once a runner has already picked the job up.

Read that carefully too. A wait can be a cold pool waking, a dependency that has not finished, or genuinely no free runner, and only the last is fixed by more runners. The runpool skill sets out how to tell them apart.

## Notifications are optional and external

RunPool detects. It does not deliver.

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

Unset, RunPool reports nothing and works exactly as well. There is no mail sending here, no address routing, no severity policy and no dedup window, because none of that is this tool's business. `contrib/notify-webhook.sh` is a reference implementation.

**Two things are reported**, both about the pool's own health: the machine being too contended to trust a result, and runners that are running but unreachable. Failed workflow runs are deliberately *not* reported, because watching CI results is a job for something that does not depend on this laptop being awake.

## Things worth knowing

- **Public repositories are refused at registration.** A pull request from an untrusted fork runs its own workflow file, so wiring one to a self-hosted runner hands any stranger a shell on your machine. This is a refusal, not a warning.
- **`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including here. Reach for that before accepting hosted spend.
- **More runners is not obviously more throughput.** A single test job commonly forks one worker per core, so several at once may oversubscribe the machine and time out tests that are not actually broken. That is the standard argument, it is repeated confidently everywhere including in older versions of this file, and it is worth knowing that it is an argument rather than a measurement. `runpool stats` is here to settle it on your machine rather than in the abstract.
- **Per-runner package caches are load-bearing.** All runners share one HOME, so each gets its own pnpm store and npm cache. Without that, concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine**, by Apple's licence and enforced by the Virtualization framework. If you need more than two parallel macOS jobs, that whole family of tools is unavailable to you, which is part of why this one exists.

## macOS only

launchd, `sysctl`, `~/Library` paths and the `osx-arm64` runner build. This is not an oversight: Linux and Windows are well served by [actions-runner-controller](https://github.com/actions/actions-runner-controller), [garm](https://github.com/cloudbase/garm) and others, and generalising would mean competing where there is no gap.

## For agents

`AGENTS.md` covers working on this repository. `skills/runpool/` is an agent skill for *using* it: wiring a repository to local CI, choosing a scope, and diagnosing a job that queues and never starts. Install it with your agent's usual skill mechanism, or point at the directory.

## Licence

MIT.
