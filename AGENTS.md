# Agent instructions for RunPool

Guidance for an agent changing this repository. The README is for people *using* RunPool; this file is for whoever is *editing* it.

## What this is

A single-purpose macOS CLI that manages pools of self-hosted GitHub Actions runners. It controls **capacity only**: whether runners are running. Where a job lands is decided by the workflow's `runs-on` and is none of this tool's business.

Plain shell. No build step, no dependencies to install, no package manager.

## Hard constraints

Break any of these and the tool stops being what it is.

- **Bash 3.2.** Stock macOS ships bash 3.2 and the tool must run there. No associative arrays, no `mapfile`/`readarray`, no `${var^^}`, no `&>>`. CI parses every file under `/bin/bash` on a macOS runner to enforce this.
- **macOS only.** launchd, `sysctl`, `~/Library` paths, the `osx-arm64` runner build. Do not add Linux or Windows support: that case is already well served by actions-runner-controller and garm, and serving it would mean competing where there is no gap.
- **No notifier.** `lib/notify.sh` writes one JSON object to whatever `RUNPOOL_NOTIFY_CMD` names. It must never grow mail sending, address routing, severity policy, dedup windows, or a dependency on a particular service. An earlier version had all of those and it is exactly why it could not be published.
- **No workflow-result watching.** Reporting on failed CI runs is observability and belongs to whatever receives the notifications, which can poll GitHub without depending on a laptop being awake. This tool reports only on the health of the pool itself.
- **Nothing personal in the repository.** No real organisation names, repository names, hostnames, addresses or paths, in code, comments, docs or examples. Use `acme` / `acme-inc` / `me/side-project`. Installation specifics belong in the user's config file, never here.
- **No secrets, ever.** Registration credentials live in the runtime directory, which is outside this repo by design. Nothing in a checkout should reveal anything about the machine it came from.
- **The public-repository check sits at whichever layer owns it, and the asymmetry is deliberate.** At *repository* scope it is RunPool's, because GitHub has no per-repository equivalent: `register` refuses by default, refuses again when visibility cannot be resolved, and takes `--allow-public` as an explicit, warned override. At *organisation* scope it is GitHub's: a runner group carries `allows_public_repositories`, it defaults to `false`, and runners land in the default group because `config.sh` is never passed `--runnergroup`. So RunPool reads and reports that setting and nothing more. **Do not enumerate an organisation's public repositories to re-derive the answer**, and do not "even up" the two branches. They differ because the controls differ. See `SECURITY.md`, which states this for users.

## Layout

```
bin/runpool          the executable, its dispatcher, its help text, and RUNPOOL_VERSION
lib/common.sh        config, logging, pool loading, launch agents, deregistration
lib/lifecycle.sh     register, set-count, up, down, reregister, rename, remove
lib/apply.sh         the pools file, and reconciling the machine to it
lib/scheduler.sh     status, doctor, autoscale, sweep, clean, schedule
lib/notify.sh        the optional notifier hook and what triggers it
lib/stats.sh         job durations from recorded telemetry, and queue times
                     via contrib/telemetry-join.sh
tests/               offline test scripts, every one of them run by CI
contrib/             optional pieces the user opts into: job hook, webhook notifier,
                     demo status fixture
skills/runpool/      agent skill for *using* runpool, shipped with the tool
assets/icon.svg      the icon, source of truth; PNGs are rendered from it
```

**`skills/runpool/` and this file have different audiences and must not converge.** This file is for changing runpool. The skill is for an agent wiring some other repository to it, choosing a scope, sizing a pool, or working out why a job is queued and nothing has picked it up. **If a change alters observable behaviour, the skill needs updating**; if it alters how the code is structured, this file does. The skill is a hub plus `SIZING.md` and `MIGRATION.md`; keep it that shape rather than growing SKILL.md back into one flat file.

**The split by concern is load-bearing**, not cosmetic. It is what lets the notifier be absent, and what keeps the pools file out of everything that does not read one. Keep new code in the part that owns the concern; if something does not fit, that is a signal the concern is new, not that the split is wrong.

## Conventions

- **Functions are prefixed `_rp_`.** Only the dispatcher in `bin/runpool` is public surface.
- **`set -uo pipefail`, deliberately without `-e`.** Most logic branches on exit status and the failures that matter are handled with explicit `|| return`. Do not add `-e`.
- **Sourced fragments carry `# shellcheck shell=bash`** on line one, because they have no shebang and shellcheck cannot infer the dialect otherwise.
- **Use `>|`, not `>`.** A shell with `noclobber` set refuses to truncate an existing file, which has silently broken this tool twice: once on the activity timestamp and once on launch agent rewriting.
- **Use `find`, not globs, over directories that may be empty.** An unmatched glob either expands to a literal or aborts the function depending on the shell.
- **Declare every `local` once, at the top of a function.** Re-declaring inside a loop makes some shells print it as a typeset assignment, which has leaked stray lines into logs.
- **A constant read in only one file belongs in that file.** shellcheck analyses each file independently, so one defined in `lib/common.sh` and read only in `bin/runpool` trips SC2034.
- **Comments explain why.** Most of the non-obvious lines here exist because something failed in a specific way, and the comment records that failure. Preserve those; they are the reason the code looks as it does.

## The launch agent carries behaviour, not just plumbing

**Two plist keys are load-bearing and neither looks it.** `RUNNER_MANUALLY_TRAP_SIG` is what makes GitHub's `run.sh` finish its current job on SIGTERM instead of dying with it, and `ExitTimeOut` is what stops launchd sending SIGKILL twenty seconds later. Together they are the whole of `--drain`; remove either and the drain silently becomes the job-killing behaviour it exists to replace.

**The consequence is that an agent already loaded is not necessarily an agent that behaves correctly.** A plist rewritten on disk changes nothing until the pool cycles. Anything depending on agent behaviour must therefore read the *loaded* environment with `launchctl print`, not the file. `_rp_agent_traps_signals` is the example, and `_rp_drain_pool` refuses per runner on the strength of it. The file on disk is what somebody intended; the loaded environment is what is true.

## The pool name is a label

**`POOL_LABELS` is the full list handed to `config.sh`, and the extras are derived back out of it.** There is deliberately no `POOL_EXTRA_LABELS`. A second field would be a frozen copy of `_rp_extra_labels`, and configs get edited by hand: the copy would go stale on the next hand edit and the following `apply` would silently revert it, which is the very defect `--labels` exists to fix.

- **`--labels` appends and cannot replace.** GitHub assigns `self-hosted`, the OS and the architecture to every self-hosted runner whatever it is told, so a replacing flag would promise something GitHub overrides. The pool name is in the base set too, because it is the routing contract.
- **An implicit label is refused, not dropped.** A token accepted and then normalised away would leave what the pools file declares and what the config holds permanently unequal, and `apply` would re-register the pool on every run.
- **Extras are compared sorted and stored in declared order.** Unlike `--watch`, which is compared as written: the costs are not symmetric, because a spurious watch difference is one file write and a spurious label difference stands the whole pool down.
- **`_rp_extra_labels` is tolerant and `_rp_valid_label` is strict.** The first runs against whatever a human left in a config and must only filter; the second guards the way in. That character class is what keeps a sourced config safe, `apply`'s `|` separator intact, and `rename`'s `find -name` free of globs.

## Renaming moves, and must deregister

**`rename` uses `mv`, unlike `migrate-storage`, which copies.** The copy there is because it crosses storage roots, where a partial copy is real and the old tree is the safety net. A rename keeps the same parent by construction, so `mv` is atomic and a second on-disk copy of runner credentials buys nothing.

- **It holds two locks, old then new, released in reverse.** From the moment the new config exists, `_rp_pool_names` returns it and autoscale would start it mid-rename. The second acquisition failing has to release the first.
- **`config.sh --replace` cannot help.** It replaces a registration of the same name, and the name is what changes, so GitHub keeps the old one: permanently offline, still carrying the old pool name as a label, and unreachable afterwards because `config.sh` overwrites the `.runner` holding its `agentId`. The old registrations are therefore deleted explicitly, before reconfiguring.
- **It iterates the runner directories that exist, not `1..POOL_COUNT`.** A count lowered by hand leaves higher-numbered runners on disk and registered; those are deregistered and deliberately not re-registered, which would be a permanent `miscount`.
- **`_rp_migrate_update_pool_conf` is not reusable here.** Its `END` clause adds `POOL_CACHE_DIR` when absent, and that absence is exactly how `_rp_load_pool` recognises a legacy pool. `rename` writes its own config instead, in one write, omitting the field when the pool did not have it.

## The stuck-queue guard subtracts, it does not suppress

**A queued run that never starts would otherwise wake a pool for ever**, every `RUNPOOL_IDLE_SECS` plus a tick, and nothing reports it because a pool that wakes and stands down is behaving as designed. `_rp_autoscale` therefore computes `queued > held` rather than deciding whether the pool is allowed to wake.

- **Never suppress the pool.** An org pool watches many repositories, and one dead run in one of them must not blind it to the rest. Subtracting is what keeps the blast radius to the single run.
- **A strike is earned only when `state/pools/<name>.started` has changed** since that run was last judged. That is the only available proof that waking for it achieved nothing. A tick count would give three strikes in three minutes to a pool that cannot start at all, and then refuse it real work once its agents were repaired; elapsed time would punish a laptop that slept through the night with work genuinely queued.
- **`_rp_stuck_advance`, `_rp_stuck_held` and `_rp_stuck_new_holds` are pure**, for the same reason `_rp_unwatched_repos` is: the rule is only testable at all when it is separate from the caller that needs GitHub.
- **The job count is corroboration, never a branch.** Zero jobs is the signature of the zombie case and it reads well in the message, but making the decision depend on a second API shape buys nothing the local rule does not already get right.
- **A held run says nothing on later ticks.** Only `_rp_stuck_new_holds` logs or notifies, or the loop this exists to end is replaced by a line a minute.

## The reconfiguration lock

**One per-pool lock covers resize and drain, and `up` and autoscale both respect it.** It was originally a resize lock; a drain needs the same exclusion for longer, so the concept widened rather than gaining a second flag to get out of step with.

- **The holder writes its pid into the lock.** `_rp_set_count_locked` calls `_rp_up` at the end of its own work while still holding the lock, so a test for mere existence would deadlock every resize against itself. `_rp_resize_locked_by_other` is the predicate to use.
- **Staleness is measured from the lock's mtime**, and a drain refreshes it every poll. So an old lock means nobody is tending it, not that the work is slow. Anything that can hold the lock for a long time must call `_rp_resize_lock_touch`.
- **`rename` holds two, old then new, released in reverse.** The lock directory carries the pool name, so one lock cannot cover both. They cannot deadlock, because `_rp_resize_lock` refuses rather than blocks, and the second acquisition failing must release the first.
- **A dead holder is not an obstacle.** It left the directory behind, and the stale break in `_rp_resize_lock` is what clears it.

## Configuration precedence

Environment, then config file, then built-in default. The config file uses plain assignments, so `lib/common.sh` snapshots any `RUNPOOL_*` already in the environment, sources the config, then restores the snapshot. **A new setting has to be added in four places in that block:** the snapshot, the restore, the `unset`, and the `export`. Otherwise it silently becomes un-overridable, or leaks a `_rp_env_*` variable, or fails to reach a child process.

`RUNPOOL_POOLS_FILE` is deliberately derived from `XDG_CONFIG_HOME` rather than from `RUNPOOL_CONFIG`'s directory, so that pointing the config at `/dev/null` to isolate a test does not also move the pools file somewhere unexpected. **The corollary is that neither `RUNPOOL_CONFIG` nor `RUNPOOL_BASE` isolates it:** it has to be set on its own, or overridden per run with `apply --file`. `/dev/null` is a valid value: `apply` tests for a readable non-directory rather than a regular file, so the isolation idiom means the same thing for both settings.

## Working on it

```bash
# Exactly what CI runs. Note tests/*.sh in both: omit it and CI checks more than you did.
/bin/bash -n bin/runpool lib/*.sh contrib/*.sh tests/*.sh install.sh
shellcheck --severity=warning bin/runpool lib/*.sh contrib/*.sh tests/*.sh install.sh

for t in tests/*.sh; do "$t" || break; done
```

Without shellcheck installed, Docker gives the same result and leaves nothing behind. Skipping the check is how CI goes red unnoticed:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  --severity=warning bin/runpool lib/*.sh contrib/*.sh tests/*.sh install.sh
```

**The tests run offline and make no API calls**, which is what makes them safe anywhere. A new test must keep that: fabricate pool configs under a scratch `RUNPOOL_BASE`, stub `gh` where a path needs it, and prefer a guard refused early over one that reaches the network. `tests/set-count-guards.sh` probes its lock case with a mismatched `--if-count` for that reason, since a real resize fetches the runner tarball first. `tests/stuck-queue-guard.sh` stubs `_rp_up` to move the started stamp by a counter rather than the clock, because the rule it exercises turns on that stamp changing and real seconds would mean sleeping through every cycle.

**Test against a scratch directory, never a real installation:**

```bash
RUNPOOL_BASE=/tmp/rp-test RUNPOOL_CONFIG=/dev/null ./bin/runpool status --json
```

**`RUNPOOL_BASE` does not move the pools file**, per *Configuration precedence* above. Anything touching `apply` needs `RUNPOOL_POOLS_FILE` or `--file` too, or it reads the real one and plans against real GitHub targets. `RUNPOOL_LOG_DIR` too, or the log lands in a real installation's. `CONTRIBUTING.md` has the full isolated invocation.

**`register`, `set-count`, `reregister` and `remove` talk to the real GitHub API and real runners.** None has a dry-run and there is nowhere sensible to add one, because the work *is* the API call. Verify destructive changes against a throwaway private repository, never while a job is in flight. The tool refuses on purpose, and forcing past that kills live jobs.

**`apply --dry-run` is the one exception, and only for the plan.** It reads the pools file and the pool configs, prints what it would do, and calls nothing, which makes all of `lib/apply.sh` testable with no GitHub account. What it does *not* cover: visibility is checked inside `register`, which a dry run never reaches, so a `+` line is a plan and not a promise.

## The icon

`assets/icon.svg` is the source. Re-render rather than editing a PNG:

```bash
rsvg-convert -w 512 -h 512 assets/icon.svg -o assets/icon.png
rsvg-convert -w 1024 -h 1024 assets/icon.svg -o assets/icon@1024.png
```

**ImageMagick cannot render it.** Its internal renderer silently drops the clip path and the outline, producing a bare wave. `rsvg-convert` from `librsvg` is required. Always look at the output before committing it.

The background is transparent and there are no baked-in rounded corners, so the mark works on light and dark and is never double-rounded by anything that masks it.

## Issues

**Every defect found gets a GitHub issue, including one fixed in the same session.** The issue is the record of what was wrong and why the fix looks the way it does; a commit message alone is not discoverable later. Close it referencing the commit.

The pattern is already established: configuration precedence was found and fixed in one sitting and still has an issue.

## Releases

`.github/workflows/release.yml` does the whole of it. There are two manual steps:

1. **Bump `RUNPOOL_VERSION` in `bin/runpool`** and land it on `main` with CI green. It is the only place a version is written.
2. **Cut an annotated tag and push it.** `git tag -a vX.Y.Z` then `git push origin vX.Y.Z`.

The workflow then re-runs the checks that gate `main`, attaches a source tarball to a GitHub release, and bumps the formula in the tap to point at it. Nothing else is done by hand.

**The tag message is the release notes.** There is no second copy anywhere: no `CHANGELOG.md`, nothing generated from commits, nothing typed into the GitHub UI afterwards. Write them where you cut the tag, and keep them short: a headline and a paragraph or two, plus any action the reader must take on upgrading. A reader wants to know what changed and whether it affects them; anyone who needs more than that can read the code. Left unstated, this drifts: the notes were once twenty words and had reached four hundred. **The workflow refuses a lightweight tag** for this reason, and the check is `git cat-file -t` rather than `for-each-ref`, because `for-each-ref` falls through to the *commit* message on a lightweight tag and would publish something plausible and wrong.

**The tag and `RUNPOOL_VERSION` must agree, and the workflow enforces it** before spending a macOS runner. A tag without a matching bump ships a binary that misreports itself, which was previously only a line in this file asking someone to remember.

**The release asset is a tarball built here, not GitHub's `archive/refs/tags` URL.** Those are generated on demand and their checksums are not contractually stable, which has broken formulae pinning them. `git archive | gzip -n` is reproducible, and the recorded `sha256` is of bytes we uploaded.

**The tap is updated last, and only after `brew audit --strict`, `brew install` and `brew test` pass against the edited formula.** That ordering is deliberate: if the tap step fails you have a real release and a stale formula, which is one job re-run away from fixed. The reverse would point the tap at a release that does not exist.

**`secrets.TAP_TOKEN` is a fine-grained PAT with `Contents: write` on the tap repository only.** It is the one credential in the release path, and the workflow refuses early when the secret is missing rather than discovering it at `git push`. **A token scoped to the wrong repository fails as a 403, not a 404**, because the tap is public: any token may read it, so one that does not list it still gets far enough to be denied the write. Read that error as a question about which repositories the token covers, not only about its permission level. However the credential ends up broken, the failure runs in the same direction: releases still publish, the tap quietly stops updating, and the symptom is machines sitting on an old version rather than anything going red.

**There is no `CHANGELOG.md`, deliberately.** The release notes on GitHub are the changelog and the README's release badge links to them. A copy in the repo would be a second thing to keep current and a second thing to disagree with the first. Do not add one.

**The formula installs `bin/` and `lib/` together under `libexec` and symlinks only the executable into `bin`.** The executable resolves its own location, following symlinks, to find `lib/` next to itself. Installing the script directly into `bin` puts `lib/` one directory too high and breaks it.

## This repository's own CI

**Pinned to GitHub-hosted runners, permanently. This applies to `release.yml` as much as to `ci.yml`.** This repo is public, so a pull request from an untrusted fork runs its own workflow file. RunPool refuses to register a public repository for exactly that reason, and it would be absurd for the tool to break its own rule. `--allow-public` exists for users who have weighed the risk on their own machine; it is not licence to point this repository at a pool.
