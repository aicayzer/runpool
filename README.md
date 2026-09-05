<img src="assets/icon.png" width="88" alt="">

# RunPool: self-hosted GitHub Actions runners for macOS

[![CI](https://github.com/aicayzer/runpool/actions/workflows/ci.yml/badge.svg)](https://github.com/aicayzer/runpool/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/aicayzer/runpool)](https://github.com/aicayzer/runpool/releases)
[![Licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)
[![Raycast](https://img.shields.io/badge/Raycast-extension-FF6363)](https://www.raycast.com/aic/runpool)

Runners wake when jobs queue and stand down when nothing has run for a while. Nothing sits in the background for a repository you are not touching, and nothing starts at login.

GitHub-hosted minutes are metered and macOS bills at ten times the Linux rate. Self-hosted minutes are free, but GitHub's own runner is a poor houseguest on a machine you also use: one runner with no concept of a pool, no way to change capacity afterwards, no standing down, and no cleaning up. **RunPool makes it behave.**

## Getting started

Requires macOS on Apple Silicon and an authenticated [`gh`](https://cli.github.com).

```bash
brew install aicayzer/tap/runpool

runpool register acme --org acme-inc --count 4
runpool schedule install
```

Then point a workflow at the pool:

```yaml
jobs:
  test:
    runs-on: [self-hosted, acme]
```

That is the whole setup. Better still, put the target behind a repository variable, so a repo moves between hosted and self-hosted without editing workflows:

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

`brew upgrade runpool` updates it, from the [aicayzer/homebrew-tap](https://github.com/aicayzer/homebrew-tap) tap. To work from source instead, `./install.sh` symlinks `runpool` onto your PATH from wherever you cloned it, so `git pull` is the update.

## Raycast extension

<img src="assets/raycast.png" width="640" alt="The RunPool Raycast extension listing three runner pools">

**[Available in the Raycast store](https://www.raycast.com/aic/runpool).** Start and stop pools, change runner counts, disable local CI and see what is running, without a terminal. An optional menu bar readout fills to the jobs in flight, and a set of AI tools come with it.

## How it works

- **A pool is a set of runners bound to one GitHub scope.** GitHub offers repository, organisation and enterprise scopes and **no user-account scope**, which is the most surprising thing about self-hosted runners. An organisation shares one pool across its repositories; a personal repository needs its own and cannot borrow an organisation's.
- **Capacity and routing stay separate.** A workflow's `runs-on` decides where a job lands. RunPool decides only whether the runners are up, so a workflow pointed at a pool that is down waits for it rather than quietly rerouting to a hosted runner that costs ten times as much.
- **Two launch agents drive everything.** A tick every 60 seconds brings up pools with queued work, stands down idle ones, and checks their registrations are still live. A run that stays queued across several wake cycles stops counting as work, so a run GitHub will never start cannot wake the pool for ever. A clean at 04:00 prunes work directories, caches and superseded binaries, skipping any pool mid-job. Only stopped pools are polled, so active work costs no API calls at all.

The first job after a quiet spell waits about a minute for its pool to come up. Everything after that is immediate.

## Commands

| Command | |
|---|---|
| `register <pool> --repo OWNER/REPO\|--org ORG [--count N] [--watch OWNER/REPO,...] [--allow-public]` | Create a pool and configure its runners |
| `set-count <pool> N [--if-count M] [--drain]` | Change a pool's runner count. `--if-count` refuses unless it is currently M; `--drain` lets running jobs finish first |
| `apply [--dry-run] [--file PATH]` | Reconcile the machine to a file describing its pools |
| `up` / `down <pool> [--drain\|--force]` | Bring a pool online, or stand it down. `--drain` waits for running jobs; `--force` ends them |
| `up-all` / `down-all` | The same, for every pool |
| `status [--json] [--local]` | Local state alongside what GitHub actually sees |
| `doctor` | Why is nothing picking this up. Reports; changes nothing |
| `pools` | List registered pools |
| `stats [--queue] [--days N \| --all]` | What jobs cost, from recorded telemetry. `--queue` adds the wait before each job started, over the last 7 days unless widened |
| `pause [pool]` / `resume [pool]` | Global kill switch, or persistent per-pool pause |
| `reregister <pool>` | Recreate GitHub registrations, keeping the local install |
| `rewrite-agents` | Regenerate the launch agents after changing hook settings |
| `remove <pool>` | Deregister and delete a pool |
| `clean [pool]` | Prune work directories, temp, diagnostics, old binaries, caches |
| `schedule install\|remove` | The background agents that drive everything above |
| `migrate-storage [--dry-run]` | Move a legacy installation into macOS storage |
| `version` | Print the installed version |
| `help [command]` | Per-command options and guidance |

`tick`, `autoscale` and `sweep` exist for the launch agents to call and are not normally run by hand.

Three commands earn a note beyond the table:

- **A busy pool is resized with `--drain`.** Both `set-count` and `down` refuse by default while a job is running, because stopping a runner mid-job fails that job. On a pool that is serving work continuously that refusal has no way through, and the pool most likely to need resizing is the busy one. `--drain` stops the runners accepting new jobs, waits for the ones already running to finish, and then proceeds. The wait is bounded by `RUNPOOL_DRAIN_TIMEOUT`, and it reports what it is still waiting for rather than going quiet. It is opt-in because a command that silently blocks for an hour is worse than one that refuses.
- **The pools file is intent; the running pool is state.** `set-count` changes the pool and deliberately does not write the file, so the two disagree after any resize. That is the normal condition between them rather than a fault: the file records the shape you want a machine to have and is what you copy between machines, while the pool records what is running right now. `apply` is where they are reconciled, and it resolves the difference in the file's favour, so `apply --dry-run` first is not a formality. A `count 3 -> 4` line in that plan is the drift, and applying it would undo a deliberate resize.
- **`set-count` is absolute, so a caller that reads a count and acts on it later needs `--if-count`.** A pool changed in between turns a growth into a shrink, and shrinking deregisters runners. `--if-count M` refuses unless the pool is still at M, and one resize per pool runs at a time so two callers cannot interleave. A runner deregistered locally that GitHub still holds is reported as a failure, not logged and passed over: a stale registration attracts jobs that then queue forever.
- **`status --json --local` skips the GitHub query**, reporting those fields as `null`. The root `paused` field is the global kill switch; every pool also carries its own additive `paused` field. Anything refreshing on a timer should use `--local`, since one API call per pool per minute is thousands a day and makes a passive readout fail whenever the network does.
- **`doctor` answers "why is nothing picking this up" in one command.** It checks `gh` and its authentication, that GitHub still holds the registrations, that the launch agents exist, and then disk headroom, config permissions and the organisation's runner-group setting. Each failure comes with what to do about it, and it exits non-zero when something is actually wrong. It repairs nothing, so it is safe at any moment including mid-job.

## Describing a machine's pools

`register` is right for adding one pool and wrong for describing a machine, because the setup then exists only as a sequence somebody remembers running. Put it in `~/.config/runpool/pools` instead, one pool per line, written as its `register` arguments minus the word `register`:

```
acme  --org acme-inc --count 4 \
      --watch acme-inc/api, acme-inc/web

side  --repo me/side-project --count 1
```

```bash
runpool apply --dry-run   # prints the plan, touches nothing
runpool apply
```

The file holds no credentials and nothing machine-specific, so **a second machine gets the same pools by getting the same file.**

- **Reconciliation goes one way.** Pools in the file are created or adjusted; **a pool on the machine and not in the file is reported and left alone**, because a missing line is far too quiet a way to ask for deregistration. `remove` stays explicit.
- **`--watch` matters for organisation pools.** GitHub reports queued runs per repository and not per organisation, so an org pool with nothing watched never wakes on its own, and one watching only some of its repositories wakes only for those. `doctor` reports a watch list that has fallen behind the organisation; it does not maintain one. Repository pools poll their own target and refuse the flag.

`skills/runpool/` is an agent skill covering all of this in depth: wiring a repository, choosing a scope, sizing a pool, and diagnosing a job that queues and never starts.

## Security

**A public repository is refused at registration**, because a pull request from an untrusted fork runs its own workflow file, which would hand any stranger a shell on your machine. `--allow-public` overrides it with a warning, so the decision is explicit rather than pushed into a forked copy of the tool. For an organisation that control is GitHub's rather than RunPool's: a runner group carries `allows_public_repositories`, it is `false` by default, and RunPool reads it and warns only if it has been turned on.

**[SECURITY.md](SECURITY.md) is the full picture**, including what a job on a runner can reach, why persistent runners are a deliberate choice, and the fork pull request setting RunPool cannot enforce for you.

## Storage

Required state lives in `~/Library/Application Support/runpool`, regenerable data in `~/Library/Caches/runpool`, logs in `~/Library/Logs/runpool`, and configuration under `~/.config/runpool`. `RUNPOOL_BASE`, `RUNPOOL_CACHE_DIR` and `RUNPOOL_LOG_DIR` override those roots.

Installations predating this layout keep working until migrated. `runpool migrate-storage --dry-run` previews the move and the skill covers the rest, including how to verify before removing the old tree.

## Notifications

RunPool detects. It does not deliver. Set `RUNPOOL_NOTIFY_CMD` to any command reading one JSON object on stdin:

```json
{ "severity": "critical", "title": "Pool 'main' is not registered with GitHub", "key": "runpool/unregistered/main" }
```

Unset, it reports nothing and works as well. `contrib/notify-webhook.sh` is a reference implementation.

**Only pool connectivity failures are reported**: a missing GitHub registration, or runners running locally but unreachable from GitHub. Failed workflow runs deliberately are not, because watching CI results should not depend on this laptop being awake.

## Things worth knowing

- **A runner can look healthy while GitHub has dropped it.** GitHub prunes registrations that have not connected for a long time. The local install still starts and connects and then picks up nothing, so jobs queue forever against a pool reporting as running. That is what the `github` column in `status` is for, and `reregister` fixes it.
- **`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including here.
- **More runners is not obviously more throughput.** `runpool stats --queue` gives the wait before each job started, which is the figure that moves when capacity changes. Read it with the qualifier it prints: a wait can be a cold pool waking or a dependency that has not finished, and neither is fixed by more runners.
- **`--queue` costs one API call per run, so it covers the last 7 days by default.** A busy machine accumulates thousands of runs, and joining all of them unbounded takes longer than anyone waits. `--days N` widens or narrows the window and `--all` removes it; the join says how many runs it is fetching and marks each one off, so a long join never looks like a stuck one.

## Not on a Mac?

Linux and Windows are already well served by [actions-runner-controller](https://github.com/actions/actions-runner-controller) and [garm](https://github.com/cloudbase/garm). macOS-only here is a choice rather than an unfinished port: launchd, `sysctl`, `~/Library` paths and the `osx-arm64` runner build go all the way through.
