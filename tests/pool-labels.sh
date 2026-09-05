#!/bin/bash
# Custom runner labels: the rules that derive and validate them, and the drift
# `apply` reports against a pool that has some.
#
# Two halves, both offline. The first is pure functions. The second is
# `apply --dry-run`, which reads the pools file and the configs and calls
# nothing, so the whole plan can be asserted with no GitHub account.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
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
         "${RUNPOOL_LOG_DIR}" "${RUNPOOL_AGENT_DIR}"

# shellcheck source=/dev/null
. "${repo_dir}/lib/common.sh" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# deriving the extras back out of the stored list
# ---------------------------------------------------------------------------
# The case this exists for: a label added by hand to a config, which `register`
# could never have produced and nothing else can see.
check "an extra label is recovered" "xcode" \
  "$(_rp_extra_labels "self-hosted,macOS,ARM64,acme,xcode" acme)"
check "a plain pool has no extras" "" \
  "$(_rp_extra_labels "self-hosted,macOS,ARM64,acme" acme)"

# Only the FIRST occurrence of the name is the name label. A pool called xcode
# carrying a genuine xcode label must keep it, or rename loses it silently.
check "a pool named after its label keeps it" "xcode" \
  "$(_rp_extra_labels "self-hosted,macOS,ARM64,xcode,xcode" xcode)"

check "spaces, empties and duplicates are filtered" "a,b" \
  "$(_rp_extra_labels "self-hosted, macOS ,ARM64,,acme,,a,a,b" acme)"
check "a config missing a base label still derives" "xcode" \
  "$(_rp_extra_labels "self-hosted,acme,xcode" acme)"
check "order is preserved" "z,a" \
  "$(_rp_extra_labels "self-hosted,macOS,ARM64,acme,z,a" acme)"

# A hand-mangled config must filter, never fail: this runs on every apply, and
# a config nobody can load is worse than a label nobody asked for. A space is
# not mangling, though: the list is split on whitespace as well as commas, so
# 'a b' is two labels and both survive.
check "an unusable token is dropped rather than fatal" "ok" \
  "$(_rp_extra_labels "self-hosted,acme,a|b,ok" acme)"
check "a space reads as two labels" "a,b" \
  "$(_rp_extra_labels "self-hosted,acme,a b" acme)"

# Round trip.
check "building then deriving is the identity" "xcode,gpu" \
  "$(_rp_extra_labels "$(_rp_pool_labels acme "xcode,gpu")" acme)"
check "the built list carries the base three and the name" "self-hosted,macOS,ARM64,acme,xcode" \
  "$(_rp_pool_labels acme xcode)"
check "and just the name with no extras" "self-hosted,macOS,ARM64,acme" \
  "$(_rp_pool_labels acme "")"

check "sorting is for comparison only" "a,b,c" "$(_rp_sorted_labels "c,a,b")"
check "and ignores empty entries"      "a,b"   "$(_rp_sorted_labels "b,,a")"

# ---------------------------------------------------------------------------
# validation on the way in
# ---------------------------------------------------------------------------
# '|' is apply's record separator, '"' and '$' reach a config that is SOURCED
# on every invocation and every tick, whitespace is two fields in a file that
# is word-split, and '*' would reach rename's find -name.
for bad in "a|b" 'a"b' 'a$(id)' 'a`id`' "a b" "a,b" "" "." ".." "a*b" "a[b"; do
  if _rp_valid_label "${bad}"; then fail "_rp_valid_label accepted '${bad}'"; fi
  pass=$(( pass + 1 ))
done
for good in xcode xcode-16.2 gpu_2 a.b; do
  _rp_valid_label "${good}" || fail "_rp_valid_label rejected '${good}'"
  pass=$(( pass + 1 ))
done
long=$(printf 'a%.0s' $(seq 1 256)); _rp_valid_label "${long}" || fail "256 characters should be allowed"
pass=$(( pass + 1 ))
toolong=$(printf 'a%.0s' $(seq 1 257)); _rp_valid_label "${toolong}" && fail "257 characters should be refused"
pass=$(( pass + 1 ))

# ---------------------------------------------------------------------------
# what apply plans, with no GitHub account
# ---------------------------------------------------------------------------
# RUNPOOL_POOLS_FILE and RUNPOOL_LOG_DIR are isolated separately on purpose:
# RUNPOOL_BASE moves neither, so without both this would read the real pools
# file and write to a real installation's log.
runpool() { "${repo_dir}/bin/runpool" "$@"; }

cat >"${RUNPOOL_BASE}/pools/acme.conf" <<CONF
POOL_SCOPE="org"
POOL_TARGET="acme-inc"
POOL_COUNT="2"
POOL_DIR="${RUNPOOL_BASE}/runners/acme"
POOL_CACHE_DIR="${RUNPOOL_CACHE_DIR}/pools/acme"
POOL_LABELS="self-hosted,macOS,ARM64,acme,xcode"
CONF

# Declared without --labels against a pool that has one. This is the hazard the
# strict comparison creates, and the plan has to spell out the consequence
# rather than printing a bare diff.
printf 'acme --org acme-inc --count 2\n' >"${RUNPOOL_POOLS_FILE}"
out=$(runpool apply --dry-run 2>&1) || fail "dry run failed: ${out}"
case "${out}" in
  *"labels xcode -> (none)"*) pass=$(( pass + 1 )) ;;
  *) fail "the plan does not name the label being dropped: ${out}" ;;
esac
case "${out}" in
  *"stops matching"*) pass=$(( pass + 1 )) ;;
  *) fail "the plan does not say what stops matching: ${out}" ;;
esac
case "${out}" in
  *"will be re-registered"*) pass=$(( pass + 1 )) ;;
  *) fail "the plan does not warn that a label change re-registers: ${out}" ;;
esac

# Declared to match, so nothing to do.
printf 'acme --org acme-inc --count 2 --labels xcode\n' >"${RUNPOOL_POOLS_FILE}"
out=$(runpool apply --dry-run 2>&1) || fail "dry run failed: ${out}"
case "${out}" in
  *"up to date"*) pass=$(( pass + 1 )) ;;
  *) fail "a matching label set should be up to date: ${out}" ;;
esac

# Order alone is not drift, or every apply would re-register the pool.
cat >"${RUNPOOL_BASE}/pools/acme.conf" <<CONF
POOL_SCOPE="org"
POOL_TARGET="acme-inc"
POOL_COUNT="2"
POOL_DIR="${RUNPOOL_BASE}/runners/acme"
POOL_CACHE_DIR="${RUNPOOL_CACHE_DIR}/pools/acme"
POOL_LABELS="self-hosted,macOS,ARM64,acme,gpu,xcode"
CONF
printf 'acme --org acme-inc --count 2 --labels xcode,gpu\n' >"${RUNPOOL_POOLS_FILE}"
out=$(runpool apply --dry-run 2>&1) || fail "dry run failed: ${out}"
case "${out}" in
  *"up to date"*) pass=$(( pass + 1 )) ;;
  *) fail "label order should not read as drift: ${out}" ;;
esac

# An implicit label is refused rather than dropped, so declared and derived
# cannot end up permanently unequal.
printf 'acme --org acme-inc --count 2 --labels self-hosted\n' >"${RUNPOOL_POOLS_FILE}"
out=$(runpool apply --dry-run 2>&1) && fail "a base label should be refused"
case "${out}" in
  *"pools:1:"*"already"*) pass=$(( pass + 1 )) ;;
  *) fail "the refusal should name the line: ${out}" ;;
esac
printf 'acme --org acme-inc --count 2 --labels acme\n' >"${RUNPOOL_POOLS_FILE}"
runpool apply --dry-run >/dev/null 2>&1 && fail "the pool's own name should be refused"
pass=$(( pass + 1 ))

# The record separator, which would otherwise shift every field in both reads.
printf 'acme --org acme-inc --count 2 --labels a|b\n' >"${RUNPOOL_POOLS_FILE}"
runpool apply --dry-run >/dev/null 2>&1 && fail "a label containing '|' should be refused"
pass=$(( pass + 1 ))

# A create carries its labels through to the plan.
rm -f "${RUNPOOL_BASE}/pools/acme.conf"
printf 'acme --org acme-inc --count 2 --labels xcode\n' >"${RUNPOOL_POOLS_FILE}"
out=$(runpool apply --dry-run 2>&1) || fail "dry run failed: ${out}"
case "${out}" in
  *"labelled xcode"*) pass=$(( pass + 1 )) ;;
  *) fail "a create should say what it will be labelled: ${out}" ;;
esac

echo "ok: ${pass} case(s)"
