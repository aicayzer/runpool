# shellcheck shell=bash
# stats.sh — summarise recorded job telemetry.
#
# This exists to answer one question with data instead of folklore: how many
# runners should this machine have?
#
# The received wisdom is that a test job forks roughly one worker per core, so
# several jobs at once thrash rather than run faster. That is plausible, it is
# repeated confidently in this project's own documentation, and nobody has ever
# measured it on a real machine. A number arrived at by argument is worth less
# than a slow one arrived at by observation.
#
# What it reports: how long jobs actually took, grouped by how many jobs were
# running when each one started. If duration stays flat as concurrency rises,
# the machine is coping and the runner count could go up. If it climbs faster
# than concurrency, the pool is oversubscribed and should come down.
#
# Requires RUNPOOL_TELEMETRY=1 and the job hook. Reads only local files.

_rp_stats_file() { echo "${RUNPOOL_BASE}/telemetry/jobs.jsonl"; }

# Pull one numeric field out of a telemetry line. The file is machine-written
# with a fixed shape, so a targeted match is safe and avoids needing jq.
_rp_stats_field() {
  sed -n "s/.*\"$1\":\([0-9][0-9.]*\).*/\1/p"
}

_rp_stats() {
  local f n_done first last c durs count median p90 total_secs peak_load cores
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

  first=$(head -1 "${f}" | _rp_stats_field ts)
  last=$(tail -1 "${f}" | _rp_stats_field ts)
  cores=$(tail -1 "${f}" | _rp_stats_field cores)
  peak_load=$(grep '"phase":"started"' "${f}" | _rp_stats_field load1 | sort -rn | head -1)

  echo "Jobs completed: ${n_done}"
  echo "Window:         $(date -r "${first}" '+%Y-%m-%d %H:%M') to $(date -r "${last}" '+%Y-%m-%d %H:%M')"
  echo "Machine:        ${cores} cores, peak 1-minute load ${peak_load} while a job was starting"
  echo ""
  echo "Duration by how many jobs were running when this one started:"
  echo ""
  printf "  %-12s %-7s %-10s %-10s\n" "concurrent" "jobs" "median" "p90"

  # One pass per concurrency level. The dataset is one line per job, so this
  # stays cheap long past the point where the answer stops changing.
  for c in $(grep '"phase":"completed"' "${f}" | _rp_stats_field concurrent | sort -un); do
    durs=$(grep '"phase":"completed"' "${f}" \
           | grep "\"concurrent\":${c}," \
           | grep -v '"duration":null' \
           | _rp_stats_field duration | sort -n)
    [ -n "${durs}" ] || continue
    count=$(printf '%s\n' "${durs}" | wc -l | tr -d ' ')
    median=$(printf '%s\n' "${durs}" | awk -v n="${count}" 'NR==int((n+1)/2){print; exit}')
    p90=$(printf '%s\n' "${durs}" | awk -v n="${count}" 'NR>=n*0.9{print; exit}')
    printf "  %-12s %-7s %-10s %-10s\n" "${c}" "${count}" "$(_rp_stats_dur "${median}")" "$(_rp_stats_dur "${p90}")"
  done

  total_secs=$(grep '"phase":"completed"' "${f}" | grep -v '"duration":null' \
               | _rp_stats_field duration | awk '{s+=$1} END {print s+0}')
  echo ""
  echo "  total job time: $(_rp_stats_dur "${total_secs}")"
  echo ""
  echo "Read it like this: if the median holds steady as concurrency rises, the"
  echo "machine is coping and the runner count could go up. If it climbs faster"
  echo "than concurrency does, the pool is oversubscribed. A row with only a"
  echo "handful of jobs is not yet evidence of anything."
}

# Seconds to something readable.
_rp_stats_dur() {
  local s="${1:-0}"
  case "${s}" in ''|*[!0-9]*) echo "-"; return ;; esac
  if [ "${s}" -lt 60 ]; then echo "${s}s"
  elif [ "${s}" -lt 3600 ]; then echo "$(( s / 60 ))m$(( s % 60 ))s"
  else echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; fi
}
