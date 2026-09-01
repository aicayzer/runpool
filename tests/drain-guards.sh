#!/bin/bash
# The guards around --drain, exercised without runners, launchd or GitHub.
#
# Every case here is refused, or driven through a stubbed _rp_busy_in, so
# nothing registers a runner, loads an agent or calls the API. The one thing
# this cannot cover is whether a real runner finishes its job on SIGTERM;
# that is verified by hand against a throwaway repository before release.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
trap 'rm -rf "${scratch_dir}"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$(( pass + 1 )); }

base_dir="${scratch_dir}/base"
mkdir -p "${base_dir}/pools" "${base_dir}/state" "${base_dir}/agents" \
         "${scratch_dir}/cache" "${scratch_dir}/config" "${scratch_dir}/logs"

cat >|"${base_dir}/pools/alpha.conf" <<CONF
POOL_SCOPE="repo"
POOL_TARGET="acme/widget"
POOL_COUNT="2"
POOL_DIR="${base_dir}/runners/alpha"
POOL_CACHE_DIR="${scratch_dir}/cache/pools/alpha"
POOL_LABELS="self-hosted,macOS,ARM64,alpha"
CONF

runpool() {
  env RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${scratch_dir}/cache" \
      RUNPOOL_CONFIG="${scratch_dir}/config/runpool.conf" \
      RUNPOOL_POOLS_FILE="${scratch_dir}/config/pools" \
      RUNPOOL_LOG_DIR="${scratch_dir}/logs" RUNPOOL_LOG="${scratch_dir}/logs/runpool.log" \
      "${repo_dir}/bin/runpool" "$@"
}

count_now() { sed -n 's/^POOL_COUNT="\(.*\)"$/\1/p' "${base_dir}/pools/alpha.conf"; }

assert_refused() {
  local what="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  [ "${rc}" -ne 0 ] || fail "${what}: exited 0, expected a refusal. Output: ${out}"
  [ "$(count_now)" = "2" ] || fail "${what}: POOL_COUNT changed to $(count_now)"
  ok
  echo "${out}"
}

# --- argument handling --------------------------------------------------------
# --timeout is a duration, so anything that is not a positive whole number of
# seconds has to be refused rather than silently becoming zero and turning a
# drain into an immediate give-up.
assert_refused "set-count --timeout with no value"  runpool set-count alpha 1 --drain --timeout >/dev/null
assert_refused "set-count --timeout non-numeric"    runpool set-count alpha 1 --drain --timeout abc >/dev/null
assert_refused "set-count --timeout zero"           runpool set-count alpha 1 --drain --timeout 0 >/dev/null
assert_refused "down --timeout with no value"       runpool down alpha --drain --timeout >/dev/null
assert_refused "down --timeout non-numeric"         runpool down alpha --drain --timeout abc >/dev/null
assert_refused "down unknown flag"                  runpool down alpha --no-such-flag >/dev/null
assert_refused "down trailing argument"             runpool down alpha extra >/dev/null
assert_refused "down with no pool"                  runpool down >/dev/null

# --drain waits for jobs and --force ends them. Accepting both would have to
# silently pick one, and either choice is wrong half the time.
out=$(assert_refused "down --drain with --force" runpool down alpha --drain --force)
case "${out}" in
  *"pick one"*) ok ;;
  *) fail "down --drain --force: unhelpful message: ${out}" ;;
esac

# --- the busy refusal names the way through ------------------------------------
# The whole point of this release: the old message told you to wait, which on a
# continuously busy pool is not a remedy.
grep -q -- "--drain" "${repo_dir}/lib/lifecycle.sh" || fail "lifecycle.sh no longer mentions --drain"
for msg in "refusing to resize" "refusing to stand down"; do
  grep -A0 "${msg}" "${repo_dir}/lib/lifecycle.sh" | grep -q -- "--drain" \
    || fail "the '${msg}' message does not name --drain as the way through"
  ok
done

# --- the plist carries what the drain depends on -------------------------------
# Without these two keys a drain kills the job it is trying to protect, so they
# are behaviour rather than formatting.
plist_probe() (
  export RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${scratch_dir}/cache" \
         RUNPOOL_CONFIG=/dev/null RUNPOOL_POOLS_FILE="${scratch_dir}/config/pools" \
         RUNPOOL_LOG_DIR="${scratch_dir}/logs" RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" >/dev/null 2>&1
  _rp_write_plist "probe.label" "${base_dir}/runners/alpha/runner-1" "${scratch_dir}/cache/x" 0
  cat "${RUNPOOL_AGENT_DIR}/probe.label.plist"
)
plist="$(plist_probe)" || fail "_rp_write_plist failed"
case "${plist}" in
  *RUNNER_MANUALLY_TRAP_SIG*) ok ;;
  *) fail "the plist has no RUNNER_MANUALLY_TRAP_SIG, so unloading kills the job" ;;
esac
case "${plist}" in
  *ExitTimeOut*) ok ;;
  *) fail "the plist has no ExitTimeOut, so launchd SIGKILLs the job after ~20s" ;;
esac
# Zero means infinity and the man page warns it can stall shutdown forever.
printf '%s\n' "${plist}" | grep -A1 ExitTimeOut | grep -q '<integer>0</integer>' \
  && fail "ExitTimeOut is 0, which means infinity"
ok

# --- the reconfiguration lock --------------------------------------------------
# Driven in the sourced subshell rather than a fresh `bash -c`: shell
# functions do not survive an exec, so a spawned shell cannot see any of this.
lock_probe() (
  export RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${scratch_dir}/cache" \
         RUNPOOL_CONFIG=/dev/null RUNPOOL_POOLS_FILE="${scratch_dir}/config/pools" \
         RUNPOOL_LOG_DIR="${scratch_dir}/logs" RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" >/dev/null 2>&1
  eval "$1"
)

# A holder must not block itself: _rp_set_count_locked calls _rp_up at the end
# of its own work, while still holding the lock it took.
lock_probe '
  _rp_resize_lock alpha >/dev/null 2>&1 || exit 1
  _rp_resize_locked_by_other alpha && exit 1   # own pid: not an obstacle
  _rp_resize_unlock alpha
  exit 0
' || fail "the lock blocks its own holder, which would deadlock every resize"
ok

# A different, live process holding it is an obstacle. The stand-in has to be
# a process this user owns: kill -0 against another user\'s pid fails with
# EPERM even when it exists, so pid 1 would look dead.
lock_probe '
  sleep 30 & holder=$!
  disown "${holder}" 2>/dev/null
  mkdir -p "$(_rp_resize_lock_dir alpha)"
  echo "${holder}" >| "$(_rp_resize_lock_dir alpha)/pid"
  _rp_resize_locked_by_other alpha; held=$?
  kill "${holder}" 2>/dev/null
  _rp_resize_unlock alpha
  exit "${held}"
' || fail "a lock held by another live process was not detected"
ok

# A holder that died is not an obstacle: it left the directory behind and the
# stale break is what clears it. Treating it as held would wedge the pool.
lock_probe '
  mkdir -p "$(_rp_resize_lock_dir alpha)"
  echo 999999 >| "$(_rp_resize_lock_dir alpha)/pid"
  _rp_resize_locked_by_other alpha && exit 1
  _rp_resize_unlock alpha
  exit 0
' || fail "a lock left by a dead process is being treated as held"
ok

# A long drain refreshes the lock. Staleness is measured from the mtime, so
# without the touch a drain outliving the stale window invites a second caller
# to break its lock and start resizing underneath it.
lock_probe '
  lock="$(_rp_resize_lock_dir alpha)"
  mkdir -p "${lock}"
  touch -t 200001010000 "${lock}"
  before=$(stat -f %m "${lock}")
  _rp_resize_lock_touch alpha
  after=$(stat -f %m "${lock}")
  _rp_resize_unlock alpha
  [ "${after}" -gt "${before}" ]
' || fail "_rp_resize_lock_touch did not refresh the lock"
ok

# `up` refuses while another process holds the lock, which is what stops a
# second terminal or the tick restarting a pool mid-drain.
lock_probe '
  . "'"${repo_dir}"'/lib/lifecycle.sh" >/dev/null 2>&1
  sleep 30 & holder=$!
  disown "${holder}" 2>/dev/null
  mkdir -p "$(_rp_resize_lock_dir alpha)"
  echo "${holder}" >| "$(_rp_resize_lock_dir alpha)/pid"
  out=$(_rp_up alpha 2>&1); rc=$?
  kill "${holder}" 2>/dev/null
  _rp_resize_unlock alpha
  [ "${rc}" = "0" ] && exit 1
  case "${out}" in *"being reconfigured"*) exit 0 ;; *) exit 1 ;; esac
' || fail "up did not refuse while another process held the lock"
ok

# --- the drain loop, against a stubbed busy count ------------------------------
# _rp_busy_in is a function, so the wait can be driven without a runner. The
# pool has no agents loaded here, so the unload pass is a no-op and the stale
# agent check has nothing to refuse.
drain_probe() (
  export RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${scratch_dir}/cache" \
         RUNPOOL_CONFIG=/dev/null RUNPOOL_POOLS_FILE="${scratch_dir}/config/pools" \
         RUNPOOL_LOG_DIR="${scratch_dir}/logs" RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" >/dev/null 2>&1
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/lifecycle.sh" >/dev/null 2>&1
  _rp_load_pool alpha
  eval "$1"
  _rp_drain_pool alpha "$2"
)

# Busy forever: must give up at the bound rather than waiting indefinitely.
out=$(drain_probe '_rp_busy_in() { echo 1; }' 5 2>&1) && fail "a drain that never quiesced returned success"
case "${out}" in
  *"no longer waiting"*) ok ;;
  *) fail "timed-out drain did not say so: ${out}" ;;
esac
# The runners are already stopped at that point, so the message has to say what
# is still true rather than implying nothing happened.
case "${out}" in
  *"already stopped"*) ok ;;
  *) fail "timed-out drain did not say the runners are already stopped: ${out}" ;;
esac

# Nothing running: returns at once.
drain_probe '_rp_busy_in() { echo 0; }' 5 >/dev/null 2>&1 || fail "an idle pool did not drain immediately"
ok

# Busy, then quiet: the normal case.
# The counter lives in a file, not a variable: _rp_busy_in is called inside a
# command substitution, so anything it assigns dies with that subshell.
out=$(drain_probe '
  echo 0 >| "'"${scratch_dir}"'/ticks"
  _rp_busy_in() {
    local n; n=$(( $(cat "'"${scratch_dir}"'/ticks") + 1 ))
    echo "${n}" >| "'"${scratch_dir}"'/ticks"
    [ "${n}" -gt 2 ] && echo 0 || echo 1
  }' 60 2>&1) || fail "a pool that quiesced did not drain: ${out}"
case "${out}" in
  *"every job finished"*) ok ;;
  *) fail "successful drain did not report completion: ${out}" ;;
esac

# --- doctor answers "would a drain work here" ---------------------------------
# The predicate doctor reports on. Without it the only way to find out is to
# attempt the drain, which is the thing being checked.
type_probe() (
  export RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${scratch_dir}/cache" \
         RUNPOOL_CONFIG=/dev/null RUNPOOL_POOLS_FILE="${scratch_dir}/config/pools" \
         RUNPOOL_LOG_DIR="${scratch_dir}/logs" RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" >/dev/null 2>&1
  eval "$1"
)

# An agent that is not loaded cannot be mid-job, so it is not reported.
type_probe '_rp_agent_loaded() { return 1; }
            _rp_agent_traps_signals() { return 1; }
            _rp_agent_loaded x && exit 1
            exit 0' || fail "an unloaded agent should not be reported as un-drainable"
ok

# The two states doctor distinguishes.
type_probe '_rp_agent_traps_signals() { return 0; }; _rp_agent_traps_signals x' \
  || fail "a trapping agent was not recognised"
ok
type_probe '_rp_agent_traps_signals() { return 1; }; _rp_agent_traps_signals x' \
  && fail "a non-trapping agent was recognised as trapping"
ok

# doctor must report it rather than fail it: such a pool runs and takes work
# perfectly well, and only draining is affected.
grep -q "only draining is affected" "${repo_dir}/lib/scheduler.sh" \
  || fail "doctor does not say that a non-drainable pool still works normally"
ok
grep -B4 "only draining is affected" "${repo_dir}/lib/scheduler.sh" | grep -q "_rp_doctor_note" \
  || fail "drain readiness should be a note, not a failure"
ok

echo "ok: ${pass} case(s)"
