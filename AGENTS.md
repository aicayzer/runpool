# Agent instructions for RunPool

Guidance for an agent changing this repository. The README is for people *using* RunPool; this file is for whoever is *editing* it.

## What this is

A single-purpose macOS CLI that manages pools of self-hosted GitHub Actions runners. It controls **capacity only**: whether runners are running. Where a job lands is decided by the workflow's `runs-on` and is none of this tool's business.

Plain shell. No build step, no dependencies to install, no package manager.

## Hard constraints

Break any of these and the tool stops being what it is.

- **Bash 3.2.** Stock macOS ships bash 3.2 and the tool must run there. No associative arrays, no `mapfile`/`readarray`, no `${var^^}`, no `&>>`. CI parses every file under `/bin/bash` on a macOS runner to enforce this.
- **macOS only.** launchd, `sysctl`, `~/Library` paths, the `osx-arm64` runner build. Do not add Linux or Windows support: that case is already well served by actions-runner-controller and garm, and serving it would mean competing where there is no gap.
- **No notifier.** `lib/notify.sh` writes one JSON object to whatever `RUNPOOL_NOTIFY_CMD` names. It must never grow mail sending, address routing, severity policy, dedup windows, or a dependency on a particular service. An earlier version of this tool had all of those and it is exactly why it could not be published.
- **No workflow-result watching.** Reporting on failed CI runs is observability and belongs to whatever receives the notifications, which can poll GitHub without depending on a laptop being awake. This tool reports only on the health of the pool itself.
- **Nothing personal in the repository.** No real organisation names, repository names, hostnames, addresses or paths, in code, comments, docs or examples. Use `acme` / `acme-inc` / `me/side-project`. Installation specifics belong in the user's config file, never here.
- **No secrets, ever.** Registration credentials live in the runtime directory, which is outside this repo by design. Nothing in a checkout should reveal anything about the machine it came from.

## Layout

```
bin/runpool          the executable and its dispatcher
lib/common.sh        config, logging, pool loading, launch agents, deregistration
lib/lifecycle.sh     register, set-count, up, down, reregister, remove
lib/scheduler.sh     status, autoscale, sweep, clean, schedule
lib/notify.sh        the optional notifier hook and what triggers it
contrib/             optional pieces the user opts into: job hook, webhook notifier,
                     demo status fixture
skills/runpool/      agent skill for *using* runpool, shipped with the tool
assets/icon.svg      the icon, source of truth; PNGs are rendered from it
```

**`skills/runpool/SKILL.md` and this file have different audiences and must not converge.** This file is for changing runpool. The skill is for an agent wiring some other repository to it, choosing a scope, or working out why a job is queued and nothing has picked it up. If a change alters observable behaviour, the skill needs updating; if it alters how the code is structured, this file does.

**The three-way split is load-bearing**, not cosmetic. It is what lets the notifier be absent. Keep new code in the part that owns the concern; if something does not fit, that is a signal the concern is new, not that the split is wrong.

## The icon

`assets/icon.svg` is the source. Re-render rather than editing a PNG:

```bash
rsvg-convert -w 512 -h 512 assets/icon.svg -o assets/icon.png
rsvg-convert -w 1024 -h 1024 assets/icon.svg -o assets/icon@1024.png
```

**ImageMagick cannot render it.** Its internal renderer silently drops the clip path and the outline, producing a bare wave. `rsvg-convert` from `librsvg` is required. Always look at the output before committing it.

The background is transparent and there are no baked-in rounded corners, so the mark works on light and dark and is never double-rounded by anything that masks it.

## Conventions

- **Functions are prefixed `_rp_`.** Only the dispatcher in `bin/runpool` is public surface.
- **`set -uo pipefail`, deliberately without `-e`.** Most logic branches on exit status and the failures that matter are handled with explicit `|| return`. Do not add `-e`.
- **Sourced fragments carry `# shellcheck shell=bash`** on line one, because they have no shebang and shellcheck cannot infer the dialect otherwise.
- **Use `>|`, not `>`.** A shell with `noclobber` set refuses to truncate an existing file, which has silently broken this tool twice: once on the activity timestamp and once on launch agent rewriting.
- **Use `find`, not globs, over directories that may be empty.** An unmatched glob either expands to a literal or aborts the function depending on the shell.
- **Declare every `local` once, at the top of a function.** Re-declaring inside a loop makes some shells print it as a typeset assignment, which has leaked stray lines into logs.
- **Comments explain why.** Most of the non-obvious lines here exist because something failed in a specific way, and the comment records that failure. Preserve those; they are the reason the code looks as it does.

## Configuration precedence

Environment, then config file, then built-in default. The config file uses plain assignments, so `lib/common.sh` snapshots any `RUNPOOL_*` already in the environment, sources the config, then restores the snapshot. **If you add a setting, add it to both lists**, or it silently becomes un-overridable.

## Working on it

```bash
/bin/bash -n bin/runpool lib/*.sh contrib/*.sh install.sh   # parse under stock bash
shellcheck --severity=warning bin/runpool lib/*.sh contrib/*.sh install.sh

# CI runs exactly that. Without shellcheck installed, Docker gives the same
# result and leaves nothing behind — skipping the check is how CI goes red
# unnoticed:
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  --severity=warning bin/runpool lib/*.sh contrib/*.sh install.sh
```

**Test against a scratch directory, never a real installation:**

```bash
RUNPOOL_BASE=/tmp/rp-test RUNPOOL_CONFIG=/dev/null ./bin/runpool status --json
```

**Anything that registers, resizes or removes a pool talks to the real GitHub API and to real runners.** There is no dry-run. Verify destructive changes against a throwaway private repository, and never while a job is in flight — the tool refuses on purpose, and forcing past that kills live jobs.

## Issues

**Every defect found gets a GitHub issue, including one fixed in the same session.** The issue is the record of what was wrong and why the fix looks the way it does; a commit message alone is not discoverable later. Close it referencing the commit.

The pattern is already established: configuration precedence was found and fixed in one sitting and still has an issue.

## Releases

1. Land the change on `main` with CI green.
2. `git tag -a vX.Y.Z` and push the tag.
3. `gh release create vX.Y.Z` with notes describing what changed for a user.
4. Update the Homebrew formula in the tap repository: bump `url` to the new tag and recompute `sha256` from the release tarball.
5. `brew audit --strict` and `brew test` against the formula before pushing it.

**The formula installs `bin/` and `lib/` together under `libexec` and symlinks only the executable into `bin`.** The executable resolves its own location, following symlinks, to find `lib/` next to itself. Installing the script directly into `bin` puts `lib/` one directory too high and breaks it.

## This repository's own CI

**Pinned to GitHub-hosted runners, permanently.** This repo is public, so a pull request from an untrusted fork runs its own workflow file. RunPool refuses to register a public repository for exactly that reason, and it would be absurd for the tool to break its own rule.
