# shellcheck shell=bash
# notify.sh — the optional notifier hook, and the conditions worth reporting.
#
# runpool detects. It does not deliver. There is no mail sending here, no
# address routing, no severity policy, no dedup window and no dependency on any
# particular service. An earlier version of this tool had all five, and that is
# precisely why it could not be published: none of it was anyone else's.
#
# Set RUNPOOL_NOTIFY_CMD to a command that reads one JSON object on stdin.
# Unset, every call here is a no-op and the tool works fully without it.
# See contrib/notify-webhook.sh for a reference implementation.
#
# WHAT IS DELIBERATELY NOT REPORTED
#
# Failed workflow runs. Watching CI *results* is observability and belongs to
# whatever receives these alerts, which can poll GitHub directly and does not
# need a laptop to be awake to do it. runpool reports only runners that are
# registered incorrectly or running but not reachable. That condition belongs
# to the pool and otherwise leaves jobs queued against capacity that looks
# healthy locally.
#
# Nothing watches runpool itself, and that is an accepted gap rather than an
# oversight. A dead poller on a laptop cannot be polled from outside, and a
# failed CI run stays visible on its pull request regardless, so the situation
# surfaces within a day. This is a CI helper, not a production pager, and the
# point of the exercise was fewer alerts rather than a monitor for the monitor.

RUNPOOL_HEALTH_STATE="${RUNPOOL_STATE_DIR}/health-checked"

# Minimal JSON string escaping: backslash and double quote, then strip control
# characters. Enough for the values this tool actually produces.
_rp_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

# Emit one notification.
#   $1 severity  critical | warning | info
#   $2 title     one line
#   $3 key       stable identifier grouping a condition with its recurrence
#   $4 detail    optional prose
#   $5 fields    optional pre-rendered JSON object body, without braces
_rp_notify() {
  [ -n "${RUNPOOL_NOTIFY_CMD}" ] || return 0
  local severity="$1" title="$2" key="$3" detail="${4:-}" fields="${5:-}" json
  json="{\"source\":\"runpool\""
  json="${json},\"severity\":\"$(_rp_json_escape "${severity}")\""
  json="${json},\"title\":\"$(_rp_json_escape "${title}")\""
  json="${json},\"key\":\"$(_rp_json_escape "${key}")\""
  [ -n "${detail}" ] && json="${json},\"detail\":\"$(_rp_json_escape "${detail}")\""
  [ -n "${fields}" ] && json="${json},\"fields\":{${fields}}"
  json="${json}}"
  if printf '%s\n' "${json}" | ${RUNPOOL_NOTIFY_CMD} >/dev/null 2>&1; then
    _rp_log "notified: [${severity}] ${title}"
  else
    _rp_err "notifier failed: ${title}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Pool reachability
# ---------------------------------------------------------------------------
# GitHub deletes the registration of a runner that has not connected for a
# while. The local install is unaffected and still looks entirely healthy: it
# starts, connects, and then silently picks up nothing, so jobs queue forever
# against a pool that reports as running. This went unnoticed for three weeks
# once, and 'runpool status' only surfaces it if somebody thinks to look.
#
# Checked at most hourly, because it costs one API call per pool.
_rp_health_check() {
  local now last p gh reg online
  now=$(_rp_now); last=$(cat "${RUNPOOL_HEALTH_STATE}" 2>/dev/null || echo 0)
  [ $(( now - last )) -lt 3600 ] && return 0
  echo "${now}" >| "${RUNPOOL_HEALTH_STATE}"
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
    [ "${reg}" = "?" ] && continue   # GitHub unreachable is not a pool fault
    if [ "${reg}" = "0" ]; then
      _rp_notify critical \
        "Pool '${p}' is not registered with GitHub" \
        "runpool/unregistered/${p}" \
        "GitHub has no runners for this pool, so any job routed to it will queue forever. Registrations are pruned after a long idle period." \
        "\"Pool\":\"${p}\",\"Target\":\"${POOL_TARGET}\",\"Fix\":\"runpool reregister ${p}\""
    elif [ "$(_rp_running_in "${p}" "${POOL_COUNT}")" -gt 0 ] && [ "${online}" = "0" ]; then
      _rp_notify critical \
        "Pool '${p}' is running but not reaching GitHub" \
        "runpool/offline/${p}" \
        "The runners started but none has connected. Jobs will queue against a pool that looks healthy locally." \
        "\"Pool\":\"${p}\",\"Target\":\"${POOL_TARGET}\",\"Registered\":\"${reg}\",\"Online\":\"${online}\""
    fi
  done
}
