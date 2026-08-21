# shellcheck shell=bash
# stats.sh — what recorded jobs actually cost.
#
# Deliberately a description rather than an analysis.
#
# This began as an attempt to answer "how many runners should this machine
# have" in bash, and that was the wrong shape for the problem. Every analysis
# hard-coded here is a blind spot with a version number, and the first one
# shipped confidently reported a contention effect that turned out to be an
# artefact of how CI workflows are structured. The raw records joined to GitHub
# can answer the question properly. A fixed table cannot.
#
# So this prints what a person wants at a glance and points at the data, and
# at the tool that joins it. See contrib/telemetry-join.sh.
#
# Requires RUNPOOL_TELEMETRY=1 and the job hook. Reads only local files, with
# one deliberate exception: `--queue` runs contrib/telemetry-join.sh, which asks
# GitHub for the wait the hook cannot see. That is precisely why it is a flag
# and not part of the default readout.

_rp_stats_file() { echo "${RUNPOOL_BASE}/telemetry/jobs.jsonl"; }

# Pull one numeric field out of a telemetry line. The file is machine-written
# with a fixed shape, so a targeted match is safe and avoids needing jq.
_rp_stats_field() {
  sed -n "s/.*\"$1\":\([0-9][0-9.]*\).*/\1/p"
}

# Completed jobs as "duration<TAB>workflow / job". Fields are matched by name
# rather than by position, so reordering anything in the hook cannot silently
# produce nonsense here.
_rp_stats_rows() {
  awk '
    function jstr(l, k,   s) {
      if (!match(l, "\"" k "\":\"[^\"]*\"")) return ""
      s = substr(l, RSTART, RLENGTH); sub("^\"" k "\":\"", "", s); sub("\"$", "", s); return s
    }
    function jnum(l, k,   s) {
      if (!match(l, "\"" k "\":-?[0-9]+")) return ""
      s = substr(l, RSTART, RLENGTH); sub("^\"" k "\":", "", s); return s
    }
    /"phase":"completed"/ {
      d = jnum($0, "duration")
      if (d == "") next
      printf "%s\t%s / %s\n", d, jstr($0, "workflow"), jstr($0, "job")
    }
  ' "$1"
}

# Median, p90 and count of the durations on stdin.
_rp_stats_quantiles() {
  sort -n | awk '
    { d[NR] = $1 }
    END {
      if (NR == 0) { print "-\t-\t0"; exit }
      printf "%d\t%d\t%d\n", d[int((NR + 1) / 2)], d[NR < 10 ? NR : int(NR * 0.9) + 1], NR
    }
  '
}

# Both readouts need the same two things to exist. Explains itself and returns
# non-zero when they do not, so either caller can simply stop.
_rp_stats_have_data() {
  local f="$1"
  if [ ! -s "${f}" ]; then
    echo "No telemetry recorded yet."
    echo ""
    echo "Enable it in ${RUNPOOL_CONFIG}:"
    echo "  RUNPOOL_JOB_HOOK=\"/path/to/runpool/contrib/job-hook.sh\""
    echo "  RUNPOOL_TELEMETRY=1"
    echo ""
    echo "Then: runpool rewrite-agents && runpool down-all"
    echo "Data accrues as jobs run. It records timings and machine state only."
    return 1
  fi
  if [ "$(grep -c '"phase":"completed"' "${f}" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "Telemetry is recording, but no job has completed yet."
    echo "  starts recorded: $(grep -c '"phase":"started"' "${f}" 2>/dev/null || echo 0)"
    return 1
  fi
  return 0
}

_rp_stats() {
  local arg queue=0 f
  for arg in "$@"; do
    case "${arg}" in
      --queue) queue=1 ;;
      *) _rp_err "unknown flag: ${arg} (usage: runpool stats [--queue])"; return 1 ;;
    esac
  done
  f="$(_rp_stats_file)"
  # Missing data is explained, not an error: nothing is wrong with a machine
  # that has not switched telemetry on.
  _rp_stats_have_data "${f}" || return 0
  if [ "${queue}" = "1" ]; then _rp_stats_queue "${f}"; else _rp_stats_local "${f}"; fi
}

_rp_stats_local() {
  local f="$1" rows n_done first last cores peak_load total key median p90 runs

  n_done=$(grep -c '"phase":"completed"' "${f}" 2>/dev/null || echo 0)
  rows="$(_rp_stats_rows "${f}")"
  first=$(head -1 "${f}" | _rp_stats_field ts)
  last=$(tail -1 "${f}" | _rp_stats_field ts)
  cores=$(tail -1 "${f}" | _rp_stats_field cores)
  peak_load=$(grep '"phase":"started"' "${f}" | _rp_stats_field load1 | sort -rn | head -1)

  printf 'Jobs completed  %s\n' "${n_done}"
  printf 'Window          %s to %s\n' \
    "$(date -r "${first}" '+%-d %b %H:%M')" "$(date -r "${last}" '+%-d %b %H:%M')"
  printf 'Machine         %s cores, peak 1-minute load %s while a job was starting\n' \
    "${cores}" "${peak_load}"

  echo ""
  printf '  %-34s %6s %10s %10s\n' "job" "runs" "median" "p90"
  printf '%s\n' "${rows}" | awk -F'\t' '{print $2}' | sort -u | while IFS= read -r key; do
    [ -n "${key}" ] || continue
    # Split on the tab the quantile helper emits, rather than on `set --` with
    # an unquoted expansion. Same result, without relying on word splitting.
    IFS="$(printf '\t')" read -r median p90 runs <<EOF
$(printf '%s\n' "${rows}" | awk -F'\t' -v k="${key}" '$2 == k {print $1}' | _rp_stats_quantiles)
EOF
    printf '  %-34s %6s %10s %10s\n' "${key}" "${runs}" \
      "$(_rp_stats_dur "${median}")" "$(_rp_stats_dur "${p90}")"
  done

  total=$(printf '%s\n' "${rows}" | awk -F'\t' '{s+=$1} END {print s+0}')
  echo ""
  printf '  %-34s %6s %10s\n' "total job time" "" "$(_rp_stats_dur "${total}")"

  echo ""
  echo "This is a description, not an analysis. Grouping these durations by how"
  echo "many jobs were running looks like it measures contention and does not:"
  echo "a workflow runs its fast gates first and fans out to its heavy jobs, so"
  echo "the heavy jobs are always the ones at high concurrency."
  echo ""
  echo "To work out what this machine actually wants, join these records to what"
  echo "GitHub knows about the same runs, which adds the queue times the job"
  echo "hook cannot see:"
  echo ""
  echo "  runpool stats --queue           median and p90 queue time, per job"
  echo "  contrib/telemetry-join.sh       one row per job, everything joined"
  echo ""
  echo "  records: ${f}"
}

# ---------------------------------------------------------------------------
# --queue — the wait before a runner picked the job up
# ---------------------------------------------------------------------------
# Queue time is the figure that answers "do I need more runners", because more
# runners help if and only if work is waiting. The job hook fires when a runner
# *picks a job up*, so the whole wait before that moment is invisible locally
# and only GitHub knows it.
#
# BEHIND A FLAG, and not part of plain `runpool stats`. The header of this file
# says it reads only local files; the join makes one gh api call per unique run.
# A network fan-out behind a command people run casually is exactly the failure
# `status --json --local` exists to prevent, so the two readouts stay separate.
#
# contrib/telemetry-join.sh is INVOKED, not reimplemented here. It carries two
# correctness traps that took working out — run id plus runner name matches
# several API jobs and needs the nearest-start tie-break, and created_at is
# run-level rather than job-level — and a second copy is a second place to get
# them wrong.
_rp_stats_queue() {
  local f="$1" join joined rows n key median p90 runs
  _rp_require gh || return 1

  # RUNPOOL_ROOT is resolved by bin/runpool, following symlinks, and is visible
  # to everything it sources. The Homebrew formula installs contrib/ beside
  # bin/ and lib/ under libexec, so this resolves for a tap install too.
  join="${RUNPOOL_ROOT:-}/contrib/telemetry-join.sh"
  [ -x "${join}" ] || {
    _rp_err "cannot run ${join} — contrib/ ships with runpool; check the install, or chmod +x it"
    return 1
  }

  echo "Joining the local records to GitHub: one API call per run, so give it a moment."
  echo ""
  # The telemetry path is passed explicitly. Left to work it out, the script
  # falls back to `runpool status --json --local` and picks up whatever runpool
  # is on PATH, which is not necessarily the one being run.
  joined="$("${join}" "${f}" 2>/dev/null)" || {
    _rp_err "the join failed — run '${join} ${f}' directly to see why"
    return 1
  }

  # Reshaped to the same "value<TAB>workflow / job" that _rp_stats_rows emits,
  # so the grouping below is the grouping the duration table already uses.
  # Column 6 is queue_s, 2 is workflow, 3 is job; NR > 1 drops the header.
  rows="$(printf '%s\n' "${joined}" \
          | awk -F'\t' 'NR > 1 && NF >= 6 && $6 ~ /^-?[0-9]+$/ { printf "%s\t%s / %s\n", $6, $2, $3 }')"
  n=$(printf '%s\n' "${rows}" | grep -c . )

  if [ "${n}" -eq 0 ]; then
    echo "The join produced no rows."
    echo ""
    echo "Every record has to match a job GitHub still has, and run history is"
    echo "kept for a limited time, so records older than that no longer join."
    echo "Run it directly to see what came back:"
    echo ""
    echo "  ${join} ${f}"
    return 0
  fi

  printf 'Queue time      %s job record(s) joined to GitHub\n' "${n}"
  echo ""
  printf '  %-34s %6s %10s %10s\n' "job" "runs" "median" "p90"
  printf '%s\n' "${rows}" | awk -F'\t' '{print $2}' | sort -u | while IFS= read -r key; do
    [ -n "${key}" ] || continue
    # Split on the tab the quantile helper emits, as the duration table does.
    IFS="$(printf '\t')" read -r median p90 runs <<EOF
$(printf '%s\n' "${rows}" | awk -F'\t' -v k="${key}" '$2 == k {print $1}' | _rp_stats_quantiles)
EOF
    printf '  %-34s %6s %10s %10s\n' "${key}" "${runs}" \
      "$(_rp_stats_dur "${median}")" "$(_rp_stats_dur "${p90}")"
  done

  # The qualifier ships with the number, every time and not as a footnote.
  # queue_s conflates three different things and only one of them is fixed by
  # capacity. This file exists in its present form because a canned analysis
  # already shipped a confidently wrong answer on exactly this, and a bare
  # "median queue 47s" is that blind spot again with a new number on it.
  echo ""
  echo "A queue time is not one thing. A wait can be a cold pool waking, a"
  echo "dependency that has not finished, or no free runner — and only the last"
  echo "is fixed by more runners. On an on-demand pool the first job after a"
  echo "quiet spell always shows about a minute of queue while the pool starts,"
  echo "and no amount of capacity removes it."
  echo ""
  echo "To tell them apart, reconstruct from the created and started epochs"
  echo "whether the pool was ever full during a job's wait. If a runner sat free"
  echo "throughout, more runners would not have helped:"
  echo ""
  echo "  ${join} ${f} > joined.tsv"
}

# Seconds to something readable.
_rp_stats_dur() {
  local s="${1:-0}"
  case "${s}" in ''|*[!0-9]*) echo "-"; return ;; esac
  if [ "${s}" -lt 60 ]; then echo "${s}s"
  elif [ "${s}" -lt 3600 ]; then echo "$(( s / 60 ))m$(( s % 60 ))s"
  else echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; fi
}
