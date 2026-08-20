# Security

RunPool runs GitHub Actions jobs on a Mac you also use, as your own user. This file says plainly what that means, where the boundaries are, and the two places RunPool deliberately differs from GitHub's published hardening guidance.

## What a job on a RunPool runner can do

There is no VM and no container. A job runs as **your macOS user**, which means it can reach:

- **Your home directory**, including SSH keys, cloud credentials, and anything else readable without a prompt.
- **Your network**, including hosts reachable only from this machine.
- **The next job**, because runners are persistent and the working directory, caches and environment survive between jobs.

The whole arrangement therefore rests on one thing: **only code you trust ever runs on the pool.** Everything below is in service of that.

## Public repositories

A pull request from a fork runs its own copy of the workflow file. On a public repository that means any stranger can propose a workflow and have it execute here. GitHub says the same in stronger terms: self-hosted runners "should almost never be used for public repositories".

The control differs by scope, because GitHub's own controls do.

- **Repository scope: RunPool refuses, by default.** `runpool register --repo` checks visibility and stops on a public repository. GitHub has no per-repository equivalent of the setting described below, so this one is RunPool's to make. If visibility cannot be determined, registration is refused rather than assumed safe.
- **The refusal is a default, not a wall.** `--allow-public` proceeds anyway, with a warning that states the risk. A refusal with no way past it just moves the problem somewhere less visible, like a forked copy of the tool or a hand-registered runner. If you use the flag, pair it with fork pull request approval below, and understand you are accepting the risk described at the top of this file.
- **Organisation scope: GitHub's control, and it already defaults safely.** Each runner group carries `allows_public_repositories`, which is `false` by default, and runners RunPool registers land in the default group. A public repository in the organisation does not get those runners. RunPool reads that setting at register time and warns only if it has been turned on. It does not reimplement the check, because duplicating a control that already exists and already defaults correctly only creates a second thing to get wrong.

## Two deliberate differences from GitHub's guidance

### Persistent runners

GitHub recommends ephemeral runners and states that "autoscaling with persistent self-hosted runners is not recommended", so that each job starts from a clean environment.

**RunPool runners are persistent on purpose.** Warm caches, warm toolchains and an unchanged working directory are most of the reason a local runner beats a hosted one, and discarding them each time would remove the point of the tool.

**What that costs:** state leaks between jobs, and a job that compromises the runner stays compromised until you rebuild it. On a machine where every job comes from repositories you control, that is a reasonable trade. On a machine running code from people you do not know, it is not, and no setting in RunPool changes that.

### Fork pull requests on private repositories

GitHub warns that anyone able to fork a private repository and open a pull request, which generally means anyone with read access, can compromise a self-hosted runner. Keeping to private repositories reduces who that is; it does not reduce it to nobody.

**RunPool cannot enforce this.** The control is GitHub's, per repository, under **Settings → Actions → General → Fork pull request workflows**. Set it to require approval for outside or first-time contributors. If a repository has collaborators you would not hand a shell to, set it before pointing that repository at a pool.

## Why not just-in-time tokens

JIT configuration (`generate-jitconfig`) exists for ephemeral runners: one job, then automatic deregistration. RunPool registers persistently, so adopting JIT would mean re-registering every runner on every job, which is a different tool with a different lifecycle.

The exposure JIT would reduce here is a registration token that is valid for one hour and is never written to disk by RunPool. Without also going ephemeral, swapping it for JIT buys very little. This is a considered decision rather than an oversight; if RunPool ever grows an ephemeral mode, JIT is the right way to build it.

## What RunPool does with credentials

- **Registration tokens are never persisted.** One is requested per runner at register time, passed once to GitHub's `config.sh`, and exchanged by the runner for its own credentials. No RunPool file ever contains it.
- **A known, bounded exposure:** `config.sh` accepts the token only as a command-line argument, so it is briefly visible in `ps` output to other local users. RunPool cannot avoid this without upstream support from the runner.
- **The runner's own credentials** (`.credentials`, `.credentials_rsaparams`) are written and owned by GitHub's runner, in the runtime directory. RunPool neither reads nor relaxes them.
- **Keep the config file at mode 0600.** `~/.config/runpool/config` can hold `RUNPOOL_WEBHOOK_TOKEN`. The installer sets this; if you created the file by hand, set it yourself.
- **Nothing sensitive is logged.** Logs and the optional telemetry record timings, counts and machine state. Telemetry never leaves the machine.

## Reporting a vulnerability

Open a [security advisory](https://github.com/aicayzer/runpool/security/advisories/new) rather than a public issue. For anything low risk, a normal issue is fine.
