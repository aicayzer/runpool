#!/bin/bash
# Run against a scratch installation only. Every case here is refused before
# set-count reaches GitHub, so nothing registers a runner or calls the API.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
base_dir="${scratch_dir}/base"
cache_dir="${scratch_dir}/cache"
config_dir="${scratch_dir}/config"
log_dir="${scratch_dir}/logs"

cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "${base_dir}/pools" "${base_dir}/state" "${cache_dir}" "${config_dir}" "${log_dir}"

cat >"${base_dir}/pools/alpha.conf" <<CONF
POOL_SCOPE="repo"
POOL_TARGET="acme/widget"
POOL_COUNT="4"
POOL_DIR="${base_dir}/runners/alpha"
POOL_CACHE_DIR="${cache_dir}/pools/alpha"
POOL_LABELS="self-hosted,macOS,ARM64,alpha"
CONF

runpool() {
  env RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${cache_dir}" \
      RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
      RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
      "${repo_dir}/bin/runpool" "$@"
}

count_now() { sed -n 's/^POOL_COUNT="\(.*\)"$/\1/p' "${base_dir}/pools/alpha.conf"; }

# Every refusal below must leave the pool exactly as it was. Checked after each
# one rather than at the end, so a failure names the case that caused it.
assert_untouched() {
  [ "$(count_now)" = "4" ] || fail "$1: POOL_COUNT changed to $(count_now)"
}

assert_refused() {
  local what="$1"; shift
  local out rc
  out=$(runpool set-count "$@" 2>&1); rc=$?
  [ "${rc}" -ne 0 ] || fail "${what}: exited 0, expected a refusal. Output: ${out}"
  assert_untouched "${what}"
  echo "${out}"
}

# --- the compare-and-swap -----------------------------------------------------
out=$(assert_refused "stale --if-count" alpha 5 --if-count 3)
case "${out}" in
  *"has 4 runner(s), not 3"*) ;;
  *) fail "stale --if-count: unhelpful message: ${out}" ;;
esac

# A premise that no longer holds is a failure whatever the target is. Without
# this, asking for the count the pool already has would report success and tell
# a caller its stale view had been correct.
assert_refused "stale --if-count reaching the no-op shortcut" alpha 4 --if-count 3 >/dev/null

out=$(runpool set-count alpha 4 --if-count 4 2>&1) \
  || fail "matching --if-count on an unchanged count should succeed: ${out}"
case "${out}" in
  *"already 4 runner(s)"*) ;;
  *) fail "matching --if-count: expected the no-op message, got: ${out}" ;;
esac
assert_untouched "matching --if-count"

assert_refused "--if-count with no value" alpha 5 --if-count >/dev/null
assert_refused "--if-count with a bad value" alpha 5 --if-count 0 >/dev/null

# --- arguments are no longer ignored in silence -------------------------------
# These used to be read as $1 and $2 with anything further dropped, so a
# mistyped flag did nothing and said nothing.
assert_refused "unknown flag" alpha 5 --no-such-flag >/dev/null
assert_refused "trailing argument" alpha 5 extra >/dev/null
assert_refused "missing count" alpha >/dev/null
assert_refused "unknown pool" nosuchpool 5 >/dev/null

# --- the resize lock ----------------------------------------------------------
mkdir -p "${base_dir}/state/resize.alpha.lock"
out=$(assert_refused "held resize lock" alpha 5)
case "${out}" in
  *"already being resized"*) ;;
  *) fail "held lock: unhelpful message: ${out}" ;;
esac

# A resize killed halfway must not wedge the pool for good. Backdate the lock
# past the stale window and the next attempt has to get in.
#
# Probed with a mismatched --if-count rather than a real resize: that is
# refused just after the lock is taken and before anything is fetched, so the
# test stays offline and fast. Reaching the --if-count message at all is the
# proof, because a lock still held would have refused earlier.
touch -t 200001010000 "${base_dir}/state/resize.alpha.lock"
out=$(runpool set-count alpha 5 --if-count 3 2>&1)
case "${out}" in
  *"already being resized"*) fail "stale lock was not broken: ${out}" ;;
  *"has 4 runner(s), not 3"*) ;;
  *) fail "stale lock: unexpected outcome: ${out}" ;;
esac
[ ! -d "${base_dir}/state/resize.alpha.lock" ] || fail "lock not released after the attempt"
assert_untouched "stale lock"

# --- registration tokens ------------------------------------------------------
# `gh api --jq` prints the error body to stdout when a request fails, so a
# non-empty test accepts a 404 body as a token and hands it to config.sh. Both
# halves are checked against a stubbed gh, so this stays offline.
stub_dir="${scratch_dir}/stub"
mkdir -p "${stub_dir}"

with_stub_gh() {
  cat >"${stub_dir}/gh"
  chmod +x "${stub_dir}/gh"
}

token_for() (
  PATH="${stub_dir}:${PATH}"
  export RUNPOOL_BASE="${base_dir}" RUNPOOL_CACHE_DIR="${cache_dir}" \
         RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
         RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log"
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" >/dev/null 2>&1
  _rp_registration_token repo acme/widget
)

with_stub_gh <<'STUB'
#!/bin/bash
echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
exit 1
STUB
if out=$(token_for 2>/dev/null); then
  fail "a 404 body was accepted as a registration token: ${out}"
fi

with_stub_gh <<'STUB'
#!/bin/bash
echo "AZY7QF3KTPLMN2RSTUVWX4YZ6ABCD"
STUB
out=$(token_for 2>/dev/null) || fail "a valid token was rejected"
[ "${out}" = "AZY7QF3KTPLMN2RSTUVWX4YZ6ABCD" ] || fail "token mangled: ${out}"

# --- version ------------------------------------------------------------------
for flag in version --version -V; do
  out=$(runpool "${flag}" 2>&1) || fail "runpool ${flag} exited non-zero: ${out}"
  case "${out}" in
    "runpool "[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "runpool ${flag}: expected a version, got: ${out}" ;;
  esac
done

echo "OK: set-count guards"
