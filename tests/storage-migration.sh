#!/bin/bash
# Run against a scratch installation only. This verifies the storage migration
# without registering a runner or calling GitHub.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
legacy_dir="${scratch_dir}/legacy"
support_dir="${scratch_dir}/Application Support/runpool"
cache_dir="${scratch_dir}/Caches/runpool"
config_dir="${scratch_dir}/config"
log_dir="${scratch_dir}/logs"
hook_dir="${config_dir}/runpool/hooks"
job_hook="${scratch_dir}/job-hook.sh"

cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_dir() { [ -d "$1" ] || fail "missing directory: $1"; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "${1} does not contain ${2}"; }
assert_link() { [ -L "$1" ] || fail "missing symlink: $1"; }

mkdir -p "${legacy_dir}/pools" "${legacy_dir}/agents" "${legacy_dir}/state/pools" \
         "${legacy_dir}/alpha/runner-1/_work/repository" \
         "${legacy_dir}/alpha/runner-1/.pnpm-store" \
         "${legacy_dir}/alpha/runner-1/.npm-cache" \
         "${legacy_dir}/alpha/runner-1/bin.2.336.0" \
         "${legacy_dir}/alpha/runner-1/externals.2.336.0" \
         "${legacy_dir}/alpha/runner-1/tmp" "${config_dir}" "${log_dir}"

touch "${legacy_dir}/alpha/runner-1/bin.2.336.0/Runner.Listener" \
      "${legacy_dir}/alpha/runner-1/externals.2.336.0/node"
ln -s "${legacy_dir}/alpha/runner-1/bin.2.336.0" "${legacy_dir}/alpha/runner-1/bin"
ln -s "${legacy_dir}/alpha/runner-1/externals.2.336.0" "${legacy_dir}/alpha/runner-1/externals"
printf '#!/bin/sh\nexit 0\n' >| "${job_hook}"
chmod +x "${job_hook}"

cat >| "${legacy_dir}/pools/alpha.conf" <<CONF
POOL_NAME="alpha"
POOL_SCOPE="repo"
POOL_TARGET="acme/example"
POOL_COUNT="1"
POOL_DIR="${legacy_dir}/alpha"
POOL_LABELS="self-hosted,macOS,ARM64,alpha"
CONF
cat >| "${config_dir}/runpool.conf" <<CONF
RUNPOOL_BASE="${legacy_dir}"
RUNPOOL_JOB_HOOK="${job_hook}"
RUNPOOL_HOOK_DIR="${hook_dir}"
CONF
chmod 600 "${config_dir}/runpool.conf"
cat >| "${legacy_dir}/alpha/runner-1/.runner" <<RUNNER
{"agentId":1,"workFolder":"_work"}
RUNNER
touch "${legacy_dir}/alpha/runner-1/run.sh" \
      "${legacy_dir}/alpha/runner-1/_work/repository/file" \
      "${legacy_dir}/alpha/runner-1/.pnpm-store/file" \
      "${legacy_dir}/alpha/runner-1/.npm-cache/file" \
      "${legacy_dir}/alpha/runner-1/tmp/file" \
      "${legacy_dir}/state/pools/alpha.paused"

env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" migrate-storage --dry-run --from "${legacy_dir}" --to "${support_dir}" \
    >/dev/null || fail "dry run failed"
[ ! -f "${support_dir}/pools/alpha.conf" ] || fail "dry run changed the target"

env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" migrate-storage --from "${legacy_dir}" --to "${support_dir}" \
    >/dev/null || fail "migration failed"

assert_file "${legacy_dir}/pools/alpha.conf"
assert_file "${support_dir}/pools/alpha.conf"
assert_contains "${config_dir}/runpool.conf" "RUNPOOL_BASE=\"${support_dir}\""
[ "$(stat -f '%Lp' "${config_dir}/runpool.conf")" = "600" ] || fail "config mode changed"
assert_contains "${support_dir}/pools/alpha.conf" "POOL_DIR=\"${support_dir}/runners/alpha\""
assert_contains "${support_dir}/pools/alpha.conf" "POOL_CACHE_DIR=\"${cache_dir}/pools/alpha\""
assert_file "${support_dir}/runners/alpha/runner-1/.runner"
assert_link "${support_dir}/runners/alpha/runner-1/bin"
assert_link "${support_dir}/runners/alpha/runner-1/externals"
[ "$(readlink "${support_dir}/runners/alpha/runner-1/bin")" = "bin.2.336.0" ] || fail "bin link remained absolute"
[ "$(readlink "${support_dir}/runners/alpha/runner-1/externals")" = "externals.2.336.0" ] || fail "externals link remained absolute"
assert_contains "${support_dir}/runners/alpha/runner-1/.runner" "\"workFolder\":\"${cache_dir}/pools/alpha/runner-1/work\""
assert_dir "${cache_dir}/pools/alpha/runner-1/work"
[ ! -e "${cache_dir}/pools/alpha/runner-1/work/repository/file" ] || fail "migration retained path-bound work output"
assert_file "${cache_dir}/pools/alpha/runner-1/pnpm/file"
assert_file "${cache_dir}/pools/alpha/runner-1/npm/file"
assert_dir "${cache_dir}/pools/alpha/runner-1/tmp"
[ ! -e "${cache_dir}/pools/alpha/runner-1/tmp/file" ] || fail "migration retained old job temp"
assert_file "${legacy_dir}/alpha/runner-1/_work/repository/file"
assert_file "${legacy_dir}/alpha/runner-1/tmp/file"
assert_file "${support_dir}/agents/runpool.alpha.1.plist"
assert_contains "${support_dir}/agents/runpool.alpha.1.plist" "${cache_dir}/pools/alpha/runner-1/pnpm"
assert_contains "${support_dir}/agents/runpool.alpha.1.plist" "${hook_dir}/started.sh"
assert_contains "${support_dir}/agents/runpool.alpha.1.plist" "${hook_dir}/completed.sh"
assert_file "${hook_dir}/started.sh"
assert_file "${hook_dir}/completed.sh"
[ -x "${hook_dir}/started.sh" ] || fail "started hook launcher is not executable"
[ -x "${hook_dir}/completed.sh" ] || fail "completed hook launcher is not executable"
[ ! -d "${support_dir}/hooks" ] || fail "obsolete hook directory copied into Application Support"

rm "${hook_dir}/started.sh"
env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" rewrite-agents >/dev/null || fail "agent rewrite failed to restore hook launcher"
assert_file "${hook_dir}/started.sh"

invalid_output="${scratch_dir}/invalid-hook-dir.txt"
if env RUNPOOL_HOOK_DIR="${scratch_dir}/hook dir" RUNPOOL_CACHE_DIR="${cache_dir}" \
       RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
       RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
       "${repo_dir}/bin/runpool" rewrite-agents >| "${invalid_output}" 2>&1; then
  fail "agent rewrite accepted a hook launcher path containing whitespace"
fi
assert_contains "${invalid_output}" "RUNPOOL_HOOK_DIR cannot contain whitespace"

status_file="${scratch_dir}/status.json"
env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" status --json --local >| "${status_file}" || fail "status failed"
assert_contains "${status_file}" "\"cache\":\"${cache_dir}\""
assert_contains "${status_file}" "\"paused\":true"

env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" up alpha >/dev/null 2>&1 && fail "paused pool started"
env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" resume alpha >/dev/null || fail "pool resume failed"
[ ! -f "${support_dir}/state/pools/alpha.paused" ] || fail "pool pause flag remained"

env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" pause alpha >/dev/null || fail "pool pause failed"
assert_file "${support_dir}/state/pools/alpha.paused"

env RUNPOOL_CACHE_DIR="${cache_dir}" RUNPOOL_CONFIG="${config_dir}/runpool.conf" RUNPOOL_POOLS_FILE="${config_dir}/pools" \
    RUNPOOL_LOG_DIR="${log_dir}" RUNPOOL_LOG="${log_dir}/runpool.log" \
    "${repo_dir}/bin/runpool" migrate-storage --from "${legacy_dir}" --to "${support_dir}" --remove-legacy \
    >/dev/null || fail "legacy removal failed"
[ ! -e "${legacy_dir}" ] || fail "legacy installation remained"
assert_file "${support_dir}/runners/alpha/runner-1/bin/Runner.Listener"
assert_file "${support_dir}/runners/alpha/runner-1/externals/node"

# An empty native root must not make an existing XDG installation invisible.
# This is the compatibility path a user takes simply by installing the new
# binary; no migration has happened yet and their runner registrations remain
# the active installation.
fallback_home="${scratch_dir}/fallback-home"
fallback_legacy="${fallback_home}/.local/share/runpool"
fallback_support="${fallback_home}/Library/Application Support/runpool"
fallback_cache="${fallback_home}/Library/Caches/runpool"
fallback_log="${fallback_home}/Library/Logs/runpool"
mkdir -p "${fallback_legacy}/pools" "${fallback_support}"
cat >| "${fallback_legacy}/pools/beta.conf" <<CONF
POOL_NAME="beta"
POOL_SCOPE="repo"
POOL_TARGET="acme/example"
POOL_COUNT="1"
POOL_DIR="${fallback_legacy}/beta"
POOL_LABELS="self-hosted,macOS,ARM64,beta"
CONF
fallback_status="${scratch_dir}/fallback-status.json"
env HOME="${fallback_home}" RUNPOOL_CONFIG=/dev/null RUNPOOL_POOLS_FILE="${scratch_dir}/fallback-pools" \
    RUNPOOL_CACHE_DIR="${fallback_cache}" RUNPOOL_LOG_DIR="${fallback_log}" RUNPOOL_LOG="${fallback_log}/runpool.log" \
    "${repo_dir}/bin/runpool" status --json --local >| "${fallback_status}" || fail "legacy fallback status failed"
assert_contains "${fallback_status}" "\"base\":\"${fallback_legacy}\""

echo "ok storage migration"
