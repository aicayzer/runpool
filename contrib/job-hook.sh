#!/usr/bin/env bash
# Optional job hook — stamps machine state into every job on the pool.
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
# A non-zero exit from a job hook FAILS THE JOB, so nothing here may fail.
# Every command is guarded and the script always exits 0.
set -u

phase="${1:-started}"
load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1"/"$2"/"$3}')" || load="unknown"
cores="$(sysctl -n hw.ncpu 2>/dev/null)" || cores="?"
jobs="$(pgrep -f 'Runner.Worker' 2>/dev/null | wc -l | tr -d ' ')" || jobs="?"
free="$(df -h / 2>/dev/null | awk 'NR==2{print $4}')" || free="?"

line="runner ${RUNNER_NAME:-?}, load ${load} (1/5/15m), ${cores} cores, ${jobs} job(s) on this machine, ${free} disk free"

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

exit 0
