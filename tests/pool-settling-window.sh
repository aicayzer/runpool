#!/bin/bash
# The rule that separates a pool which has just started from a broken one.
#
# A runner reaches GitHub a second or two after launchd starts it. Until it
# does, a healthy pool presents exactly the numbers a broken one does: agents
# up locally, nothing online at GitHub. `_rp_gh_state` is the single judgement
# both `status` and the notifier read, so the distinction is tested here rather
# than through either of them.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
trap 'rm -rf "${scratch_dir}"' EXIT INT TERM

# Every path the library reads at load time points into a scratch directory, so
# nothing here can see or touch a real installation.
export RUNPOOL_BASE="${scratch_dir}/base"
export RUNPOOL_STATE_DIR="${scratch_dir}/state"
export RUNPOOL_CACHE_DIR="${scratch_dir}/cache"
export RUNPOOL_CONFIG="${scratch_dir}/runpool.conf"
export RUNPOOL_POOLS_FILE="${scratch_dir}/pools"
export RUNPOOL_LOG_DIR="${scratch_dir}/logs"
export RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
export RUNPOOL_AGENT_DIR="${scratch_dir}/agents"
mkdir -p "${RUNPOOL_BASE}" "${RUNPOOL_STATE_DIR}" "${RUNPOOL_CACHE_DIR}" \
         "${RUNPOOL_LOG_DIR}" "${RUNPOOL_AGENT_DIR}"

# shellcheck source=/dev/null
. "${repo_dir}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "${repo_dir}/lib/scheduler.sh"

mkdir -p "${RUNPOOL_POOL_STATE_DIR}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass=$(( pass + 1 ))
  else
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

# --- the state decision -----------------------------------------------------
#             registered online running expected settling

check "a pool up and connected is ok" \
  "ok" "$(_rp_gh_state 3 3 3 3 0)"

check "runners up and none online is offline once settled" \
  "offline" "$(_rp_gh_state 3 0 3 3 0)"

# The regression this file exists for. The same numbers, inside the window.
check "the same numbers inside the settling window are a start, not an outage" \
  "starting" "$(_rp_gh_state 3 0 3 3 1)"

# A pruned registration is true regardless of how recently the pool started, so
# the window must not swallow it: this is the failure that queues jobs forever.
check "an unregistered pool still reports while settling" \
  "unregistered" "$(_rp_gh_state 0 0 3 3 1)"

check "an unreachable GitHub is never a pool fault, settling or not" \
  "unreachable" "$(_rp_gh_state '?' '?' 3 3 1)"

# Absent fifth argument means not settling, so an older caller cannot silently
# turn every offline pool into a start.
check "omitting the settling argument reports offline" \
  "offline" "$(_rp_gh_state 3 0 3 3)"

# --- the window itself ------------------------------------------------------

_rp_pool_settling acme && fail "a pool that has never started is not settling"
pass=$(( pass + 1 ))

_rp_touch_pool_started acme
_rp_pool_settling acme || fail "a pool started just now is settling"
pass=$(( pass + 1 ))

# Stamped further back than the window, which is how every pool spends all but
# its first two minutes.
echo "$(( $(_rp_now) - RUNPOOL_SETTLE_SECS - 1 ))" >| "$(_rp_pool_started_flag acme)"
_rp_pool_settling acme && fail "a pool started before the window is not settling"
pass=$(( pass + 1 ))

# A truncated or hand-mangled stamp must not read as "started at the epoch"
# and must not read as settling forever either.
echo "not-a-number" >| "$(_rp_pool_started_flag acme)"
_rp_pool_settling acme && fail "an unreadable stamp is not settling"
pass=$(( pass + 1 ))

echo "ok: ${pass} case(s)"
