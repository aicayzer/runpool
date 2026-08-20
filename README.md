<img src="assets/icon.png" width="88" alt="">

# RunPool

[![CI](https://github.com/aicayzer/runpool/actions/workflows/ci.yml/badge.svg)](https://github.com/aicayzer/runpool/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/aicayzer/runpool)](https://github.com/aicayzer/runpool/releases)
[![Licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

On-demand self-hosted GitHub Actions runner pools for macOS.

Runners come up when jobs queue and stand down when nothing has run for a while. Nothing sits in the background for a repository you are not touching, and nothing starts at login.

```bash
brew install aicayzer/tap/runpool

runpool register acme --org acme-inc --count 4
runpool schedule install
```

That is the whole setup. After it, pushes just work.

## Why this exists

GitHub-hosted Actions minutes are metered and macOS is billed at ten times the Linux rate. Running CI on a Mac you already own removes the meter, because self-hosted minutes are free and drawn from a separate allowance.

The official runner makes that harder than it should be. It configures exactly one runner with no concept of a pool, offers no way to change capacity afterwards, runs forever once started, and never cleans up after itself.

Every mature tool that solves this assumes Kubernetes, a cloud provider API, or ephemeral virtual machines. **One Mac running a few pools has no off-the-shelf answer.**

## Install

Requires macOS on Apple Silicon and an authenticated [`gh`](https://cli.github.com).

```bash
brew install aicayzer/tap/runpool
```

The tap is [aicayzer/homebrew-tap](https://github.com/aicayzer/homebrew-tap). `brew upgrade runpool` updates it.

From source instead, which symlinks `runpool` onto your PATH from wherever you cloned it, so `git pull` updates the tool with no reinstall:

```bash
git clone https://github.com/aicayzer/runpool.git
cd runpool && ./install.sh
```

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

## How it works

**A pool is a set of runners bound to one GitHub scope.** GitHub offers repository, organisation and enterprise scopes and **no user-account scope**, which is the most surprising thing about self-hosted runners. An organisation shares one pool across all its repositories; a personal repository needs its own and cannot borrow an organisation's.

**Capacity and routing are separate.** A workflow's `runs-on` decides where a job lands. RunPool decides only whether the runners are up, so a workflow pointed at a pool that is down waits for it rather than silently rerouting to a hosted runner that costs ten times as much.

`schedule install` writes two launch agents: a tick every 60 seconds that brings up pools with queued work, stands down idle ones and checks registrations are still live, and a clean at 04:00 that skips any pool mid-job. Only stopped pools are polled, so active work costs no API calls.

The first job after a quiet spell waits about a minute for its pool. Everything after is immediate.

## `status` tells you what GitHub thinks

```
GLOBAL: active
  acme       org  acme-inc              running 4/4  busy 2  github 4/4
  sideproj   repo me/side-project       running 0/2  busy 0  github 0/2
```

**The GitHub column is not decoration.** GitHub prunes the registration of a runner that has not connected for a long time. The local install is unaffected and still looks healthy: it starts, connects, and picks up nothing, so jobs queue forever against a pool reporting as running. Reporting only the local view hid exactly that for three weeks. `runpool reregister <pool>` fixes it.

`--json` gives the same machine-readably. **`--json --local` skips the GitHub query**, reporting those fields as `null`, and anything on a timer should use it: one call per pool per minute is thousands a day and fails whenever the network does.

## Raycast extension

<img src="assets/raycast.png" width="640" alt="The RunPool Raycast extension listing three runner pools">

Start and stop pools, change runner counts, disable local CI, and see what is running, without a terminal. There is an optional menu bar readout and a set of AI tools.

**Currently in review for the Raycast store** ([raycast/extensions#30343](https://github.com/raycast/extensions/pull/30343)). Until it lands, run it from a clone of that branch with `npm install && npm run dev`.

## `stats`

Set `RUNPOOL_JOB_HOOK` and `RUNPOOL_TELEMETRY=1` and every job records its duration, the machine's load, and how many jobs were running when it started. `runpool stats` reports what each job type costs.

**It deliberately stops there.** Working out the right runner count needs the raw records joined to GitHub, because the figure that matters is queue time and the job hook only fires once a runner has already picked a job up. `contrib/telemetry-join.sh` does that join.

Read the result carefully: a wait can be a cold pool waking, an unfinished dependency, or genuinely no free runner, and only the last is fixed by more runners. `skills/runpool/` sets out how to tell them apart, and why grouping durations by concurrency measures workload shape rather than contention.

## Notifications are optional and external

RunPool detects. It does not deliver. Set `RUNPOOL_NOTIFY_CMD` to any command reading one JSON object on stdin:

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

Unset, it reports nothing and works as well. No mail sending, no address routing, no severity policy, because none of that is this tool's business. `contrib/notify-webhook.sh` is a reference implementation.

**Two things are reported**, both about the pool's own health: a machine too contended to trust a result, and runners that are up but unreachable. Failed workflow runs deliberately are not, because watching CI results should not depend on this laptop being awake.

## Things worth knowing

- **Public repositories are refused at registration.** A pull request from an untrusted fork runs its own workflow file, so wiring one to a self-hosted runner hands any stranger a shell on your machine. A refusal, not a warning.
- **`services:` and `container:` do not force a hosted runner.** Those two keys are Linux-only, but an ordinary `docker run` in a step works anywhere Docker does, including here.
- **More runners is not obviously more throughput**, and the argument that it is not is an argument rather than a measurement. `runpool stats` settles it on your machine.
- **The contention threshold depends on pool size.** It defaults to six times core count, but a busy pool of N runners reaches roughly N times core count on its own, so a large pool needs it raised or it alerts on healthy work.
- **Per-runner package caches are load-bearing.** All runners share one HOME, so each gets its own pnpm store and npm cache. Without that, concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine** by Apple's licence, enforced by the Virtualization framework. Needing more than two parallel macOS jobs rules that whole family of tools out, which is part of why this one exists.

## macOS only

launchd, `sysctl`, `~/Library` paths and the `osx-arm64` runner build. Not an oversight: Linux and Windows are well served by [actions-runner-controller](https://github.com/actions/actions-runner-controller) and [garm](https://github.com/cloudbase/garm), and generalising would mean competing where there is no gap.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `AGENTS.md` covers working on this repository, and `skills/runpool/` is an agent skill for *using* it.

## Licence

MIT.
