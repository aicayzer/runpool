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
# Requires RUNPOOL_TELEMETRY=1 and the job hook. Reads only local files.

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

_rp_stats() {
  local f rows n_done first last cores peak_load total key median p90 runs

  f="$(_rp_stats_file)"

  if [ ! -s "${f}" ]; then
    echo "No telemetry recorded yet."
    echo ""
    echo "Enable it in ${RUNPOOL_CONFIG}:"
    echo "  RUNPOOL_JOB_HOOK=\"/path/to/runpool/contrib/job-hook.sh\""
    echo "  RUNPOOL_TELEMETRY=1"
    echo ""
    echo "Then: runpool rewrite-agents && runpool down-all"
    echo "Data accrues as jobs run. It records timings and machine state only."
    return 0
  fi

  n_done=$(grep -c '"phase":"completed"' "${f}" 2>/dev/null || echo 0)
  if [ "${n_done}" -eq 0 ]; then
    echo "Telemetry is recording, but no job has completed yet."
    echo "  starts recorded: $(grep -c '"phase":"started"' "${f}" 2>/dev/null || echo 0)"
    return 0
  fi

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
  echo "  contrib/telemetry-join.sh > joined.tsv"
  echo ""
  echo "  records: ${f}"
}

# Seconds to something readable.
_rp_stats_dur() {
  local s="${1:-0}"
  case "${s}" in ''|*[!0-9]*) echo "-"; return ;; esac
  if [ "${s}" -lt 60 ]; then echo "${s}s"
  elif [ "${s}" -lt 3600 ]; then echo "$(( s / 60 ))m$(( s % 60 ))s"
  else echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; fi
}
