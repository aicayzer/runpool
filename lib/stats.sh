# shellcheck shell=bash
# stats.sh — summarise recorded job telemetry.
#
# This exists to answer one question with data instead of folklore: how many
# runners should this machine have?
#
# The received wisdom is that a test job forks roughly one worker per core, so
# several at once thrash rather than run faster. That is plausible, it is
# repeated confidently in this project's own documentation, and nobody has ever
# measured it on a real machine.
#
# The trap is that grouping durations by concurrency alone answers a different
# question than the one being asked. CI workflows have a fixed shape: a couple
# of fast gates, then a fan-out of heavy jobs. The heavy jobs are therefore the
# ones running when concurrency is highest, and a naive table shows durations
# climbing steeply with concurrency on a machine that is coping perfectly well.
# It is the workload changing, not the machine struggling.
#
# So the headline here is the like-for-like comparison: the same job type at
# different concurrency levels. Everything else is descriptive, and is labelled
# as such.
#
# Requires RUNPOOL_TELEMETRY=1 and the job hook. Reads only local files.

_rp_stats_file() { echo "${RUNPOOL_BASE}/telemetry/jobs.jsonl"; }

# Pull one numeric field out of a telemetry line. The file is machine-written
# with a fixed shape, so a targeted match is safe and avoids needing jq.
_rp_stats_field() {
  sed -n "s/.*\"$1\":\([0-9][0-9.]*\).*/\1/p"
}

# Flatten completed jobs to "duration<TAB>concurrent<TAB>workflow / job".
#
# Fields are matched by name rather than by position, so reordering anything in
# the hook cannot silently produce nonsense here.
_rp_stats_rows() {
  awk '
    function jstr(line, key,   s) {
      if (!match(line, "\"" key "\":\"[^\"]*\"")) return ""
      s = substr(line, RSTART, RLENGTH)
      sub("^\"" key "\":\"", "", s); sub("\"$", "", s)
      return s
    }
    function jnum(line, key,   s) {
      if (!match(line, "\"" key "\":-?[0-9]+")) return ""
      s = substr(line, RSTART, RLENGTH)
      sub("^\"" key "\":", "", s)
      return s
    }
    /"phase":"completed"/ {
      d = jnum($0, "duration"); c = jnum($0, "concurrent")
      if (d == "" || c == "") next
      printf "%s\t%s\t%s / %s\n", d, c, jstr($0, "workflow"), jstr($0, "job")
    }
  ' "$1"
}

# Median and p90 of the durations on stdin, as "median<TAB>p90<TAB>count".
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
  local f rows n_done first last cores peak_load comparable

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

  _rp_stats_like_for_like "${rows}"
  comparable=$?

  _rp_stats_by_concurrency "${rows}"
  _rp_stats_by_job "${rows}"
  _rp_stats_verdict "${comparable}"
}

# The only fair comparison: one job type, run at more than one concurrency.
# Returns the number of job types that qualify, so the verdict can be honest
# about whether anything has been established.
_rp_stats_like_for_like() {
  local rows="$1" keys key levels c n=0 solid

  echo ""
  echo "Same job, different concurrency"
  echo "-------------------------------"

  # Job types seen at two or more concurrency levels.
  keys=$(printf '%s\n' "${rows}" | awk -F'\t' '{print $3 "\t" $2}' | sort -u \
         | awk -F'\t' '{c[$1]++} END {for (k in c) if (c[k] > 1) print k}' | sort)

  if [ -z "${keys}" ]; then
    echo "  Nothing to compare. Every job type so far has only ever run at one"
    echo "  concurrency level, so no pair of numbers here differs by concurrency"
    echo "  alone."
    return 0
  fi

  printf '  %-32s %s\n' "job" "median at each concurrency"
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    levels=""; solid=0
    for c in $(printf '%s\n' "${rows}" | awk -F'\t' -v k="${key}" '$3 == k {print $2}' | sort -un); do
      set -- $(printf '%s\n' "${rows}" \
               | awk -F'\t' -v k="${key}" -v c="${c}" '$3 == k && $2 == c {print $1}' \
               | _rp_stats_quantiles)
      [ "$3" -ge 3 ] && solid=$(( solid + 1 ))
      levels="${levels}  c=${c}: $(_rp_stats_dur "$1") (n=$3)"
    done
    # Only a job with a real sample at two or more levels has measured
    # anything. The rest are shown because they are the closest thing to
    # evidence available, not because they are evidence.
    [ "${solid}" -ge 2 ] && n=$(( n + 1 ))
    printf '  %-32s%s\n' "${key}" "${levels}"
  done <<EOF
${keys}
EOF
  return "${n}"
}

_rp_stats_by_concurrency() {
  local rows="$1" c median p90 count shared

  echo ""
  echo "By concurrency, for reference only"
  echo "----------------------------------"
  printf '  %10s %6s %10s %10s\n' "concurrent" "jobs" "median" "p90"

  for c in $(printf '%s\n' "${rows}" | awk -F'\t' '{print $2}' | sort -un); do
    set -- $(printf '%s\n' "${rows}" | awk -F'\t' -v c="${c}" '$2 == c {print $1}' | _rp_stats_quantiles)
    median="$1"; p90="$2"; count="$3"
    printf '  %10s %6s %10s %10s\n' "${c}" "${count}" \
      "$(_rp_stats_dur "${median}")" "$(_rp_stats_dur "${p90}")"
  done

  # The warning that makes the table safe to look at. If the busiest and
  # quietest levels have no job type in common, the difference between their
  # rows is workload, and reading it as contention is simply wrong.
  shared=$(_rp_stats_shared_types "${rows}")
  echo ""
  if [ "${shared}" -eq 0 ]; then
    echo "  Do not read a trend down this column. The busiest and quietest levels"
    echo "  here have no job type in common, so the rows describe different work,"
    echo "  not the same work under different load."
  else
    echo "  ${shared} job type(s) appear at both the busiest and quietest levels,"
    echo "  so some of this difference is comparable. The table above is still"
    echo "  the sounder guide."
  fi
}

# How many job types appear at both the lowest and highest concurrency seen.
_rp_stats_shared_types() {
  printf '%s\n' "$1" | awk -F'\t' '
    { seen[$3 "\t" $2] = 1; if (min == "" || $2 < min) min = $2; if ($2 > max) max = $2 }
    END {
      if (min == max) { print 0; exit }
      for (k in seen) {
        split(k, p, "\t")
        if (p[2] == min) lo[p[1]] = 1
        if (p[2] == max) hi[p[1]] = 1
      }
      n = 0
      for (j in lo) if (j in hi) n++
      print n
    }
  '
}

_rp_stats_by_job() {
  local rows="$1" key

  echo ""
  echo "By job type"
  echo "-----------"
  printf '  %-32s %6s %10s %10s\n' "job" "runs" "median" "p90"

  printf '%s\n' "${rows}" | awk -F'\t' '{print $3}' | sort -u | while IFS= read -r key; do
    [ -n "${key}" ] || continue
    set -- $(printf '%s\n' "${rows}" | awk -F'\t' -v k="${key}" '$3 == k {print $1}' | _rp_stats_quantiles)
    printf '  %-32s %6s %10s %10s\n' "${key}" "$3" \
      "$(_rp_stats_dur "$1")" "$(_rp_stats_dur "$2")"
  done
}

_rp_stats_verdict() {
  echo ""
  echo "What this can tell you"
  echo "----------------------"
  if [ "${1:-0}" -eq 0 ]; then
    echo "  Not yet whether the runner count is right. That needs one job type"
    echo "  measured properly at two different concurrency levels, and nothing"
    echo "  has been so far: where the same job has run at two levels at all, one"
    echo "  side of the comparison rests on a run or two."
    echo ""
    echo "  Waiting alone will not fix this. A workflow has a fixed shape, so it"
    echo "  keeps producing the same jobs at the same concurrency however long it"
    echo "  runs. Change the count deliberately, leave it for a week, and compare"
    echo "  the same job across the two settings."
  else
    echo "  Read the first table only. If a job takes about the same time at"
    echo "  higher concurrency, the machine is coping and the count could go up."
    echo "  If it takes materially longer, the pool is oversubscribed. Anything"
    echo "  with a handful of runs behind it is not yet evidence of much."
  fi
}

# Seconds to something readable.
_rp_stats_dur() {
  local s="${1:-0}"
  case "${s}" in ''|*[!0-9]*) echo "-"; return ;; esac
  if [ "${s}" -lt 60 ]; then echo "${s}s"
  elif [ "${s}" -lt 3600 ]; then echo "$(( s / 60 ))m$(( s % 60 ))s"
  else echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"; fi
}
