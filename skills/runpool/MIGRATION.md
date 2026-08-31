# Storage migration

New installations keep runner credentials, pool definitions and pause state in `~/Library/Application Support/runpool`, with work trees and per-runner caches in `~/Library/Caches/runpool` and logs in `~/Library/Logs/runpool`. Generated job-hook launchers stay under `~/.config/runpool`, whose path is safe for the runner's unquoted Bash hook invocation.

**Installations predating this layout keep working until explicitly migrated**, so upgrading never silently strands registrations.

## The sequence

```bash
runpool migrate-storage --dry-run
runpool migrate-storage
runpool status --local
runpool doctor
```

Only after verifying the new installation:

```bash
runpool migrate-storage --remove-legacy
```

For a custom legacy `RUNPOOL_BASE`, use the exact `--from` and `--to` command that migration prints rather than composing one:

```bash
runpool migrate-storage --from /old/runpool \
  --to "$HOME/Library/Application Support/runpool" --remove-legacy
```

## What it does, and what it deliberately discards

- **It refuses while a job is running**, stopping only idle runners and preserving registrations and the legacy tree.
- **Runner state is copied** into Application Support, and reusable package stores move into Caches.
- **Work and temp directories start empty.** Build products can embed their former absolute path, so carrying them across would produce failures that look like code problems.
- **Each runner's absolute work folder is rewritten** and the launch agents are regenerated.
- **The legacy tree is retained** until `--remove-legacy` is run. Remove it only after `status --local` and `doctor` both look right.

## Do not

- **Do not run migration while a job is active.** RunPool refuses, and forcing past that kills live jobs.
- **Do not remove the legacy tree in the same step as migrating.** The retention is the rollback.
