---
name: runpool
description: |
  Set up, wire and diagnose self-hosted GitHub Actions runners on macOS using runpool.
  Use this skill when asked to move a repository's CI off GitHub-hosted runners, to run Actions
  locally or on a Mac, to reduce Actions minutes or billing, to add or resize a runner pool,
  or when a workflow is queued and nothing picks it up. Also use when the user mentions runpool,
  self-hosted runners, runner pools, or `runs-on: self-hosted` on macOS.
---

# runpool

On-demand self-hosted GitHub Actions runner pools for macOS. Pools wake when jobs queue and stand down when idle.

**runpool controls capacity, not routing.** Whether runners are running is runpool's job. Which runner a job lands on is decided by the workflow's `runs-on`. Both have to be right, and they are changed in different places.

## Before anything else

```bash
command -v runpool || echo "not installed"
runpool status
```

Not installed:

```bash
brew install aicayzer/tap/runpool
```

runpool needs an authenticated `gh` with admin on the target, because registering a runner requires a registration token.

## Wiring a repository to local CI

Two changes, one in each place.

**1. Capacity.** Create a pool, if the right one does not already exist:

```bash
runpool pools                                        # is there one already?
runpool register <name> --org ORG --count 4          # org-wide
runpool register <name> --repo OWNER/REPO --count 2  # a single repo
runpool schedule install                             # once per machine
```

**2. Routing.** In the workflow, route the job:

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

Then set the repository variable `CI_RUNNER` to `self-hosted`. The fallback keeps the workflow working for anyone without the pool, and the variable means switching back to hosted is one setting rather than a commit.

**Never add an automatic fallback to hosted runners.** On macOS that silently costs ten times as much, and if the hosted allowance is exhausted it fails anyway. A job waiting for a pool that is down is the correct behaviour.

## Which scope

**GitHub has repository, organisation and enterprise scopes, and no user-account scope.** This is the single most surprising thing about self-hosted runners and it decides the shape of everything.

- **An organisation's repositories share one pool.** Register once with `--org` and every repo in it can use those runners.
- **A personal repository needs its own pool.** It cannot borrow an organisation's, ever.

**Never split a pool by platform.** Every runner is the same machine, so a second pool grants no capability the first lacked. Split only for scope, or for a deliberate capacity reservation.

## Never wire a public repository

`runpool register` refuses one outright. A pull request from an untrusted fork runs its own workflow file, so a public repo on a self-hosted runner hands any stranger a shell on the machine. Do not look for a way around this.

Keep publish, deploy and OIDC jobs on hosted runners too: npm provenance requires it.

## Diagnosing "the job is queued and nothing happens"

Work down this list.

```bash
runpool status
```

- **`** NOT REGISTERED **`** — GitHub has pruned the registrations after a long idle spell. The local install is untouched and looks perfectly healthy, which is what makes this confusing. Fix: `runpool reregister <pool>`.
- **`running N/N` but `github 0/N`** — the runners started but are not reaching GitHub. Same fix.
- **`GLOBAL: paused`** — someone hit the kill switch. `runpool resume`.
- **`running 0/N` and the job is genuinely queued** — the tick brings a pool up within about a minute. Wait one minute before intervening. `runpool up <pool>` forces it.
- **Everything looks right but the job still waits** — check routing rather than capacity. The workflow's `runs-on` may not resolve to `self-hosted`, or its labels may not match the pool's.

```bash
runpool status --json           # machine-readable, for scripting
runpool status --json --local   # same shape, no GitHub call; use this on a timer
tail -50 ~/Library/Logs/runpool/runpool.log
```

The JSON carries each pool's watched repositories and the paths to its logs, so a wrapper never has to guess either.

## Capacity

```bash
runpool set-count <pool> 4
```

**More runners is not more throughput.** A single test job commonly forks one worker per core, so on a 14-core machine one job alone nearly saturates it. Several in parallel do not run faster, they thrash, and the first symptom is timing-sensitive tests failing for reasons unrelated to the code.

**If red runs come and go, suspect contention before suspecting the code.** Lower the count, or cap per-job worker counts in the test runner. The job hook in `contrib/` stamps machine load into every job so this is visible in the log rather than guessed at.

Resizing refuses while a job is running. Wait rather than forcing.

## Containers

**`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including macOS. Reach for that before accepting hosted spend.

## Disk

Persistent runners never clean up after themselves. `runpool clean` prunes work directories, temp, diagnostics, superseded runner binaries and package stores, and the scheduler runs it daily. If disk is disappearing, run it manually and check the log for what it freed.

## Notifications

runpool ships with **no notifier** and works fully without one. Set `RUNPOOL_NOTIFY_CMD` to a command reading one JSON object on stdin; `contrib/notify-webhook.sh` is a reference implementation.

**Do not add notification logic to runpool.** It reports two conditions, both about the pool's own health: contention, and runners that are up but unreachable. Watching workflow *results* belongs to whatever receives the notifications, because that should not depend on the laptop being awake.

## Things that will bite

- **Registration credentials live in the runtime directory**, not the repo. Never commit one, never copy one between machines.
- **All runners share one HOME**, so each needs its own package store and cache. runpool sets this in the launch agent; if you hand-edit an agent, preserve it or concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine** by Apple's licence. If someone suggests Tart, Tartelet or Cilicon for more than two parallel macOS jobs, that ceiling is why it will not work.
- **Nothing watches runpool itself.** This is an accepted gap, not an oversight. Do not build a heartbeat for it.
