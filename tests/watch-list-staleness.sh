#!/bin/bash
# The rule behind doctor's watch-list check, exercised without GitHub.
#
# `_rp_unwatched_repos` is what decides whether an org pool's watch list has
# gone stale, and the check that reports it needs the API. Separating the two
# is what lets the rule be tested at all.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
trap 'rm -rf "${scratch_dir}"' EXIT INT TERM

# Sourced rather than driven through the binary, because the rule under test
# is a pure function and the check that calls it needs GitHub. Every path the
# library reads at load time points into a scratch directory, so nothing here
# can see or touch a real installation.
export RUNPOOL_BASE="${scratch_dir}/base"
export RUNPOOL_STATE_DIR="${scratch_dir}/state"
export RUNPOOL_CACHE_DIR="${scratch_dir}/cache"
export RUNPOOL_CONFIG="${scratch_dir}/runpool.conf"
export RUNPOOL_POOLS_FILE="${scratch_dir}/pools"
export RUNPOOL_LOG_DIR="${scratch_dir}/logs"
export RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
export RUNPOOL_AGENT_DIR="${scratch_dir}/agents"
mkdir -p "${RUNPOOL_BASE}" "${RUNPOOL_STATE_DIR}" "${RUNPOOL_CACHE_DIR}" "${RUNPOOL_LOG_DIR}" "${RUNPOOL_AGENT_DIR}"

# shellcheck source=/dev/null
. "${repo_dir}/lib/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "${repo_dir}/lib/scheduler.sh"

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

ALL=$'acme/one\nacme/two\nacme/three'

check "every repository watched" \
  "" \
  "$(_rp_unwatched_repos "acme/one,acme/two,acme/three" "${ALL}")"

check "one missing is named" \
  "acme/three" \
  "$(_rp_unwatched_repos "acme/one,acme/two" "${ALL}")"

check "several missing are all named" \
  $'acme/two\nacme/three' \
  "$(_rp_unwatched_repos "acme/one" "${ALL}")"

# The list is stored as one string and hand-edited, so spaces after commas
# are the likeliest way it is written. Treating "acme/two" and " acme/two"
# as different repositories would report a stale list that is not stale.
check "spaces around entries do not matter" \
  "" \
  "$(_rp_unwatched_repos "acme/one, acme/two , acme/three" "${ALL}")"

# A substring is not a match, and the direction matters. Without the comma
# fencing, a watch list naming `acme/one-more` would satisfy `acme/one`,
# because the shorter name occurs inside the longer one — so a genuinely
# unwatched repository would be reported as watched. That is the direction
# that fails silently: the check would say the list is complete when it is
# not, which is exactly the state it exists to catch.
check "a repository whose name occurs inside a watched one is still unwatched" \
  "acme/one" \
  "$(_rp_unwatched_repos "acme/one-more" $'acme/one\nacme/one-more')"

# A watch list naming something the organisation no longer holds is not this
# check's business: the failure it exists for is work nobody wakes for, and
# a repository that does not exist queues nothing.
check "a watched repository that no longer exists is not reported" \
  "" \
  "$(_rp_unwatched_repos "acme/one,acme/gone" "acme/one")"

echo "ok: ${pass} case(s)"
