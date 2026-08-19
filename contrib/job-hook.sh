#!/usr/bin/env bash
# Optional job hook — stamps machine state into every job, and optionally
# records it locally so the right runner count can be measured rather than
# guessed.
#
# A self-hosted pool shares one machine with everything else on it, and several
# branches pushed together turn that machine into a queue. Timing-sensitive
# tests then fail for reasons that have nothing to do with the code, and in a
# log a contended failure and a genuine defect look identical. This makes them
# distinguishable by writing down what the machine was doing at the time.
#
# A runner hook rather than a workflow step on purpose: it covers every
# repository on the pool automatically, needs no per-workflow edit, and cannot
# be forgotten when someone adds a new workflow.
#
# Enable by setting RUNPOOL_JOB_HOOK to this file's absolute path in
# ~/.config/runpool/config, then: runpool rewrite-agents && runpool down-all
#
# Set RUNPOOL_TELEMETRY=1 as well and each job also appends one JSON line to
# <base>/telemetry/jobs.jsonl. That is what `runpool stats` reads. It records
# nothing about the code, only timings and machine state, and it never leaves
# the machine.
#
# A non-zero exit from a job hook FAILS THE JOB, so nothing here may fail.
# Every command is guarded and the script always exits 0.
set -u

phase="${1:-started}"

# Resolve config the same way the CLI does, since launchd gives the hook none
# of the shell environment.
RUNPOOL_CONFIG="${RUNPOOL_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/runpool/config}"
# shellcheck disable=SC1090
[ -f "${RUNPOOL_CONFIG}" ] && . "${RUNPOOL_CONFIG}" 2>/dev/null
RUNPOOL_BASE="${RUNPOOL_BASE:-${XDG_DATA_HOME:-${HOME}/.local/share}/runpool}"
RUNPOOL_TELEMETRY="${RUNPOOL_TELEMETRY:-0}"

load1="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')" || load1="0"
loadall="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1"/"$2"/"$3}')" || loadall="unknown"
cores="$(sysctl -n hw.ncpu 2>/dev/null)" || cores="0"
# Concurrent jobs across the whole machine, which is what actually competes for
# CPU. Includes this one.
jobs="$(pgrep -f 'Runner.Worker' 2>/dev/null | wc -l | tr -d ' ')" || jobs="0"
free="$(df -h / 2>/dev/null | awk 'NR==2{print $4}')" || free="?"

line="runner ${RUNNER_NAME:-?}, load ${loadall} (1/5/15m), ${cores} cores, ${jobs} job(s) on this machine, ${free} disk free"

# The job log is where a failure actually gets read.
echo "[runpool ${phase}] ${line}"

# And the run summary when the runner exposes it, so a reader sees it without
# opening the log at all.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY:-/nonexistent}" ]; then
  {
    echo ""
    echo "**Machine at job ${phase}** — ${line}"
  } >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Telemetry, opt-in
# ---------------------------------------------------------------------------
# Duration is measured locally rather than read back from the API, so the data
# needs no network and no token. The start time is parked in a per-runner file:
# a runner executes one job at a time, so its name is a safe key.
if [ "${RUNPOOL_TELEMETRY}" = "1" ]; then
  tdir="${RUNPOOL_BASE}/telemetry"
  mkdir -p "${tdir}/inflight" 2>/dev/null
  now="$(date +%s)"
  key="${tdir}/inflight/$(echo "${RUNNER_NAME:-unknown}" | tr -c 'A-Za-z0-9_.-' '_')"

  # Concurrency at the START is what the job actually competed against, so it
  # is parked with the start time and carried forward. Measuring it at
  # completion would report how busy the machine was as the job finished,
  # which is a different and much less useful number.
  if [ "${phase}" = "started" ]; then
    echo "${now} ${jobs}" >| "${key}" 2>/dev/null
    duration="null"
    at_start="${jobs}"
  else
    marker="$(cat "${key}" 2>/dev/null || echo '')"
    if [ -n "${marker}" ]; then
      duration=$(( now - ${marker%% *} ))
      at_start="${marker##* }"
      rm -f "${key}" 2>/dev/null
    else
      duration="null"
      at_start="${jobs}"
    fi
  fi

  # Hand-assembled JSON. Every value is either a number or a GitHub-supplied
  # identifier, so none of them can contain a character needing escaping.
  printf '{"ts":%s,"phase":"%s","runner":"%s","repo":"%s","workflow":"%s","job":"%s","run_id":"%s","concurrent":%s,"load1":%s,"cores":%s,"duration":%s}\n' \
    "${now}" "${phase}" "${RUNNER_NAME:-unknown}" \
    "${GITHUB_REPOSITORY:-unknown}" "${GITHUB_WORKFLOW:-unknown}" "${GITHUB_JOB:-unknown}" \
    "${GITHUB_RUN_ID:-0}" "${at_start:-0}" "${load1:-0}" "${cores:-0}" "${duration}" \
    >> "${tdir}/jobs.jsonl" 2>/dev/null || true
fi

exit 0
