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

**RunPool controls capacity, not routing.** Whether runners are running is runpool's job. Which runner a job lands on is decided by the workflow's `runs-on`. Both have to be right, and they are changed in different places.

## Before anything else

```bash
command -v runpool || echo "not installed"
runpool status
runpool doctor    # if anything looks wrong, or a job is queued and waiting
runpool help <command>  # command-specific options and guidance
```

Not installed:

```bash
brew install aicayzer/tap/runpool
```

RunPool needs an authenticated `gh` with admin on the target, because registering a runner requires a registration token.

## Wiring a repository to local CI

Two changes, one in each place.

**1. Capacity.** Create a pool, if the right one does not already exist:

```bash
runpool pools                                        # is there one already?
runpool register <name> --org ORG --count 4 \
        --watch OWNER/REPO,OWNER/OTHER               # org-wide
runpool register <name> --repo OWNER/REPO --count 2  # a single repo
runpool schedule install                             # once per machine
```

**An org pool needs `--watch` or it never autoscales.** See *`--watch` is org-only and matters* below. A repo pool polls its own target and refuses the flag.

**Pause is persistent when scoped to a pool.** `runpool pause <pool>` safely stands that pool down and prevents either autoscale or `runpool up <pool>` from starting it. Use `runpool resume <pool>` to clear it. Bare `pause` and `resume` remain the global controls; `down <pool>` is only a temporary stand-down.

**Adding several pools, or setting up a second machine?** Describe them in a file and reconcile to it instead — see *Declaring a machine's pools* below.

**2. Routing.** In the workflow, route the job:

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

Then set the repository variable `CI_RUNNER` to `self-hosted`. The fallback keeps the workflow working for anyone without the pool, and the variable means switching back to hosted is one setting rather than a commit.

**Never add an automatic fallback to hosted runners.** On macOS that silently costs ten times as much, and if the hosted allowance is exhausted it fails anyway. A job waiting for a pool that is down is the correct behaviour.

## Declaring a machine's pools

`~/.config/runpool/pools` describes what the machine should have, one pool per line, written as its `register` arguments minus the word `register`. `runpool apply` reconciles the machine to it.

```
acme  --org acme-inc --count 4 \
      --watch acme-inc/api, acme-inc/web

side  --repo me/side-project --count 1
```

**Another path**, in order of precedence: `runpool apply --file PATH` for one run, `RUNPOOL_POOLS_FILE` in the environment, `RUNPOOL_POOLS_FILE` in `~/.config/runpool/config`. Use `--file` when reading or checking a file that is not the machine's own.

**A `#` comments out the line it is on and nothing else.** A trailing `\` continues onto the next line, and that line has to say something — so a pool commented out across several lines is uncommented entirely or not at all.

```bash
runpool apply --dry-run    # always this first
runpool apply
```

**Always run `--dry-run` and show the user the plan before applying.** Applying registers runners with GitHub and can resize a pool downward, which deregisters real runners.

Read the plan by its first character: `+` create, `~` change, `=` unchanged, `?` on the machine but not in the file, `!` conflict.

- **`apply` never deletes.** A pool that is on the machine and not in the file is reported and left alone. If the user wants it gone, that is `runpool remove <pool>`, explicitly.
- **`!` means the scope or target differs** from what the runners are registered against. `apply` will not fix that; remove the pool and apply again. Say so rather than working around it.
- **`apply` exits non-zero on a conflict or a parse error**, and names the offending line by number. It also refuses a pools file it cannot read, rather than reading it as empty and reporting every real pool as `?`.
- **A real run prints the whole plan first**, then acts under an `applying:` heading. Read the plan, not the interleaving.
- **A public repository is still refused**, by `register`, at the moment the pool is actually created. A dry run does not reach that check, so a `+` line is not a promise the create will succeed.

**Prefer this over a sequence of `register` commands whenever there is more than one pool, or more than one machine.** The file is the thing you copy; a remembered sequence of commands is not. `register` is still right for adding a single pool to a machine that has no such file.

**`--watch` is org-only and matters.** GitHub reports queued runs per repository, not per organisation, so an org pool with nothing watched never autoscales and every job waits for a manual `runpool up`. Both `register` and the pools file take it, repeated flags accumulate, and both refuse it on a repo pool, because such a pool already polls its own target.

**`--allow-public` is repo-only**, for the mirror-image reason: at organisation scope the control is GitHub's own `allows_public_repositories` on the runner group, so the flag would do nothing. Both routes refuse it there rather than accepting it silently. It is consulted only when a pool is created, so adding or removing it on an existing pool is not drift and `apply` correctly reports `=`.

## Which scope

**GitHub has repository, organisation and enterprise scopes, and no user-account scope.** This is the single most surprising thing about self-hosted runners and it decides the shape of everything.

- **An organisation's repositories share one pool.** Register once with `--org` and every repo in it can use those runners.
- **A personal repository needs its own pool.** It cannot borrow an organisation's, ever.

**Never split a pool by platform.** Every runner is the same machine, so a second pool grants no capability the first lacked. Split only for scope, or for a deliberate capacity reservation.

## Never wire a public repository

A pull request from an untrusted fork runs its own workflow file, so a public repo on a self-hosted runner hands any stranger a shell on the machine, as the user who owns it.

**`runpool register --repo` refuses a public repository**, and refuses again if it cannot determine visibility rather than assuming private. There is an `--allow-public` override that warns and proceeds. **Do not reach for it on the user's behalf.** It exists so the decision is explicit rather than made in a forked copy of the tool; suggest it only if the user has said they understand the exposure, and pair it with fork pull request approval below.

**For an organisation, this is GitHub's control, not RunPool's.** The runner group setting `allows_public_repositories` defaults to `false`, and runners register into the default group, so public repos in the org do not get them. `register --org` reads that setting and warns only when it has been switched on. If it warns, the fix is in the organisation's Actions runner-group settings, not in runpool.

**Private is not the same as safe.** Anyone who can fork a private repo and open a pull request, which usually means anyone with read access, can run code on the pool. Set **Settings → Actions → General → Fork pull request workflows** to require approval for outside contributors on any repository pointed at a pool. RunPool cannot enforce this and will not know whether it is set.

Keep publish, deploy and OIDC jobs on hosted runners too: npm provenance requires it.

`SECURITY.md` in the repo is the fuller statement, including why persistent runners are a deliberate choice and why JIT tokens are not used.

## Diagnosing "the job is queued and nothing happens"

**Start here, before `status` and before the log.**

```bash
runpool doctor
```

It works down the whole list below in one pass, prints a remedy against each failure, and **exits non-zero when something is actually wrong**. It reports and repairs nothing, so it is safe at any moment including mid-job — and so nothing it finds is fixed until you run the command it names.

What it finds, and what each finding means:

- **the tick agent is not loaded** — nothing autoscales, so every job waits for a manual `runpool up` while every pool still reports as perfectly healthy. **This is the one failure no other command surfaces.** Fix: `runpool schedule install`.
- **`gh` is not authenticated** — every API call fails and each caller degrades quietly rather than complaining: `status` reports GitHub as unreachable, and autoscale reads a queued count of zero and never wakes anything. Fix: `gh auth login`.
- **github has no runners registered** — GitHub prunes registrations after a long idle spell. The local install is untouched and looks entirely healthy, which is what makes this confusing. Fix: `runpool reregister <pool>`.
- **started locally and none has reached github** — the runners are up and not connecting. Same fix.
- **runpool is paused** — someone hit the kill switch. Fix: `runpool resume`.
- **launch agents missing** — `runpool up` refuses on the first plist it cannot find. Fix: `runpool rewrite-agents`.
- **an org pool with no watched repositories** — it never autoscales, because GitHub reports queued runs per repository rather than per organisation. Fix: give it `--watch` and `runpool apply`. See *`--watch` is org-only and matters* above.
- **disk, config permissions, the organisation's runner-group setting** — each with its own remedy. None of these stops a job being picked up, but they are the things nothing else ever looks at.

**Two situations `doctor` deliberately reports as healthy, because they are.**

- **`running 0/N` with a job genuinely queued** — the tick brings a pool up within about a minute. Wait a minute before intervening; `runpool up <pool>` forces it.
- **A clean report and the job still waits** — the problem is routing, not capacity. The workflow's `runs-on` may not resolve to `self-hosted`, or its labels may not match the pool's. RunPool controls only whether the runners are up and cannot see either.

```bash
runpool status                  # the same picture as a table, one row per pool
runpool status --json           # machine-readable, for scripting
runpool status --json --local   # same shape, no GitHub call; use this on a timer
tail -50 ~/Library/Logs/runpool/runpool.log
```

The JSON carries each pool's watched repositories and the paths to its logs, so a wrapper never has to guess either.

**The root `paused` field is global; each pool has its own `paused` boolean.** Read both. A paused pool is intentional state, not an unreachable runner.

## Storage migration

New installations keep runner credentials, pool definitions and pause state in `~/Library/Application Support/runpool`, with work trees and per-runner caches in `~/Library/Caches/runpool`. Generated job-hook launchers stay under `~/.config/runpool`, whose path is safe for the runner's unquoted Bash hook invocation. Existing `RUNPOOL_BASE` installations remain active until explicitly migrated.

```bash
runpool migrate-storage --dry-run
runpool migrate-storage
runpool status --local
runpool doctor
```

**Do not run migration while a job is active.** RunPool refuses it, preserving registrations and the legacy tree. The old tree is retained after migration; remove it only after verification with `runpool migrate-storage --remove-legacy`. For a custom legacy `RUNPOOL_BASE`, use the exact `--from` and `--to` command printed by migration.

## Capacity

```bash
runpool set-count <pool> 4
```

**The standard argument is that more runners is not more throughput**, because a single test job commonly forks one worker per core, so several in parallel thrash rather than run faster. Treat that as an argument, not a fact. It may hold on a given machine and it may not, and the difference is measurable.

**If red runs come and go, suspect contention before suspecting the code.** Lower the count, or cap per-job worker counts in the test runner. The job hook in `contrib/` stamps machine load into every job so this is visible rather than guessed at.

Resizing refuses while a job is running. Wait rather than forcing.

## Answering "how many runners should this machine have"

Telemetry plus GitHub can answer this properly. `runpool stats` deliberately will not: it describes what jobs cost and stops there, because every analysis baked into the tool is a blind spot with a version number.

**Start with queue time, because it is the only figure that moves when capacity changes.** Duration says what a job costs and load says how contended the machine was; neither responds to another runner.

```bash
runpool stats --queue
```

Median and p90 of the wait before each job started, per `workflow / job`. It is behind a flag and not part of plain `stats` because it joins the local records to GitHub — one API call per run — and `stats` otherwise reads nothing but local files.

**Never quote the number without the qualifier it prints.** A queue time conflates three different situations and only one of them is a shortage of runners; the trap is spelled out below and the command repeats it every time for that reason. On an on-demand pool the first job after a quiet spell always shows about a minute of queue while the pool wakes, and no amount of capacity removes it.

**Then go to the raw rows to separate them:**

```bash
contrib/telemetry-join.sh > joined.tsv
```

One row per job: duration, queue time, load at start, concurrency, and the raw created and started timestamps. Analyse that, do not trust a canned summary — `--queue` included.

**Four traps, each of which has produced a confidently wrong answer here.**

- **Grouping duration by concurrency measures workload shape, not contention.** A workflow runs fast gate jobs first and fans out to heavy ones, so the heavy jobs are always the ones at peak concurrency. The buckets contain different work and comparing them is meaningless. Compare *within* a job type, always.
- **Load is the better axis than concurrency.** Concurrency is pinned by the workflow's structure and barely varies. Load swings widely at the same concurrency depending on where sibling jobs are in their lifecycle, which gives real variation to correlate against. Note that load *at start* is a weak proxy for a job lasting several minutes.
- **Queue time is not one thing.** A wait can be a cold pool waking, a dependency that has not finished, or no free runner. Only the last is fixed by more runners. Separate them by reconstructing, from the started and completed times, whether the pool was ever full during that job's wait. If a runner sat free throughout, more runners would not have helped.
- **`created_at` is when the *run* was created, not when the job became runnable.** Every job in a workflow shares it, so occupancy at that instant is always zero and tells you nothing. Use the whole waiting interval.

**The join key is `run_id` plus runner name.** The job hook records the workflow's job id (`check`) while the API reports its display name, so those never match.

**What no observational data can give you is the ceiling.** Nothing in the record says what eight runners would do on a machine that has only ever run four. That needs changing the count and watching.

## Containers

**`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including macOS. Reach for that before accepting hosted spend.

## Disk

Persistent runners never clean up after themselves. `runpool clean` prunes work directories, temp, diagnostics, superseded runner binaries and package stores, and the scheduler runs it daily. If disk is disappearing, run it manually and check the log for what it freed.

## Notifications

RunPool ships with **no notifier** and works fully without one. Set `RUNPOOL_NOTIFY_CMD` to a command reading one JSON object on stdin; `contrib/notify-webhook.sh` is a reference implementation.

**Do not add notification logic to runpool.** It reports two conditions, both about the pool's own health: contention, and runners that are up but unreachable. Watching workflow *results* belongs to whatever receives the notifications, because that should not depend on the laptop being awake.

## Things that will bite

- **Registration credentials live in the runtime directory**, not the repo. Never commit one, never copy one between machines.
- **Pool names are validated at `register`**: letters, digits, dot, underscore and hyphen. The name becomes a directory, a launch-agent label and a JSON field, so anything else is refused rather than sanitised.
- **All runners share one HOME**, so each needs its own package store and cache. runpool sets this in the launch agent; if you hand-edit an agent, preserve it or concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine** by Apple's licence. If someone suggests Tart, Tartelet or Cilicon for more than two parallel macOS jobs, that ceiling is why it will not work.
- **Nothing watches RunPool itself.** This is an accepted gap, not an oversight. Do not build a heartbeat for it.
