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
_rp_env_LOG_DIR="${RUNPOOL_LOG_DIR:-}"
_rp_env_LABEL_NS="${RUNPOOL_LABEL_NS:-}"
_rp_env_IDLE_SECS="${RUNPOOL_IDLE_SECS:-}"
_rp_env_LOAD_WARN="${RUNPOOL_LOAD_WARN:-}"
_rp_env_NOTIFY_CMD="${RUNPOOL_NOTIFY_CMD:-}"
_rp_env_JOB_HOOK="${RUNPOOL_JOB_HOOK:-}"

# shellcheck disable=SC1090
[ -f "${RUNPOOL_CONFIG}" ] && . "${RUNPOOL_CONFIG}"

[ -n "${_rp_env_BASE}" ]        && RUNPOOL_BASE="${_rp_env_BASE}"
[ -n "${_rp_env_LOG_DIR}" ]     && RUNPOOL_LOG_DIR="${_rp_env_LOG_DIR}"
[ -n "${_rp_env_LABEL_NS}" ]    && RUNPOOL_LABEL_NS="${_rp_env_LABEL_NS}"
[ -n "${_rp_env_IDLE_SECS}" ]   && RUNPOOL_IDLE_SECS="${_rp_env_IDLE_SECS}"
[ -n "${_rp_env_LOAD_WARN}" ]   && RUNPOOL_LOAD_WARN="${_rp_env_LOAD_WARN}"
[ -n "${_rp_env_NOTIFY_CMD}" ]  && RUNPOOL_NOTIFY_CMD="${_rp_env_NOTIFY_CMD}"
[ -n "${_rp_env_JOB_HOOK}" ]    && RUNPOOL_JOB_HOOK="${_rp_env_JOB_HOOK}"
unset _rp_env_BASE _rp_env_LOG_DIR _rp_env_LABEL_NS _rp_env_IDLE_SECS \
      _rp_env_LOAD_WARN _rp_env_NOTIFY_CMD _rp_env_JOB_HOOK

# Where runners, pool definitions, launch agents and state live. Never the
# repository: it holds registration credentials.
RUNPOOL_BASE="${RUNPOOL_BASE:-${XDG_DATA_HOME:-${HOME}/.local/share}/runpool}"
RUNPOOL_POOL_DIR="${RUNPOOL_BASE}/pools"
RUNPOOL_AGENT_DIR="${RUNPOOL_BASE}/agents"
RUNPOOL_STATE_DIR="${RUNPOOL_BASE}/state"
RUNPOOL_LOG_DIR="${RUNPOOL_LOG_DIR:-${HOME}/Library/Logs/runpool}"

RUNPOOL_LOG="${RUNPOOL_LOG_DIR}/runpool.log"
RUNPOOL_ACTIVITY="${RUNPOOL_STATE_DIR}/activity"
RUNPOOL_PAUSE_FLAG="${RUNPOOL_STATE_DIR}/paused"
# shellcheck disable=SC2034  # read by lib/scheduler.sh
RUNPOOL_LAST_CLEAN="${RUNPOOL_STATE_DIR}/last-clean"

# Prefix for every launch-agent label this tool owns. Configurable so two
# installations on one machine cannot collide.
RUNPOOL_LABEL_NS="${RUNPOOL_LABEL_NS:-runpool}"

# Stand a pool down after this many seconds with no job running anywhere.
# Restarting a runner is cheap and needs no re-registration, so a short grace
# only avoids churn between rapid pushes inside one working session.
RUNPOOL_IDLE_SECS="${RUNPOOL_IDLE_SECS:-1200}"

# Warn above this 1-minute load average while jobs are running. Six times core
# count sits clear of ordinary work: a routine two-job build reaches roughly
# 3x on a 14-core machine, while the contention incidents this exists to catch
# ran at 163 and 184.
RUNPOOL_LOAD_WARN="${RUNPOOL_LOAD_WARN:-$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 8) * 6 ))}"

# Optional command receiving one JSON object on stdin whenever something is
# worth reporting. Unset by default: runpool works fully without a notifier and
# never grows one of its own. See lib/notify.sh and contrib/notify-webhook.sh.
RUNPOOL_NOTIFY_CMD="${RUNPOOL_NOTIFY_CMD:-}"

mkdir -p "${RUNPOOL_POOL_DIR}" "${RUNPOOL_AGENT_DIR}" \
         "${RUNPOOL_STATE_DIR}" "${RUNPOOL_LOG_DIR}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
_rp_log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "${RUNPOOL_LOG}" >&2
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

# ---------------------------------------------------------------------------
# Pools
# ---------------------------------------------------------------------------
_rp_pool_conf() { echo "${RUNPOOL_POOL_DIR}/$1.conf"; }

# Load POOL_* for pool $1 into the caller's scope. POOL_WATCH is optional and
# only set on org pools, so every reader must use "${POOL_WATCH:-}".
_rp_load_pool() {
  local conf; conf="$(_rp_pool_conf "$1")"
  if [ ! -f "${conf}" ]; then
    _rp_err "unknown pool: $1 (see 'runpool pools')"; return 1
  fi
  # Cleared before sourcing so that `set -u` does not trip on a repo pool,
  # whose config file has no POOL_WATCH line at all.
  # shellcheck disable=SC2034  # read by lib/scheduler.sh
  POOL_WATCH=""
  # shellcheck disable=SC1090
  . "${conf}"
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

# '>|' rather than '>': a shell with noclobber set refuses to truncate an
# existing file, which silently stopped this timestamp updating and left the
# idle sweep reading a frozen clock.
_rp_touch_activity() { _rp_now >| "${RUNPOOL_ACTIVITY}"; }

_rp_paused() { [ -f "${RUNPOOL_PAUSE_FLAG}" ]; }

# GitHub API prefix for a pool's scope: orgs/<org> or repos/<owner>/<repo>.
_rp_scope_path() {
  if [ "$1" = "org" ]; then echo "/orgs/$2"; else echo "/repos/$2"; fi
}

# ---------------------------------------------------------------------------
# Runner binary
# ---------------------------------------------------------------------------
# Fetch the latest osx-arm64 runner tarball once and echo its local path.
_rp_fetch_runner_tarball() {
  local url path jqf attempt
  # '[.]' matches a literal dot without a backslash, which keeps this filter
  # safe to carry through shells that mangle escapes.
  jqf='[.assets[] | select(.name | test("osx-arm64.*[.]tar[.]gz$")) | .browser_download_url][0]'
  # releases/latest intermittently returns empty under secondary rate limiting,
  # so retry with backoff. Once cached this is skipped entirely.
  for attempt in 1 2 3 4 5; do
    url=$(gh api repos/actions/runner/releases/latest --jq "${jqf}" 2>/dev/null)
    [ -n "${url}" ] && break
    sleep $(( attempt * 2 ))
  done
  [ -n "${url}" ] || { _rp_err "could not resolve the osx-arm64 runner tarball after retries"; return 1; }
  path="${RUNPOOL_BASE}/.cache/${url##*/}"
  mkdir -p "${RUNPOOL_BASE}/.cache" 2>/dev/null
  if [ ! -f "${path}" ]; then
    _rp_log "downloading runner: ${url##*/}"
    curl -sSL "${url}" -o "${path}" || return 1
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
# Write the on-demand launch agent for one runner. $1 label, $2 runner_dir.
#
# Agents are written outside ~/Library/LaunchAgents on purpose, so that macOS
# never starts a runner at login. Pools come up because something asked, or
# because the tick saw queued work.
_rp_write_plist() {
  local label="$1" dir="$2" plist="${RUNPOOL_AGENT_DIR}/$1.plist" hook=""
  [ -n "${RUNPOOL_JOB_HOOK:-}" ] && hook="${RUNPOOL_JOB_HOOK}"
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
    <string>${dir}/.pnpm-store</string>
    <key>npm_config_cache</key>
    <string>${dir}/.npm-cache</string>
    <key>TMPDIR</key>
    <string>${dir}/.tmp</string>
PLIST
    if [ -n "${hook}" ]; then
      cat <<PLIST
    <key>ACTIONS_RUNNER_HOOK_JOB_STARTED</key>
    <string>${hook}</string>
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

# Regenerate every pool's agents from its config. A running pool picks the
# change up on its next down/up; a stopped pool on its next up.
_rp_rewrite_plists() {
  local p i
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    i=1
    while [ "${i}" -le "${POOL_COUNT}" ]; do
      _rp_write_plist "$(_rp_label "${p}" "${i}")" "${POOL_DIR}/runner-${i}"
      i=$(( i + 1 ))
    done
    _rp_log "rewrote agents for pool '${p}'"
  done
}
