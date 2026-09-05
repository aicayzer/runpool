#!/usr/bin/env bash
# telemetry-join.sh: one row per job, with everything needed to reason about
# runner count. Joins local telemetry to what GitHub knows about the same run.
#
# This deliberately does no analysis. It plumbs, and leaves the thinking to
# whoever reads the output. Every conclusion baked into a tool like this is a
# blind spot with a version number, and the interesting questions here are not
# known in advance.
#
# What it adds that telemetry alone cannot: queue time. The job hook fires when
# a runner picks a job up, so everything before that moment is invisible
# locally. GitHub records when the job was created, and the gap between the two
# is the wait. That is the figure that actually answers "do I have enough
# runners", because more runners help if and only if work is waiting.
#
# Read that gap carefully: on an on-demand pool a cold start also shows up as
# queue time, and the remedy for a cold start is not more runners. The
# concurrent column is what separates them. See skills/runpool/SKILL.md.
#
# The join key is run_id plus runner name. The job hook records the workflow's
# job id ("check") while the API reports its display name ("Flag documented
# -surface PRs without a docs companion"), so those two never match.
#
# The raw created and started epochs are emitted alongside queue_s on purpose.
# The concurrent column records how busy the machine was when a job *started*,
# which is not the same as when it was *queued*, and only the latter can say
# whether a wait was a shortage of runners. Reconstructing that needs the
# timestamps.
#
# One API call per run, so the run count is the cost. That cost is bounded two
# ways: only runs inside the window are fetched, and the calls run in parallel.
# Unbounded and serial, a year of telemetry is not slow but unfinishable, and a
# command with no output is indistinguishable from a hung one while it happens.
#
# Usage:  telemetry-join.sh [path/to/jobs.jsonl] [--days N | --all] > joined.tsv
# Env:    RUNPOOL_JOIN_JOBS   concurrent API calls (default 8)
# Needs:  gh, authenticated. Reads GitHub; changes nothing anywhere.

set -euo pipefail

TELEMETRY=""
DAYS=7

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)  DAYS=0 ;;
    --days) shift; DAYS="${1:-}"
            case "${DAYS}" in
              ''|*[!0-9]*) echo "--days needs a whole number of days" >&2; exit 1 ;;
            esac
            [ "${DAYS}" -gt 0 ] || { echo "--days needs a number above zero (use --all for no limit)" >&2; exit 1; } ;;
    --*)    echo "unknown flag: $1 (usage: telemetry-join.sh [file] [--days N | --all])" >&2; exit 1 ;;
    *)      TELEMETRY="$1" ;;
  esac
  shift
done

if [ -z "${TELEMETRY}" ]; then
  TELEMETRY="$(runpool status --json --local 2>/dev/null \
    | sed -n 's/.*"telemetry":"\([^"]*\)".*/\1/p')"
fi

[ -s "${TELEMETRY}" ] || { echo "no telemetry at: ${TELEMETRY:-<unset>}" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# --- local side: one row per completed job, carrying start-time machine state
awk '
  function jstr(l, k,   s) {
    if (!match(l, "\"" k "\":\"[^\"]*\"")) return ""
    s = substr(l, RSTART, RLENGTH); sub("^\"" k "\":\"", "", s); sub("\"$", "", s); return s
  }
  function jnum(l, k,   s) {
    if (!match(l, "\"" k "\":-?[0-9.]+")) return ""
    s = substr(l, RSTART, RLENGTH); sub("^\"" k "\":", "", s); return s
  }
  {
    id = jstr($0, "run_id") "|" jstr($0, "job")
    if ($0 ~ /"phase":"started"/) {
      repo[id]   = jstr($0, "repo");     wf[id]   = jstr($0, "workflow")
      runner[id] = jstr($0, "runner");   conc[id] = jnum($0, "concurrent")
      load[id]   = jnum($0, "load1");    cores[id] = jnum($0, "cores")
      run[id]    = jstr($0, "run_id");   job[id]  = jstr($0, "job")
      began[id]  = jnum($0, "ts")
    }
    if ($0 ~ /"phase":"completed"/) dur[id] = jnum($0, "duration")
  }
  END {
    for (id in dur) {
      if (!(id in run)) continue   # completed without a matching start
      printf "%s|%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        run[id], runner[id], id, repo[id], wf[id], job[id], runner[id],
        dur[id], load[id], conc[id], cores[id], began[id]
    }
  }
' "${TELEMETRY}" | sort > "${work}/local.tsv"

# --- window: a run outside it is dropped before it can cost an API call
if [ "${DAYS}" -gt 0 ]; then
  cutoff=$(( $(date +%s) - DAYS * 86400 ))
  awk -F'\t' -v c="${cutoff}" '$11 >= c' "${work}/local.tsv" > "${work}/windowed.tsv"
  mv "${work}/windowed.tsv" "${work}/local.tsv"
fi

# --- remote side: created and started, per runner, per run
#
# Each worker writes its own file rather than a shared pipe: concurrent writers
# interleave mid-line, and a torn row here would silently corrupt the join.
awk -F'\t' '{split($1, p, "|"); print $3 "\t" p[1]}' "${work}/local.tsv" \
  | sort -u > "${work}/runs.tsv"
total="$(grep -c . "${work}/runs.tsv" || true)"
jobs="${RUNPOOL_JOIN_JOBS:-8}"

if [ "${DAYS}" -gt 0 ]; then
  printf 'Joining %s run(s) from the last %s day(s), %s calls at a time.\n' \
    "${total}" "${DAYS}" "${jobs}" >&2
else
  printf 'Joining all %s run(s), %s calls at a time.\n' "${total}" "${jobs}" >&2
fi

mkdir -p "${work}/out"
export JOIN_OUT="${work}/out"
_join_fetch() {
  gh api "repos/$1/actions/runs/$2/jobs" --paginate \
    --jq ".jobs[] | [\"$2|\" + .runner_name,
                     (.created_at | fromdateiso8601),
                     (.started_at | fromdateiso8601)] | @tsv" \
    > "${JOIN_OUT}/$2" 2>/dev/null || true
  printf '.' >&2
}
export -f _join_fetch

if [ "${total}" -gt 0 ]; then
  xargs -P "${jobs}" -n2 bash -c '_join_fetch "$0" "$1"' < "${work}/runs.tsv"
  printf '\n' >&2
fi
find "${work}/out" -type f -exec cat {} + 2>/dev/null | sort > "${work}/remote.tsv"

# --- join, then keep one remote row per local job
#
# A runner takes several jobs in a run, one after another, so run_id plus
# runner name matches more than one API job and the raw join fans out. The
# right remote row is the one whose start time is nearest the moment the hook
# fired, which is what the tie-break below picks.
printf 'repo\tworkflow\tjob\trunner\tduration_s\tqueue_s\tload_at_start\tconcurrent\tcores\tcreated_epoch\tstarted_epoch\n'
join -t"$(printf '\t')" -j1 "${work}/local.tsv" "${work}/remote.tsv" \
  | awk -F'\t' '
      # $1 key, $2 uniq, $3 repo, $4 workflow, $5 job, $6 runner, $7 dur,
      # $8 load, $9 conc, $10 cores, $11 began, $12 created, $13 started
      {
        gap = $13 - $11; if (gap < 0) gap = -gap
        if (!($2 in best) || gap < best[$2]) {
          best[$2] = gap
          row[$2]  = sprintf("%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%d\t%d",
                             $3, $4, $5, $6, $7, $13 - $12, $8, $9, $10, $12, $13)
        }
      }
      END { for (k in row) print row[k] }
    ' | sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3
