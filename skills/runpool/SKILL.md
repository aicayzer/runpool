---
name: runpool
description: Set up, wire and diagnose self-hosted GitHub Actions runner pools on macOS with the runpool CLI. Use when moving a repository's CI off GitHub-hosted runners, running Actions on a Mac, reducing Actions minutes or billing, adding or resizing a runner pool, or when a workflow is queued and nothing picks it up. Also use when the user mentions runpool, self-hosted runners, runner pools, or `runs-on: self-hosted` on macOS.
---

# runpool

On-demand self-hosted GitHub Actions runner pools for macOS. Pools wake when jobs queue and stand down when idle.

**RunPool controls capacity, not routing.** Whether runners are running is runpool's job. Which runner a job lands on is decided by the workflow's `runs-on`. Both have to be right, and they are changed in different places.

**Reference files, loaded when the task needs them:**

- **[SIZING.md](SIZING.md):** how many runners a machine should have, and the four traps that have each produced a confidently wrong answer.
- **[MIGRATION.md](MIGRATION.md):** moving a legacy installation into macOS storage.

## Before anything else

```bash
command -v runpool || echo "not installed"     # brew install aicayzer/tap/runpool
runpool version
runpool status
runpool doctor            # if anything looks wrong, or a job is queued and waiting
runpool help <command>    # per-command options
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

**An org pool needs `--watch` or it never autoscales.** GitHub reports queued runs per repository and not per organisation, so an org pool with nothing watched waits for a manual `runpool up` every time. Both `register` and the pools file take it, repeated flags accumulate, and both refuse it on a repo pool because such a pool already polls its own target.

**2. Routing.** In the workflow:

```yaml
runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}
```

Then set the repository variable `CI_RUNNER` to `self-hosted`. The fallback keeps the workflow working for anyone without the pool, and the variable means switching back to hosted is one setting rather than a commit.

**Never add an automatic fallback to hosted runners.** On macOS that silently costs ten times as much, and if the hosted allowance is exhausted it fails anyway. A job waiting for a pool that is down is the correct behaviour.

Keep publish, deploy and OIDC jobs hosted regardless: npm provenance requires it.

## Which scope

**GitHub has repository, organisation and enterprise scopes, and no user-account scope.** This is the single most surprising thing about self-hosted runners and it decides the shape of everything.

- **An organisation's repositories share one pool.** Register once with `--org` and every repo in it can use those runners.
- **A personal repository needs its own pool.** It cannot borrow an organisation's, ever.

**Never split a pool by platform.** Every runner is the same machine, so a second pool grants no capability the first lacked. Split only for scope, or for a deliberate capacity reservation.

## Never wire a public repository

A pull request from an untrusted fork runs its own workflow file, so a public repo on a self-hosted runner hands any stranger a shell on the machine, as the user who owns it.

- **`runpool register --repo` refuses a public repository**, and refuses again if it cannot determine visibility rather than assuming private. `--allow-public` warns and proceeds. **Do not reach for it on the user's behalf.** It exists so the decision is explicit rather than made in a forked copy of the tool; suggest it only if the user has said they understand the exposure.
- **For an organisation this is GitHub's control.** The runner group setting `allows_public_repositories` defaults to `false` and runners register into the default group, so public repos in the org do not get them. `register --org` reads it and warns only when it has been switched on. If it warns, the fix is in the organisation's Actions runner-group settings, not in runpool.
- **Private is not the same as safe.** Anyone who can fork a private repo and open a pull request, which usually means anyone with read access, can run code on the pool. Set **Settings → Actions → General → Fork pull request workflows** to require approval for outside contributors on any repository pointed at a pool. RunPool cannot enforce this and will not know whether it is set.

`SECURITY.md` in the repo is the fuller statement, including why persistent runners are a deliberate choice and why JIT tokens are not used.

## Declaring a machine's pools

`~/.config/runpool/pools` describes what the machine should have, one pool per line, written as its `register` arguments minus the word `register`. `runpool apply` reconciles the machine to it.

```
acme  --org acme-inc --count 4 \
      --watch acme-inc/api, acme-inc/web

side  --repo me/side-project --count 1
```

```bash
runpool apply --dry-run    # always this first
runpool apply
```

**Always run `--dry-run` and show the user the plan before applying.** Applying registers runners with GitHub and can resize a pool downward, which deregisters real runners.

Read the plan by its first character: `+` create, `~` change, `=` unchanged, `?` on the machine but not in the file, `!` conflict.

- **`apply` never deletes.** A pool on the machine and not in the file is reported and left alone. If the user wants it gone, that is `runpool remove <pool>`, explicitly.
- **`!` means the scope or target differs** from what the runners are registered against. `apply` will not fix that; remove the pool and apply again. Say so rather than working around it.
- **`apply` exits non-zero on a conflict or a parse error**, and names the offending line by number. It refuses a pools file it cannot read rather than reading it as empty and reporting every real pool as `?`.
- **A real run prints the whole plan first**, then acts under an `applying:` heading. Read the plan, not the interleaving.
- **A public repository is still refused** by `register`, when the pool is actually created. A dry run does not reach that check, so a `+` line is not a promise the create will succeed.
- **`--allow-public` is repo-only**, because at organisation scope the control is GitHub's. It is consulted only at creation, so adding or removing it on an existing pool is not drift and `apply` correctly reports `=`.

**A `#` comments out the line it is on and nothing else.** A trailing `\` continues onto the next line, and that line has to say something, so a pool commented out across several lines is uncommented entirely or not at all.

**Another path**, in order of precedence: `runpool apply --file PATH` for one run, `RUNPOOL_POOLS_FILE` in the environment, then in `~/.config/runpool/config`. Use `--file` when reading a file that is not the machine's own.

**Prefer this over a sequence of `register` commands whenever there is more than one pool, or more than one machine.** The file is the thing you copy; a remembered sequence of commands is not.

## Diagnosing "the job is queued and nothing happens"

**Start here, before `status` and before the log.**

```bash
runpool doctor
```

It works down the whole list below in one pass, prints a remedy against each failure, and **exits non-zero when something is actually wrong**. It repairs nothing, so it is safe at any moment including mid-job, and nothing it finds is fixed until you run the command it names.

- **the tick agent is not loaded:** nothing autoscales, so every job waits for a manual `runpool up` while every pool still reports as perfectly healthy. **This is the one failure no other command surfaces.** Fix: `runpool schedule install`.
- **`gh` is not authenticated:** every API call fails and each caller degrades quietly: `status` reports GitHub as unreachable, and autoscale reads a queued count of zero and never wakes anything. Fix: `gh auth login`.
- **github has no runners registered:** GitHub prunes registrations after a long idle spell. The local install is untouched and looks entirely healthy, which is what makes this confusing. Fix: `runpool reregister <pool>`.
- **started locally and none has reached github:** the runners are up and not connecting. Same fix.
- **runpool is paused:** someone hit the kill switch. Fix: `runpool resume`.
- **launch agents missing:** `runpool up` refuses on the first plist it cannot find. Fix: `runpool rewrite-agents`.
- **an org pool with no watched repositories:** it never autoscales. Fix: give it `--watch` and `runpool apply`.
- **an org pool watching only some of its repositories:** a note rather than a failure, because a repository may legitimately route its jobs elsewhere and nothing readable tells the difference. A job queued by an unwatched one waits until a watched one happens to wake the pool. **`doctor` makes a stale list audible; it does not maintain one.** The list stays hand-maintained, so a repository added to the organisation is still a change somebody has to make here too.
- **runner(s) started before graceful shutdown was available:** a note, not a failure. The pool runs and takes work normally; only `--drain` is affected, and it refuses safely rather than killing the job. Fix: `runpool rewrite-agents`, then let the pool cycle. **This is how to check drain readiness without attempting a drain**, which on a busy pool means risking real jobs to answer a question.
- **disk, config permissions, the organisation's runner-group setting:** each with its own remedy. None of these stops a job being picked up, but they are the things nothing else ever looks at.

**Two situations `doctor` deliberately reports as healthy, because they are.**

- **`running 0/N` with a job genuinely queued:** the tick brings a pool up within about a minute. Wait before intervening; `runpool up <pool>` forces it.
- **A clean report and the job still waits:** the problem is routing, not capacity. The workflow's `runs-on` may not resolve to `self-hosted`, or its labels may not match the pool's. RunPool controls only whether the runners are up and cannot see either.

```bash
runpool status                  # the same picture as a table, one row per pool
runpool status --json           # machine-readable, for scripting
runpool status --json --local   # same shape, no GitHub call; use this on a timer
tail -50 ~/Library/Logs/runpool/runpool.log
```

The JSON carries each pool's watched repositories and the paths to its logs, so a wrapper never has to guess either. **The root `paused` field is global; each pool has its own `paused` boolean.** Read both: a paused pool is intentional state, not an unreachable runner.

## Capacity

```bash
runpool set-count <pool> 4
runpool set-count <pool> 4 --if-count 2    # refuse unless it is still at 2
runpool set-count <pool> 2 --drain         # let running jobs finish first
runpool down <pool> --drain                # same, without resizing
```

**The pools file is intent; the running pool is state.** `set-count` changes the pool and does not write the file, so they disagree after any resize. This is by design, not drift to repair: the file is the shape you want and what you copy between machines, the pool is what is running now, and `apply` reconciles them in the file's favour. Always `apply --dry-run` first and read the plan: a `count` line in it is a deliberate resize about to be undone.

**`set-count` writes an absolute number, so anything that read the count earlier must pass `--if-count`.** Between the read and the write the pool may have moved, and a command meant to grow it then shrinks it instead, deregistering runners that setting the number back does not restore. Pass the count you read as `--if-count` and the resize is refused rather than guessed at. One resize per pool runs at a time, so two callers cannot interleave.

A deregistration that fails is reported as a failure, not passed over. A registration GitHub still holds for a runner that no longer exists attracts jobs that queue forever, so if a resize reports orphaned runners, clear them before moving on.

**Resizing refuses while a job is running, and `--drain` is the way through.** Stopping a runner mid-job fails that job, so the refusal is right. But on a pool serving work continuously there is never a quiet moment, and the pool that most needs resizing is the busy one. `--drain` stops the runners accepting new work, waits for what is already running to finish, then resizes.

- **It is opt-in, not the default.** A command that silently blocks for an hour is worse than one that refuses, and a blocking command is indistinguishable from a hung one.
- **The wait is bounded** by `--timeout`, defaulting to `RUNPOOL_DRAIN_TIMEOUT` (4200s). Set that above the longest `timeout-minutes` any workflow on the pool allows, not above how long jobs actually take: a drain bounded at exactly the job cap can time out on a job GitHub was still happily running.
- **It reports what it is waiting for** every 30 seconds. Do not interrupt it because it has gone quiet; it has not.
- **On timeout the runners are already stopped** and will exit as their jobs finish. Retry, or `down <pool> --force` to end them now.
- **`--drain` and `--force` are mutually exclusive.** One waits for jobs, the other ends them.

**A pool upgraded to 0.10.0 but not yet restarted cannot drain**, because its loaded agents predate the graceful-shutdown setting. The drain detects this per runner and refuses rather than killing the job; the fix it names is `runpool rewrite-agents` then a down/up cycle once the pool is idle.

**Before changing a count, read [SIZING.md](SIZING.md).** More runners is not reliably more throughput, and the figure that answers the question is queue time rather than duration.

## Pausing

**`runpool pause <pool>` is persistent.** It stands that pool down safely and prevents both autoscale and a manual `runpool up` from starting it until `runpool resume <pool>`. Bare `pause` and `resume` are the global kill switch. `down <pool>` is only a temporary stand-down and does not pause anything.

## Disk

Persistent runners never clean up after themselves. `runpool clean` prunes work directories, temp, diagnostics, superseded runner binaries and package stores, and the scheduler runs it daily. If disk is disappearing, run it manually and check the log for what it freed.

## Notifications

RunPool ships with **no notifier** and works fully without one. Set `RUNPOOL_NOTIFY_CMD` to a command reading one JSON object on stdin; `contrib/notify-webhook.sh` is a reference implementation.

**Do not add notification logic to runpool.** It reports only pool connectivity failures: a missing GitHub registration, or runners that are up locally but unreachable. Watching workflow *results* belongs to whatever receives the notifications, because that should not depend on the laptop being awake.

## Containers

**`services:` and `container:` do not force a hosted runner.** Those two workflow keys are Linux-only, but an ordinary `docker run` inside a step works anywhere Docker does, including macOS. Reach for that before accepting hosted spend.

## Things that will bite

- **Registration credentials live in the runtime directory**, not the repo. Never commit one, never copy one between machines.
- **Pool names are validated at `register`**: letters, digits, dot, underscore and hyphen. The name becomes a directory, a launch-agent label and a JSON field, so anything else is refused rather than sanitised.
- **All runners share one HOME**, so each needs its own package store and cache. runpool sets this in the launch agent; if you hand-edit an agent, preserve it or concurrent installs collide.
- **Ephemeral macOS VMs are capped at two per machine** by Apple's licence. If someone suggests Tart, Tartelet or Cilicon for more than two parallel macOS jobs, that ceiling is why it will not work.
- **Nothing watches RunPool itself.** This is an accepted gap, not an oversight. Do not build a heartbeat for it.
