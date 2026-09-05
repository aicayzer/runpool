#!/bin/bash
# The guard that stops autoscale waking a pool for a run that will never start.
#
# Two halves. The first exercises the pure rule directly, because that is where
# every judgement lives and none of it needs GitHub. The second drives one
# autoscale loop with `_rp_up` and `_rp_running_in` stubbed, which is what
# makes a wake cycle deterministic and keeps launchd out of it.
#
# Offline: gh is stubbed and nothing here reaches GitHub.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
bin_dir="${scratch_dir}/bin"
trap 'rm -rf "${scratch_dir}"' EXIT INT TERM

export RUNPOOL_BASE="${scratch_dir}/base"
export RUNPOOL_STATE_DIR="${scratch_dir}/base/state"
export RUNPOOL_CACHE_DIR="${scratch_dir}/cache"
export RUNPOOL_CONFIG="${scratch_dir}/runpool.conf"
export RUNPOOL_POOLS_FILE="${scratch_dir}/pools"
export RUNPOOL_LOG_DIR="${scratch_dir}/logs"
export RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
export RUNPOOL_AGENT_DIR="${scratch_dir}/agents"
mkdir -p "${RUNPOOL_BASE}/pools" "${RUNPOOL_STATE_DIR}/pools" "${RUNPOOL_CACHE_DIR}" \
         "${RUNPOOL_LOG_DIR}" "${RUNPOOL_AGENT_DIR}" "${bin_dir}"

# shellcheck source=/dev/null
. "${repo_dir}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "${repo_dir}/lib/scheduler.sh"
# shellcheck source=/dev/null
. "${repo_dir}/lib/notify.sh"
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
strikes_for() { printf '%s\n' "$1" | awk -v k="$2" '$2 == k { print $3 }'; }
count() { printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'; }

# ---------------------------------------------------------------------------
# the pure rule
# ---------------------------------------------------------------------------
NOW=1000000
ONE=$'acme/widget 111'
TWO=$'acme/widget 111\nacme/gadget 222'

# First sight is never a strike: a run nobody has judged yet is work, and the
# pool must wake for it however old it is. This is the overnight case, where a
# laptop that slept comes back to a genuinely queued job hours old.
s1="$(_rp_stuck_advance "" "${ONE}" 500 "${NOW}" 3 86400)"
check "first sight earns no strike" "0" "$(strikes_for "${s1}" 111)"
check "first sight is not held"     "0" "$(count "$(_rp_stuck_held "${s1}" 3)")"

# The regression that matters most. A pool that cannot start at all, a missing
# launch agent being the way that happens, never changes its started stamp. If
# strikes accrued per pass it would reach the threshold in three minutes and
# then refuse real work once the agents were repaired.
s="${s1}"
for _ in 1 2 3 4 5; do
  s="$(_rp_stuck_advance "${s}" "${ONE}" 500 "${NOW}" 3 86400)"
done
check "an unchanged started stamp earns nothing" "0" "$(strikes_for "${s}" 111)"

# One strike per cycle, and held at the threshold.
s="$(_rp_stuck_advance "${s1}"  "${ONE}" 501 "${NOW}" 3 86400)"
check "one cycle, one strike"  "1" "$(strikes_for "${s}" 111)"
s="$(_rp_stuck_advance "${s}"   "${ONE}" 502 "${NOW}" 3 86400)"
s="$(_rp_stuck_advance "${s}"   "${ONE}" 503 "${NOW}" 3 86400)"
check "three cycles reach the threshold" "3" "$(strikes_for "${s}" 111)"
check "and the run is held"              "1" "$(count "$(_rp_stuck_held "${s}" 3)")"
held="${s}"

# The org case, and the reason this subtracts rather than suppressing. One
# stuck run in one repository must not blind the pool to another repository:
# queued is 2, held is 1, so the pool still wakes.
s="$(_rp_stuck_advance "${held}" "${TWO}" 504 "${NOW}" 3 86400)"
check "a new run alongside a held one is not held" "1" "$(count "$(_rp_stuck_held "${s}" 3)")"
check "and the new run starts at zero"             "0" "$(strikes_for "${s}" 222)"

# Leaving the queued set drops the record, so cancelling the run is all the
# cleanup there is.
s="$(_rp_stuck_advance "${held}" "acme/gadget 222" 505 "${NOW}" 3 86400)"
check "a run that stops being queued is forgotten" "" "$(strikes_for "${s}" 111)"

# The re-arm, so a run held by something transient cannot be held for ever.
# It buys exactly one wake, and goes straight back to held if nothing changed.
s="$(_rp_stuck_advance "${held}" "${ONE}" 503 $(( NOW + 90000 )) 3 86400)"
check "retry drops it below the threshold" "2" "$(strikes_for "${s}" 111)"
check "so it is not held"                  "0" "$(count "$(_rp_stuck_held "${s}" 3)")"
s="$(_rp_stuck_advance "${s}" "${ONE}" 506 $(( NOW + 90000 )) 3 86400)"
check "and one cycle later it is held again" "1" "$(count "$(_rp_stuck_held "${s}" 3)")"

# New holds fire once, which is what keeps the log and the notifier quiet.
check "the hold is announced once" "1" "$(count "$(_rp_stuck_new_holds "${s1}" "${held}" 3)")"
s="$(_rp_stuck_advance "${held}" "${ONE}" 507 "${NOW}" 3 86400)"
check "and not again on the next pass" "0" "$(count "$(_rp_stuck_new_holds "${held}" "${s}" 3)")"

# Nought disables the guard outright.
check "threshold 0 holds nothing" "0" "$(count "$(_rp_stuck_held "${held}" 0)")"

# A truncated or hand-mangled record is ignored rather than becoming a hold.
check "a short record is not a hold"      "0" "$(count "$(_rp_stuck_held 'acme/widget 111 3' 3)")"
check "a non-numeric strike is not a hold" "0" "$(count "$(_rp_stuck_held 'acme/widget 111 x 1 1' 3)")"
check "and it is treated as unseen"        "0" "$(strikes_for "$(_rp_stuck_advance 'acme/widget 111 x 1 1' "${ONE}" 999 "${NOW}" 3 86400)" 111)"

# ---------------------------------------------------------------------------
# one autoscale loop end to end
# ---------------------------------------------------------------------------
cat >"${RUNPOOL_BASE}/pools/alpha.conf" <<CONF
POOL_SCOPE="repo"
POOL_TARGET="acme/widget"
POOL_COUNT="1"
POOL_DIR="${RUNPOOL_BASE}/runners/alpha"
POOL_CACHE_DIR="${RUNPOOL_CACHE_DIR}/pools/alpha"
POOL_LABELS="self-hosted,macOS,ARM64,alpha"
CONF
mkdir -p "${RUNPOOL_BASE}/runners/alpha"

# Answers with whatever run ids QUEUED_IDS names, and records that it was
# called. The call count is asserted below: the guard must not cost an extra
# request, and this is what catches anyone adding a second one later.
cat >"${bin_dir}/gh" <<'STUB'
#!/bin/bash
echo "$2" >> "${GH_CALLS}"
case "$2" in
  */jobs*) echo 0 ;;
  *) n=0; for i in ${QUEUED_IDS}; do n=$(( n + 1 )); done
     echo "${n} $(echo ${QUEUED_IDS} | tr ' ' ',')" ;;
esac
STUB
chmod +x "${bin_dir}/gh"
export PATH="${bin_dir}:${PATH}"
export GH_CALLS="${scratch_dir}/calls"
: >"${GH_CALLS}"
calls() { awk 'NF { n++ } END { print n + 0 }' "${GH_CALLS}"; }

wakes="${scratch_dir}/wakes"
: >"${wakes}"
tick=0
# The pool is always down, and a wake records itself and moves the started
# stamp, which is exactly what a real `_rp_up` does and the only thing the
# rule reads from it. The stamp is a counter rather than the clock so a cycle
# is instant: real seconds would mean sleeping through every wake.
_rp_running_in() { echo 0; }
_rp_up() {
  printf '%s\n' "$1" >>"${wakes}"
  tick=$(( tick + 1 ))
  printf '%s\n' "$(( 1000 + tick ))" >| "$(_rp_pool_started_flag "$1")"
}
wakes_seen() { awk 'NF { n++ } END { print n + 0 }' "${wakes}"; }

# The tool logs to stderr as well as its log file, and a passing test should
# say only that it passed. Per call rather than `exec 2>`, which would also
# swallow `fail`, and a test whose failure message is invisible is worse than
# a noisy one.
quietly() { "$@" 2>>"${RUNPOOL_LOG}"; }

export QUEUED_IDS="111"
quietly _rp_autoscale; quietly _rp_autoscale; quietly _rp_autoscale; quietly _rp_autoscale
check "three fruitless wakes, then silence" "3" "$(wakes_seen)"

before=$(calls)
quietly _rp_autoscale
check "a held pool still costs exactly one call" "1" "$(( $(calls) - before ))"

# A second run arriving is work the pool has never judged, so it wakes at once
# even though the first run is still held.
export QUEUED_IDS="111 222"
quietly _rp_autoscale
check "a new run wakes a held pool" "4" "$(wakes_seen)"

# GitHub's error JSON arrives on stdout, not stderr, so a watch entry naming a
# repository that has been renamed or made private hands the helper a line
# starting '{'. It must count as nothing rather than reaching the arithmetic.
cat >"${bin_dir}/gh" <<'STUB'
#!/bin/bash
echo "$2" >> "${GH_CALLS}"
echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
exit 1
STUB
chmod +x "${bin_dir}/gh"
rm -f "$(_rp_pool_stuck_file alpha)"
before_wakes=$(wakes_seen)
quietly _rp_autoscale
check "a repository gh cannot read does not wake the pool" "${before_wakes}" "$(wakes_seen)"
check "and leaves no stuck record" "0" "$(count "$(_rp_read_pool_stuck alpha)")"

cat >"${bin_dir}/gh" <<'STUB'
#!/bin/bash
echo "$2" >> "${GH_CALLS}"
case "$2" in
  */jobs*) echo 0 ;;
  *) n=0; for i in ${QUEUED_IDS}; do n=$(( n + 1 )); done
     echo "${n} $(echo ${QUEUED_IDS} | tr ' ' ',')" ;;
esac
STUB
chmod +x "${bin_dir}/gh"

# The notification fires once and carries the run, not just the pool.
notes="${scratch_dir}/notes"
: >"${notes}"
cat >"${bin_dir}/notify" <<STUB
#!/bin/bash
cat >> "${notes}"
echo >> "${notes}"
STUB
chmod +x "${bin_dir}/notify"
export RUNPOOL_NOTIFY_CMD="${bin_dir}/notify"
export QUEUED_IDS="333"
rm -f "$(_rp_pool_stuck_file alpha)"
quietly _rp_autoscale; quietly _rp_autoscale; quietly _rp_autoscale; quietly _rp_autoscale
check "one notification for one stuck run" "1" "$(awk 'NF { n++ } END { print n + 0 }' "${notes}")"
case "$(cat "${notes}")" in
  *'"key":"runpool/stuck-queue/alpha/333"'*) pass=$(( pass + 1 )) ;;
  *) fail "the notification does not carry the run: $(cat "${notes}")" ;;
esac

echo "ok: ${pass} case(s)"
