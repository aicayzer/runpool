# shellcheck shell=bash
# common.sh — constants, configuration, and helpers shared by every part.
#
# Sourced by bin/runpool. Targets bash 3.2, which is what stock macOS ships,
# so nothing here may use associative arrays, mapfile, or ${var^^}.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Everything installation-specific lives in a config file outside the repo, so
# a checkout carries no personal values. Every setting has a working default.
RUNPOOL_CONFIG="${RUNPOOL_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/runpool/config}"

# Precedence is environment, then config file, then the defaults below.
#
# The config file uses plain assignments, so sourcing it would otherwise
# clobber an explicit override and there would be no way to point a single
# invocation at a scratch directory. That matters for anything testing this
# on a machine that already has a config, the Homebrew test block included.
_rp_env_BASE="${RUNPOOL_BASE:-}"
_rp_env_CACHE_DIR="${RUNPOOL_CACHE_DIR:-}"
_rp_env_POOLS_FILE="${RUNPOOL_POOLS_FILE:-}"
_rp_env_LOG_DIR="${RUNPOOL_LOG_DIR:-}"
_rp_env_LABEL_NS="${RUNPOOL_LABEL_NS:-}"
_rp_env_IDLE_SECS="${RUNPOOL_IDLE_SECS:-}"
_rp_env_LOAD_WARN="${RUNPOOL_LOAD_WARN:-}"
_rp_env_NOTIFY_CMD="${RUNPOOL_NOTIFY_CMD:-}"
_rp_env_JOB_HOOK="${RUNPOOL_JOB_HOOK:-}"
_rp_env_HOOK_DIR="${RUNPOOL_HOOK_DIR:-}"
_rp_env_TELEMETRY="${RUNPOOL_TELEMETRY:-}"
_rp_env_DRAIN_TIMEOUT="${RUNPOOL_DRAIN_TIMEOUT:-}"

# 'set -a' exports everything the config assigns, which matters because a
# notifier or job hook runs as a child process and cannot see a variable that
# was only set. The config may also define settings runpool knows nothing about
# by name, such as an endpoint and token for whatever RUNPOOL_NOTIFY_CMD points
# at, so they cannot be exported individually.
set -a
# shellcheck disable=SC1090
[ -f "${RUNPOOL_CONFIG}" ] && . "${RUNPOOL_CONFIG}"
set +a

[ -n "${_rp_env_BASE}" ]        && RUNPOOL_BASE="${_rp_env_BASE}"
[ -n "${_rp_env_CACHE_DIR}" ]   && RUNPOOL_CACHE_DIR="${_rp_env_CACHE_DIR}"
[ -n "${_rp_env_POOLS_FILE}" ]  && RUNPOOL_POOLS_FILE="${_rp_env_POOLS_FILE}"
[ -n "${_rp_env_LOG_DIR}" ]     && RUNPOOL_LOG_DIR="${_rp_env_LOG_DIR}"
[ -n "${_rp_env_LABEL_NS}" ]    && RUNPOOL_LABEL_NS="${_rp_env_LABEL_NS}"
[ -n "${_rp_env_IDLE_SECS}" ]   && RUNPOOL_IDLE_SECS="${_rp_env_IDLE_SECS}"
[ -n "${_rp_env_LOAD_WARN}" ]   && RUNPOOL_LOAD_WARN="${_rp_env_LOAD_WARN}"
[ -n "${_rp_env_NOTIFY_CMD}" ]  && RUNPOOL_NOTIFY_CMD="${_rp_env_NOTIFY_CMD}"
[ -n "${_rp_env_JOB_HOOK}" ]    && RUNPOOL_JOB_HOOK="${_rp_env_JOB_HOOK}"
[ -n "${_rp_env_HOOK_DIR}" ]    && RUNPOOL_HOOK_DIR="${_rp_env_HOOK_DIR}"
[ -n "${_rp_env_TELEMETRY}" ]   && RUNPOOL_TELEMETRY="${_rp_env_TELEMETRY}"
[ -n "${_rp_env_DRAIN_TIMEOUT}" ] && RUNPOOL_DRAIN_TIMEOUT="${_rp_env_DRAIN_TIMEOUT}"
unset _rp_env_BASE _rp_env_CACHE_DIR _rp_env_POOLS_FILE _rp_env_LOG_DIR _rp_env_LABEL_NS \
      _rp_env_IDLE_SECS _rp_env_LOAD_WARN _rp_env_NOTIFY_CMD _rp_env_JOB_HOOK \
      _rp_env_HOOK_DIR _rp_env_TELEMETRY _rp_env_DRAIN_TIMEOUT

# Restored values need exporting again: the restore above is a plain assignment
# and happens after 'set -a' was turned off.
export RUNPOOL_BASE RUNPOOL_CACHE_DIR RUNPOOL_LOG_DIR RUNPOOL_LABEL_NS RUNPOOL_IDLE_SECS \
       RUNPOOL_LOAD_WARN RUNPOOL_NOTIFY_CMD RUNPOOL_JOB_HOOK RUNPOOL_HOOK_DIR RUNPOOL_TELEMETRY \
       RUNPOOL_DRAIN_TIMEOUT \
       RUNPOOL_CONFIG RUNPOOL_POOLS_FILE

# Required state belongs in Application Support. Runner installations carry
# registration credentials, so they are not cache data and never belong in a
# checkout. An existing pre-native-storage installation remains active until
# the operator explicitly migrates it; silently switching roots would strand
# its registrations and leave launch agents pointing at the old tree.
RUNPOOL_DEFAULT_BASE="${HOME}/Library/Application Support/runpool"
RUNPOOL_LEGACY_BASE="${XDG_DATA_HOME:-${HOME}/.local/share}/runpool"
# shellcheck disable=SC2034  # read by migrate-storage in lib/lifecycle.sh
RUNPOOL_USING_LEGACY=0
if [ -z "${RUNPOOL_BASE:-}" ]; then
  # An empty Application Support directory is not an installation. This can
  # happen when a user created the directory while reading the release notes;
  # it must not make a populated legacy installation disappear from RunPool.
  if find "${RUNPOOL_LEGACY_BASE}/pools" -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q . && \
     ! find "${RUNPOOL_DEFAULT_BASE}/pools" -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q .; then
    RUNPOOL_BASE="${RUNPOOL_LEGACY_BASE}"
    # shellcheck disable=SC2034  # read by migrate-storage in lib/lifecycle.sh
    RUNPOOL_USING_LEGACY=1
  else
    RUNPOOL_BASE="${RUNPOOL_DEFAULT_BASE}"
  fi
fi

# Work trees, actions, tools, package stores, temporary files and downloaded
# runner archives are all safe to recreate. They stay outside Application
# Support so macOS can treat them as cache data and so cleaning never touches
# registration state.
RUNPOOL_CACHE_DIR="${RUNPOOL_CACHE_DIR:-${HOME}/Library/Caches/runpool}"
RUNPOOL_POOL_DIR="${RUNPOOL_BASE}/pools"
RUNPOOL_RUNNER_DIR="${RUNPOOL_BASE}/runners"
RUNPOOL_AGENT_DIR="${RUNPOOL_BASE}/agents"
RUNPOOL_STATE_DIR="${RUNPOOL_BASE}/state"
RUNPOOL_LOG_DIR="${RUNPOOL_LOG_DIR:-${HOME}/Library/Logs/runpool}"

# GitHub's runner passes a Bash hook path without quoting it, so a wrapper
# below "Application Support" fails before the workflow starts. These tiny
# launchers are durable configuration, not cache data: Caches can be evicted
# while a listener is online. Keep them beside the operator-owned config and
# validate the runner's stricter path contract before writing an agent.
RUNPOOL_HOOK_DIR="${RUNPOOL_HOOK_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/runpool/hooks}"

RUNPOOL_LOG="${RUNPOOL_LOG_DIR}/runpool.log"
RUNPOOL_ACTIVITY="${RUNPOOL_STATE_DIR}/activity"
RUNPOOL_PAUSE_FLAG="${RUNPOOL_STATE_DIR}/paused"
RUNPOOL_POOL_STATE_DIR="${RUNPOOL_STATE_DIR}/pools"
# shellcheck disable=SC2034  # read by lib/scheduler.sh
RUNPOOL_LAST_CLEAN="${RUNPOOL_STATE_DIR}/last-clean"

# The pools `runpool apply` reconciles to. Beside the config rather than under
# RUNPOOL_BASE, because it is written by a person and copied between machines,
# while everything under the base is runtime state this tool owns. Derived from
# XDG_CONFIG_HOME directly and not from RUNPOOL_CONFIG, so pointing the config
# at /dev/null to isolate a test does not also lose the pools file.
# shellcheck disable=SC2034  # read by lib/apply.sh
RUNPOOL_POOLS_FILE="${RUNPOOL_POOLS_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/runpool/pools}"

# Prefix for every launch-agent label this tool owns. Configurable so two
# installations on one machine cannot collide.
RUNPOOL_LABEL_NS="${RUNPOOL_LABEL_NS:-runpool}"

# Stand a pool down after this many seconds with no job running anywhere.
# Restarting a runner is cheap and needs no re-registration, so a short grace
# only avoids churn between rapid pushes inside one working session.
RUNPOOL_IDLE_SECS="${RUNPOOL_IDLE_SECS:-1200}"

# How long after a pool starts before its runners are expected to have reached
# GitHub. A runner authenticates and opens its long poll a second or two after
# launchd starts it, and until that lands the pool looks exactly like a broken
# one: agents up locally, nothing online at GitHub. Judging a pool inside that
# window reports every healthy start as an outage.
RUNPOOL_SETTLE_SECS="${RUNPOOL_SETTLE_SECS:-120}"

# How long `--drain` waits for running jobs to finish before giving up.
#
# Derive this from the longest job the pool could serve plus the runner's own
# teardown — not from how long jobs actually take. A workflow capping jobs at
# `timeout-minutes: 60` and a drain bounded at exactly 60 minutes race each
# other, and the drain loses in the case that matters: a job at 59m50s is
# still legitimately running, GitHub has not cut it, and the drain times out
# during its teardown. The drain would then report a failure for a job that
# was about to finish cleanly, which is a false negative in the one code path
# whose whole purpose is not killing work.
#
# So the default sits above the common 60-minute job cap rather than above
# observed durations, which are far shorter. Do not lower it on the grounds
# that no job takes this long; that is not what the number is for.
RUNPOOL_DRAIN_TIMEOUT="${RUNPOOL_DRAIN_TIMEOUT:-4200}"

# Load threshold exposed through structured status for consumers that want to
# distinguish an ordinarily busy machine from exceptional contention. RunPool
# does not notify on it: machine load is diagnostic context, not pool health.
RUNPOOL_LOAD_WARN="${RUNPOOL_LOAD_WARN:-$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 8) * 6 ))}"

# Optional command receiving one JSON object on stdin whenever something is
# worth reporting. Unset by default: runpool works fully without a notifier and
# never grows one of its own. See lib/notify.sh and contrib/notify-webhook.sh.
RUNPOOL_NOTIFY_CMD="${RUNPOOL_NOTIFY_CMD:-}"

# Record one line per job to <base>/telemetry/jobs.jsonl, so the right runner
# count can be measured rather than argued about. Off by default. Timings and
# machine state only, nothing about the code, and it never leaves the machine.
RUNPOOL_TELEMETRY="${RUNPOOL_TELEMETRY:-0}"

mkdir -p "${RUNPOOL_POOL_DIR}" "${RUNPOOL_RUNNER_DIR}" "${RUNPOOL_AGENT_DIR}" \
         "${RUNPOOL_STATE_DIR}" "${RUNPOOL_POOL_STATE_DIR}" "${RUNPOOL_CACHE_DIR}" \
         "${RUNPOOL_LOG_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_rp_log() {
  echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC')  $*" | tee -a "${RUNPOOL_LOG}" >&2
}
_rp_err() { echo "runpool: $*" >&2; }

_rp_require() {
  command -v "$1" >/dev/null 2>&1 || { _rp_err "missing dependency: $1"; return 1; }
}

_rp_now() { date +%s; }

# Absolute path to the installed executable, for launch agents to invoke. A
# launchd job gets none of the interactive shell, so the path must be resolved
# at install time rather than looked up on PATH later.
_rp_self_path() { echo "${RUNPOOL_SELF:-$0}"; }

# What a launchd agent should point at. See RUNPOOL_INVOKED in bin/runpool: the
# resolved path is version-pinned under Homebrew and disappears on upgrade.
_rp_agent_path() { echo "${RUNPOOL_INVOKED:-${RUNPOOL_SELF:-$0}}"; }

# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------
_rp_pool_conf() { echo "${RUNPOOL_POOL_DIR}/$1.conf"; }

# A pool name becomes four different things: a config file path, a runner
# directory, a launchd label, and a bare string in the status JSON. It is
# constrained here to what is safe in all four, which is also what lets
# _rp_status_json assemble JSON without escaping anything.
#
# A 'case' glob rather than a bash regex, because stock bash 3.2 treats a
# quoted and an unquoted right-hand side of =~ differently and the difference
# is easy to get wrong. '.' and '..' pass a character-class test and are still
# path hazards, so they are rejected by name.
_rp_valid_pool_name() {
  case "$1" in
    ''|.|..)           return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# A GitHub owner or repository name, by the same reasoning and the same rule.
# These matter because `apply` is the first thing to write POOL_TARGET and
# POOL_WATCH from a file rather than from a command line, and _rp_status_json
# prints both without escaping on the stated grounds that they are GitHub
# identifiers. This is what keeps that stated assumption true.
_rp_valid_gh_name() {
  case "$1" in
    ''|.|..)           return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# OWNER/REPO: exactly one slash, with a valid name either side. The rejecting
# patterns come first so that '/x', 'x/' and 'a/b/c' never reach the split.
_rp_valid_gh_repo() {
  case "$1" in
    */*/*|/*|*/) return 1 ;;
    */*)         _rp_valid_gh_name "${1%%/*}" && _rp_valid_gh_name "${1#*/}" ;;
    *)           return 1 ;;
  esac
}

# A runner count. Every caller used to test only '' and non-digits, which let
# through two values that then failed somewhere else and blamed the wrong
# thing:
#
#   '007' passes a digits-only test, is written to POOL_COUNT verbatim, and
#   comes back out of _rp_status_json as "count":007 — which Python and Node
#   both reject, taking any wrapper reading that JSON down with it.
#
#   A twenty-digit count also passes, and then `[ "${count}" -ge 1 ]` prints
#   its own 'integer expression expected' with an internal path in it before
#   the caller reports some unrelated reason.
#
# The upper bound is what keeps `[ -ge ]` off a value libc cannot parse. Four
# digits is far past anything a single Mac can host, so the bound costs nothing
# real and the failure it prevents is a raw shell error.
_rp_valid_count() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;   # empty or not all digits
    0*)          return 1 ;;   # leading zero, and plain '0' with it
  esac
  [ "${#1}" -le 4 ] || return 1
  return 0
}

# The one sentence every caller prints when _rp_valid_count says no. Kept here
# so the pools file and the command line cannot drift into describing the same
# rule differently.
_rp_count_rule() { echo "a runner count is a whole number from 1 to 9999, written without a leading zero"; }

# Load POOL_* for pool $1 into the caller's scope. POOL_WATCH is set only on
# org pools, so every reader still uses "${POOL_WATCH:-}".
#
# EVERY POOL_* is cleared first, not just POOL_WATCH. Clearing one of them was
# enough while nothing loaded more than one pool per process; `apply` reconciles
# a whole file in one, and a config missing a field then inherited the previous
# pool's value and got planned against it. A pool silently taking on its
# neighbour's count, directory or labels is worse than any error.
#
# The four fields below are dereferenced without a default all over this tool —
# POOL_COUNT in arithmetic, POOL_DIR as a path prefix — so a config that
# survived sourcing but defines none of them is refused here rather than
# somewhere further on.
# shellcheck disable=SC2034  # every POOL_* here is read by another lib/ fragment
_rp_load_pool() {
  local conf; conf="$(_rp_pool_conf "$1")"
  if [ ! -f "${conf}" ]; then
    _rp_err "unknown pool: $1 (see 'runpool pools')"; return 1
  fi
  POOL_NAME=""; POOL_SCOPE=""; POOL_TARGET=""; POOL_COUNT=""
  POOL_DIR=""; POOL_CACHE_DIR=""; POOL_LABELS=""; POOL_WATCH=""; POOL_LEGACY_LAYOUT=0
  # shellcheck disable=SC1090
  . "${conf}" || { _rp_err "pool '$1': could not read ${conf}"; return 1; }
  if [ -z "${POOL_SCOPE}" ] || [ -z "${POOL_TARGET}" ] || \
     [ -z "${POOL_COUNT}" ] || [ -z "${POOL_DIR}" ]; then
    _rp_err "pool '$1': ${conf} is incomplete (needs POOL_SCOPE, POOL_TARGET, POOL_COUNT and POOL_DIR)"
    return 1
  fi
  # Pool configs before native storage have no cache root. Keep their work and
  # package stores exactly where they are until migrate-storage rewrites them.
  if [ -z "${POOL_CACHE_DIR}" ]; then
    POOL_CACHE_DIR="${POOL_DIR}"
    POOL_LEGACY_LAYOUT=1
  fi
}

# find, not a glob, so an empty pool directory stays silent rather than
# expanding to a literal '*.conf' or aborting under zsh's nomatch.
_rp_pool_names() {
  find "${RUNPOOL_POOL_DIR}" -maxdepth 1 -name '*.conf' 2>/dev/null \
    | while read -r f; do basename "${f}" .conf; done
}

_rp_label() { echo "${RUNPOOL_LABEL_NS}.$1.$2"; }

# In-flight jobs for the pool rooted at $1. Matches "<dir>/runner-" so a pool
# whose directory contains another pool's cannot count its neighbour's work.
_rp_busy_in() {
  ps -Ao command= 2>/dev/null | grep -F "$1/runner-" | grep -c "Runner.Worker" | tr -d ' '
}

_rp_agent_loaded() { launchctl list "$1" >/dev/null 2>&1; }

# The program a loaded agent actually names, read from the plist on disk.
#
# PlistBuddy reports its own errors on stdout rather than stderr — a missing
# file answers "File Doesn't Exist, Will Create: ..." and a missing key answers
# "Does Not Exist" — so redirecting stderr is not enough to tell an answer from
# a complaint. An absolute path is the only thing worth returning.
_rp_agent_program() {
  local plist="${HOME}/Library/LaunchAgents/$1.plist" program
  [ -f "${plist}" ] || return 1
  program="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "${plist}" 2>/dev/null)"
  case "${program}" in
    /*) printf '%s\n' "${program}" ;;
    *)  return 1 ;;
  esac
}

# Whether that program is gone. launchd reports an agent as loaded whether or
# not the file it names still exists, so "loaded" on its own says nothing about
# whether the thing has run since. Absent plist or unreadable key is not
# treated as missing: the callers already distinguish not-installed.
_rp_agent_program_missing() {
  local program; program="$(_rp_agent_program "$1")"
  [ -n "${program}" ] || return 1
  [ -x "${program}" ] && return 1
  return 0
}

# Whether the loaded agent finishes its job on SIGTERM rather than dying with
# it. Reads the environment of the agent as launchd actually loaded it, not the
# plist on disk: the file is what somebody intended, the loaded environment is
# what is true. An agent loaded before this key existed keeps running without
# it until the pool next cycles, and that is the case a drain has to refuse.
_rp_agent_traps_signals() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q 'RUNNER_MANUALLY_TRAP_SIG'
}

# Is one specific runner running a job? Fixed-string, like _rp_busy_in, so a
# base path containing regex characters cannot change what it matches.
_rp_runner_busy() {
  ps -Ao command= 2>/dev/null | grep -F "$1/runner-$2/" | grep -q "Runner.Worker"
}

# '>|' rather than '>': a shell with noclobber set refuses to truncate an
# existing file, which silently stopped this timestamp updating and left the
# idle sweep reading a frozen clock.
_rp_touch_activity() { _rp_now >| "${RUNPOOL_ACTIVITY}"; }

_rp_paused() { [ -f "${RUNPOOL_PAUSE_FLAG}" ]; }
_rp_pool_pause_flag() { echo "${RUNPOOL_POOL_STATE_DIR}/$1.paused"; }
_rp_pool_paused() { [ -f "$(_rp_pool_pause_flag "$1")" ]; }

# When a pool was last brought up, and whether that was recent enough that
# GitHub cannot yet be expected to have seen it. '>|' for the same noclobber
# reason as the activity stamp above.
_rp_pool_started_flag() { echo "${RUNPOOL_POOL_STATE_DIR}/$1.started"; }
_rp_touch_pool_started() { _rp_now >| "$(_rp_pool_started_flag "$1")"; }
_rp_pool_settling() {
  local started
  started=$(cat "$(_rp_pool_started_flag "$1")" 2>/dev/null || echo 0)
  case "${started}" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(_rp_now) - started )) -lt "${RUNPOOL_SETTLE_SECS}" ]
}

_rp_runner_cache_dir() { echo "${POOL_CACHE_DIR}/runner-$2"; }
_rp_runner_work_dir() {
  if [ "${POOL_LEGACY_LAYOUT}" = "1" ]; then
    echo "${POOL_DIR}/runner-$2/_work"
  else
    echo "${POOL_CACHE_DIR}/runner-$2/work"
  fi
}

_rp_prepare_runner_cache() {
  local cache
  cache="$(_rp_runner_cache_dir "$1" "$2")"
  if [ "${POOL_LEGACY_LAYOUT}" = "1" ]; then
    mkdir -p "${cache}/_work" "${cache}/.pnpm-store" "${cache}/.npm-cache" "${cache}/tmp" 2>/dev/null
  else
    mkdir -p "${cache}/work" "${cache}/pnpm" "${cache}/npm" "${cache}/tmp" 2>/dev/null
  fi
}

# GitHub API prefix for a pool's scope: orgs/<org> or repos/<owner>/<repo>.
_rp_scope_path() {
  if [ "$1" = "org" ]; then echo "/orgs/$2"; else echo "/repos/$2"; fi
}

# Whether organisation $1's DEFAULT runner group lets public repositories use
# its runners. Echoes 'true', 'false' or 'unknown'.
#
# 'unknown' is a third answer and not a synonym for 'false': reading runner
# groups needs admin:org, and a caller that folded the two together would
# report a permission problem as an all-clear.
#
# GitHub owns this control at organisation scope. The setting defaults to false
# and runners land in the default group because config.sh is never passed
# --runnergroup, so RunPool reads it and reports it and does nothing else. In
# particular it does NOT enumerate the organisation's public repositories to
# re-derive the same answer; SECURITY.md and AGENTS.md both state why the
# repository and organisation cases are deliberately asymmetric.
#
# Shared rather than inline because it now has two callers that must agree:
# `register` reads it once when a pool is created, and `doctor` reads it on
# every run — the setting can be switched on long after the pool exists.
_rp_org_allows_public() {
  local pub
  pub=$(gh api "/orgs/$1/actions/runner-groups" \
          --jq '[.runner_groups[] | select(.default == true) | .allows_public_repositories][0]' 2>/dev/null)
  case "${pub}" in
    true)  echo true ;;
    false) echo false ;;
    *)     echo unknown ;;
  esac
}

# ---------------------------------------------------------------------------
# Runner binary
# ---------------------------------------------------------------------------
# Fetch the latest osx-arm64 runner tarball once and echo its local path.
_rp_fetch_runner_tarball() {
  local out url digest path tmp jqf attempt sum
  # '[.]' matches a literal dot without a backslash, which keeps this filter
  # safe to carry through shells that mangle escapes. The digest comes back as
  # "sha256:..." and is empty on a release that does not publish one.
  jqf='[.assets[] | select(.name | test("osx-arm64.*[.]tar[.]gz$"))
        | "\(.browser_download_url) \(.digest // "")"][0] // ""'
  # releases/latest intermittently returns empty under secondary rate limiting,
  # so retry with backoff. Once cached this is skipped entirely.
  for attempt in 1 2 3 4 5; do
    out=$(gh api repos/actions/runner/releases/latest --jq "${jqf}" 2>/dev/null)
    [ -n "${out}" ] && break
    sleep $(( attempt * 2 ))
  done
  url="${out%% *}"; digest="${out#* }"
  [ -n "${url}" ] || { _rp_err "could not resolve the osx-arm64 runner tarball after retries"; return 1; }
  path="${RUNPOOL_CACHE_DIR}/downloads/${url##*/}"
  mkdir -p "${RUNPOOL_CACHE_DIR}/downloads" 2>/dev/null
  if [ ! -f "${path}" ]; then
    _rp_log "downloading runner: ${url##*/}"
    # '-f' so an HTTP error is a failure. Without it curl writes the error body
    # to the output path and exits 0, and the "already cached" test above then
    # trusts that file forever: every later tar fails and nothing says why.
    #
    # Downloaded under a temporary name in the same directory and moved into
    # place only once it is complete and verified, so an interrupted fetch
    # cannot leave a partial file behind either.
    tmp="${path}.part.$$"
    curl -fsSL "${url}" -o "${tmp}" || {
      rm -f "${tmp}"; _rp_err "download failed: ${url}"; return 1; }
    # The release publishes a sha256 and shasum is stock on macOS, so verifying
    # costs one field in the filter above and no new dependency. A release
    # without a digest is skipped rather than refused.
    if [ -n "${digest}" ]; then
      sum="$(shasum -a 256 "${tmp}" 2>/dev/null | awk '{print $1}')"
      if [ "${sum}" != "${digest#sha256:}" ]; then
        rm -f "${tmp}"
        _rp_err "checksum mismatch on ${url##*/}: expected ${digest#sha256:}, got ${sum:-none}"
        return 1
      fi
    fi
    mv -f "${tmp}" "${path}" || { rm -f "${tmp}"; return 1; }
  fi
  echo "${path}"
}

# Deregister one runner from GitHub using the agent id it recorded itself.
#
# Two earlier approaches failed, and both failed quietly. 'config.sh remove'
# takes no --unattended flag, so the runner binary rejected the arguments and
# exited having done nothing. Matching by a derived name misses any pool whose
# runners were registered under different names. The agent id is written by the
# runner and is exact. The file carries a UTF-8 BOM, hence grep rather than jq.
#   $1 runner_dir  $2 scope  $3 target
# A runner registration token for $1 $2, or nothing with a non-zero status.
#
# `gh api --jq` prints the error body to stdout when the request fails, so
# every caller here used to accept
#
#   {"message":"Not Found","documentation_url":"...","status":"404"}
#
# as a token, because it tested only that the value was non-empty. config.sh
# then failed on a garbage token, deep in the runner's own output, saying
# nothing about the missing repository or the missing admin rights that
# actually caused it.
#
# The shape test is what makes this reliable rather than the exit status
# alone: a token is alphanumeric, and no JSON body can be.
_rp_registration_token() {
  local token
  token=$(gh api -X POST "$(_rp_scope_path "$1" "$2")/actions/runners/registration-token" \
            --jq '.token' 2>/dev/null) || return 1
  case "${token}" in
    ''|*[!A-Za-z0-9]*) return 1 ;;
  esac
  echo "${token}"
}

# ---------------------------------------------------------------------------
# Per-pool reconfiguration lock
# ---------------------------------------------------------------------------
# Two reconfigurations of one pool must not interleave. A grow fetches the
# runner tarball and runs config.sh once per new runner, and a drain waits out
# whatever job is in flight, so either can hold the pool for a long time.
# --if-count does not help: both callers would pass their own check before
# either wrote a count.
#
# mkdir is the lock, for the reason the tick already uses it: atomic on every
# POSIX filesystem, and macOS has no flock.
#
# The holder writes its pid inside. That is what lets `up` and autoscale
# refuse to start a pool mid-reconfiguration without the holder blocking
# itself when it restarts the pool at the end of its own work.
#
# Staleness is measured from the lock's mtime, not from when it was taken,
# because a drain refreshes it on every poll. So a lock older than this means
# nobody is tending it, whatever it was doing.
RUNPOOL_RESIZE_STALE=1800

_rp_resize_lock_dir() { echo "${RUNPOOL_STATE_DIR}/resize.$1.lock"; }

_rp_resize_lock() {
  local lock age; lock="$(_rp_resize_lock_dir "$1")"
  mkdir -p "${RUNPOOL_STATE_DIR}" 2>/dev/null
  if mkdir "${lock}" 2>/dev/null; then echo $$ >| "${lock}/pid"; return 0; fi

  age=$(( $(_rp_now) - $(stat -f %m "${lock}" 2>/dev/null || echo 0) ))
  if [ "${age}" -lt "${RUNPOOL_RESIZE_STALE}" ]; then
    _rp_err "pool '$1' is already being reconfigured — wait for that to finish, then retry."
    return 1
  fi
  _rp_log "reconfigure: breaking a stale lock on '$1' (${age}s old)"
  rm -rf "${lock}"
  mkdir "${lock}" 2>/dev/null || { _rp_err "could not lock pool '$1' for reconfiguration"; return 1; }
  echo $$ >| "${lock}/pid"
  return 0
}

_rp_resize_unlock() { rm -rf "$(_rp_resize_lock_dir "$1")"; }

# Keep a long drain from being mistaken for an abandoned lock.
_rp_resize_lock_touch() { touch "$(_rp_resize_lock_dir "$1")" 2>/dev/null; }

# True when some OTHER live process holds the lock. Used by `up` and autoscale,
# both of which must leave a pool alone while it is being reconfigured, and
# both of which are also called BY the holder at the end of its own work — so
# testing only for the lock's existence would deadlock a resize against itself.
#
# A dead holder is not an obstacle: it left the lock behind and the stale break
# in _rp_resize_lock is what clears it.
_rp_resize_locked_by_other() {
  local lock pid; lock="$(_rp_resize_lock_dir "$1")"
  [ -d "${lock}" ] || return 1
  pid="$(cat "${lock}/pid" 2>/dev/null)"
  case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${pid}" = "$$" ] && return 1
  kill -0 "${pid}" 2>/dev/null
}

_rp_deregister_runner() {
  local runner_dir="$1" scope="$2" target="$3" id url
  [ -f "${runner_dir}/.runner" ] || return 0   # never registered
  id=$(grep -o '"agentId"[[:space:]]*:[[:space:]]*[0-9]*' "${runner_dir}/.runner" 2>/dev/null \
        | grep -o '[0-9]*$')
  [ -n "${id}" ] || { _rp_err "no agentId in ${runner_dir}/.runner — cannot deregister"; return 1; }
  url="$(_rp_scope_path "${scope}" "${target}")/actions/runners/${id}"
  gh api -X DELETE "${url}" >/dev/null 2>&1 || {
    _rp_err "DEREGISTER FAILED: runner id ${id} is still registered on ${target}. Remove it with: gh api -X DELETE ${url}"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# Launch agents
# ---------------------------------------------------------------------------
# The runner invokes a job hook with no arguments and gives no indication of
# which phase it is, so a single script cannot tell "started" from "completed".
# Generate a one-line wrapper per phase that passes it in. Written into the
# runtime directory rather than the repo, because the path to the user's hook
# is installation-specific.
_rp_write_hook_wrappers() {
  [ -n "${RUNPOOL_JOB_HOOK:-}" ] || return 0
  local dir="${RUNPOOL_HOOK_DIR}" phase old_dir="${RUNPOOL_BASE}/hooks"
  case "${RUNPOOL_JOB_HOOK}" in
    /*) ;;
    *) _rp_err "RUNPOOL_JOB_HOOK must be an absolute path: ${RUNPOOL_JOB_HOOK}"; return 1 ;;
  esac
  [ -x "${RUNPOOL_JOB_HOOK}" ] || {
    _rp_err "RUNPOOL_JOB_HOOK is not executable: ${RUNPOOL_JOB_HOOK}"
    return 1
  }
  case "${dir}" in
    /*) ;;
    *) _rp_err "RUNPOOL_HOOK_DIR must be an absolute path: ${dir}"; return 1 ;;
  esac
  case "${dir}" in
    *[[:space:]]*)
      _rp_err "RUNPOOL_HOOK_DIR cannot contain whitespace because the GitHub Actions runner does not quote Bash hook paths: ${dir}"
      return 1
      ;;
  esac
  mkdir -p "${dir}" 2>/dev/null || { _rp_err "could not create hook directory: ${dir}"; return 1; }
  for phase in started completed; do
    cat >| "${dir}/${phase}.sh" <<WRAP
#!/bin/sh
exec "${RUNPOOL_JOB_HOOK}" ${phase}
WRAP
    chmod +x "${dir}/${phase}.sh" 2>/dev/null || return 1
  done
  if [ "${old_dir}" != "${dir}" ]; then
    rm -f "${old_dir}/started.sh" "${old_dir}/completed.sh" 2>/dev/null || true
    rmdir "${old_dir}" 2>/dev/null || true
  fi
}

# Write the on-demand launch agent for one runner. $1 label, $2 runner_dir.
#
# Agents are written outside ~/Library/LaunchAgents on purpose, so that macOS
# never starts a runner at login. Pools come up because something asked, or
# because the tick saw queued work.
# RUNNER_MANUALLY_TRAP_SIG and ExitTimeOut are what make `--drain` possible,
# and neither does anything during ordinary operation.
#
# GitHub's run.sh checks that variable: set, it installs `trap 'kill -INT
# -$PID' INT TERM` and forwards SIGINT to the job's process group, which is
# the documented finish-the-current-job-then-exit path. Unset, SIGTERM kills
# run.sh and the job dies with it.
#
# `launchctl unload` sends SIGTERM and then SIGKILL once ExitTimeOut expires,
# and the default is around twenty seconds — far shorter than any real job, so
# the graceful path above would never get to finish. Six hours is generous
# enough that launchd never beats a drain to it. Not 0: the man page says zero
# means infinity and warns it can stall shutdown forever.
_rp_write_plist() {
  local label="$1" dir="$2" cache_dir="$3" legacy_layout="$4" plist="${RUNPOOL_AGENT_DIR}/$1.plist" hook="" pnpm_dir npm_dir tmp_dir
  if [ "${legacy_layout}" = "1" ]; then
    pnpm_dir="${dir}/.pnpm-store"
    npm_dir="${dir}/.npm-cache"
    tmp_dir="${dir}/tmp"
  else
    pnpm_dir="${cache_dir}/pnpm"
    npm_dir="${cache_dir}/npm"
    tmp_dir="${cache_dir}/tmp"
  fi
  if [ -n "${RUNPOOL_JOB_HOOK:-}" ]; then
    _rp_write_hook_wrappers || return 1
    hook="${RUNPOOL_HOOK_DIR}"
  fi
  {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${dir}/run.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${dir}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>npm_config_store_dir</key>
    <string>${pnpm_dir}</string>
    <key>npm_config_cache</key>
    <string>${npm_dir}</string>
    <key>TMPDIR</key>
    <string>${tmp_dir}</string>
    <key>RUNNER_MANUALLY_TRAP_SIG</key>
    <string>1</string>
PLIST
    if [ -n "${hook}" ]; then
      cat <<PLIST
    <key>ACTIONS_RUNNER_HOOK_JOB_STARTED</key>
    <string>${hook}/started.sh</string>
    <key>ACTIONS_RUNNER_HOOK_JOB_COMPLETED</key>
    <string>${hook}/completed.sh</string>
PLIST
    fi
    cat <<PLIST
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ExitTimeOut</key>
  <integer>21600</integer>
  <key>StandardOutPath</key>
  <string>${RUNPOOL_LOG_DIR}/${label}.log</string>
  <key>StandardErrorPath</key>
  <string>${RUNPOOL_LOG_DIR}/${label}.log</string>
</dict>
</plist>
PLIST
  } >| "${plist}"
}

# Per-runner package caches and temp are load-bearing, not tidiness. All
# runners share one HOME, so without npm_config_store_dir and npm_config_cache
# concurrent installs collide and pnpm fails with a reflink error. TMPDIR is
# redirected because the shared /var/folders temp is used by the OS and every
# running app, so a job that leaks there cannot be swept safely; one test suite
# once left 633k directories and 178GB behind. Pointing each runner at its own
# temp makes that leak collectable, which is what 'runpool clean' collects.
#
# TMPDIR is deliberately NOT dot-led, unlike the caches beside it. Library code
# roots things at os.tmpdir() without knowing where that points, and a dotted
# component in the absolute path silently disables anything applying
# dotfile-ignore rules to it. A file watcher rooted there ignored its whole tree
# and failed every run of one repository's suite for eight days, load
# independent, before anyone traced it to the path. The caches keep their dots
# because only npm and pnpm read them, and neither walks its own cache.

# Regenerate every pool's agents from its config. A running pool picks the
# change up on its next down/up; a stopped pool on its next up.
_rp_rewrite_plists() {
  local p i
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    i=1
    while [ "${i}" -le "${POOL_COUNT}" ]; do
      _rp_prepare_runner_cache "${p}" "${i}"
      _rp_write_plist "$(_rp_label "${p}" "${i}")" "${POOL_DIR}/runner-${i}" \
                      "$(_rp_runner_cache_dir "${p}" "${i}")" "${POOL_LEGACY_LAYOUT}" || return 1
      i=$(( i + 1 ))
    done
    _rp_log "rewrote agents for pool '${p}'"
  done
}
