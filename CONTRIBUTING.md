# Contributing

Bug reports and pull requests are welcome. It is a small tool with a deliberately narrow scope, so the most useful thing you can do before writing code is open an issue and check the change belongs here.

## Scope

RunPool manages **capacity** on **one Mac**. Things that are out of scope by design, not by omission:

- **Routing.** A workflow's `runs-on` decides where a job lands. RunPool only decides whether runners are up.
- **Notification delivery.** It emits one JSON object to a command of your choosing and stops there.
- **Watching workflow results.** That should not depend on a laptop being awake.
- **Linux and Windows.** Both are well served by [actions-runner-controller](https://github.com/actions/actions-runner-controller) and [garm](https://github.com/cloudbase/garm).

## Working on it

`AGENTS.md` is the full guide: the hard constraints, the layout, and the traps. The short version:

- **Stock macOS bash 3.2.** No associative arrays, no `mapfile`, no `${var^^}`. It has to run on a machine where nobody has installed a newer bash.
- **No runtime dependencies beyond `gh`.** Adding one means everybody installing RunPool installs it too.
- **Sourced fragments start with `# shellcheck shell=bash`**, since they have no shebang.

Before opening a pull request:

```bash
/bin/bash -n bin/runpool lib/*.sh contrib/*.sh install.sh
shellcheck --severity=warning bin/runpool lib/*.sh contrib/*.sh install.sh
```

CI runs exactly that. If shellcheck is not installed, Docker gives the same answer and leaves nothing behind:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable \
  --severity=warning bin/runpool lib/*.sh contrib/*.sh install.sh
```

## Testing against a real machine

Most changes need runners, which means a GitHub account and a Mac. Two things make that less painful:

- **`contrib/demo-status.sh`** answers `status` with invented pools, so anything consuming the JSON can be developed with no runners at all.
- **`RUNPOOL_BASE`** points RunPool at a scratch directory, so you can register throwaway pools without touching a real setup. Environment beats config, deliberately, so a single invocation can be isolated.

## Commits and pull requests

Conventional Commits (`fix(stats): …`), one logical change per pull request, and a description that says what was wrong rather than what was edited. Issues get opened for defects found in passing and closed by the commit that fixes them.
