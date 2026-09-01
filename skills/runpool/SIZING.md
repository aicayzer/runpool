# How many runners should this machine have

Telemetry plus GitHub can answer this properly. `runpool stats` deliberately will not: it describes what jobs cost and stops there, because every analysis baked into the tool is a blind spot with a version number.

## Start with queue time

It is the only figure that moves when capacity changes. Duration says what a job costs and load says how contended the machine was; neither responds to another runner.

```bash
runpool stats --queue
```

Median and p90 of the wait before each job started, per `workflow / job`. It is behind a flag and not part of plain `stats` because it joins the local records to GitHub, one API call per run, where `stats` otherwise reads nothing but local files.

**Never quote the number without the qualifier it prints.** A queue time conflates three different situations and only one of them is a shortage of runners. On an on-demand pool the first job after a quiet spell always shows about a minute of queue while the pool wakes, and no amount of capacity removes it.

## Then go to the raw rows

```bash
contrib/telemetry-join.sh > joined.tsv
```

One row per job: duration, queue time, load at start, concurrency, and the raw created and started timestamps. Analyse that; do not trust a canned summary, `--queue` included.

**The join key is `run_id` plus runner name.** The job hook records the workflow's job id (`check`) while the API reports its display name, so those never match.

## Four traps, each of which has produced a confidently wrong answer

- **Grouping duration by concurrency measures workload shape, not contention.** A workflow runs fast gate jobs first and fans out to heavy ones, so the heavy jobs are always the ones at peak concurrency. The buckets contain different work and comparing them is meaningless. Compare *within* a job type, always.
- **Load is the better axis than concurrency.** Concurrency is pinned by the workflow's structure and barely varies. Load swings widely at the same concurrency depending on where sibling jobs are in their lifecycle, which gives real variation to correlate against. Note that load *at start* is a weak proxy for a job lasting several minutes.
- **Queue time is not one thing.** A wait can be a cold pool waking, a dependency that has not finished, or no free runner. Only the last is fixed by more runners. Separate them by reconstructing, from the started and completed times, whether the pool was ever full during that job's wait. If a runner sat free throughout, more runners would not have helped.
- **`created_at` is when the *run* was created, not when the job became runnable.** Every job in a workflow shares it, so occupancy at that instant is always zero and tells you nothing. Use the whole waiting interval.

## Contention

**The standard argument is that more runners is not more throughput**, because a single test job commonly forks one worker per core, so several in parallel thrash rather than run faster. Treat that as an argument, not a fact. It may hold on a given machine and it may not, and the difference is measurable.

**If red runs come and go, suspect contention before suspecting the code.** Lower the count with `runpool set-count <pool> N --drain` — a contended pool is by definition a busy one, so without `--drain` the resize is refused exactly when you need it — or cap per-job worker counts in the test runner. The job hook in `contrib/` stamps machine load into every job so this is visible rather than guessed at.

## The ceiling is not in the data

Nothing in the record says what eight runners would do on a machine that has only ever run four. That needs changing the count and watching.
