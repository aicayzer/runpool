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

# --- a pool being reconfigured is not judged --------------------------------
# set-count, reregister and rename all delete registrations and create them
# again. A check landing in that window can see none and report a deliberate
# operation as an outage, at critical, to whoever holds the lock and already
# knows. Asserted by call count, because the point is that GitHub is not asked
# at all rather than asked and forgiven.
mkdir -p "${RUNPOOL_BASE}/pools" "${scratch_dir}/bin"
cat >"${RUNPOOL_BASE}/pools/alpha.conf" <<CONF
POOL_SCOPE="repo"
POOL_TARGET="acme/widget"
POOL_COUNT="1"
POOL_DIR="${RUNPOOL_BASE}/runners/alpha"
POOL_CACHE_DIR="${RUNPOOL_CACHE_DIR}/pools/alpha"
CONF
cat >"${scratch_dir}/bin/gh" <<STUB
#!/bin/bash
echo call >> "${scratch_dir}/gh-calls"
echo "0 0"
STUB
chmod +x "${scratch_dir}/bin/gh"
export PATH="${scratch_dir}/bin:${PATH}"
gh_calls() { awk 'NF { n++ } END { print n + 0 }' "${scratch_dir}/gh-calls" 2>/dev/null || echo 0; }

# shellcheck source=/dev/null
. "${repo_dir}/lib/notify.sh"
: >"${scratch_dir}/gh-calls"

# A lock held by a live process that is not us, which is what
# _rp_resize_locked_by_other tests for. It has to be a real running pid: $$
# reads as our own lock and is deliberately ignored, and a pid we cannot
# signal reads as a dead holder, which is equally deliberate.
sleep 60 &
holder=$!
mkdir -p "$(_rp_resize_lock_dir alpha)"
echo "${holder}" >"$(_rp_resize_lock_dir alpha)/pid"
rm -f "${RUNPOOL_HEALTH_STATE}"
_rp_health_check >/dev/null 2>&1
check "a pool mid-reconfiguration is not asked about" "0" "$(gh_calls)"

kill "${holder}" 2>/dev/null; wait "${holder}" 2>/dev/null
rm -rf "$(_rp_resize_lock_dir alpha)"
rm -f "${RUNPOOL_HEALTH_STATE}"
_rp_health_check >/dev/null 2>&1
[ "$(gh_calls)" -gt 0 ] || fail "an unlocked pool should still be judged"
pass=$(( pass + 1 ))

# --- where the window's own setting comes from ------------------------------
# Precedence is environment, then config file, then default, and every setting
# has to be threaded through the snapshot-source-restore block to get it. This
# one was defined outside that block for a long time, which inverted it: a
# value in the config beat one in the environment, the opposite of every other
# setting and of what the documentation says.
#
# Each case is a subshell that sources the library fresh, because precedence is
# decided once at load time.
setting_in() {
  ( export RUNPOOL_BASE RUNPOOL_CACHE_DIR RUNPOOL_POOLS_FILE RUNPOOL_LOG_DIR RUNPOOL_LOG
    export RUNPOOL_CONFIG="$1"
    if [ -n "${2:-}" ]; then export RUNPOOL_SETTLE_SECS="$2"; else unset RUNPOOL_SETTLE_SECS; fi
    # shellcheck source=/dev/null
    . "${repo_dir}/lib/common.sh" 2>/dev/null || true
    echo "${RUNPOOL_SETTLE_SECS}" )
}
conf="${scratch_dir}/precedence.conf"
printf 'RUNPOOL_SETTLE_SECS=222\n' >"${conf}"

check "the default applies with neither set"     "120" "$(setting_in /dev/null "")"
check "the config file beats the default"        "222" "$(setting_in "${conf}" "")"
check "the environment beats the config file"    "333" "$(setting_in "${conf}" 333)"
check "and the environment beats the default"    "333" "$(setting_in /dev/null 333)"

echo "ok: ${pass} case(s)"
