# scheduler.sh — reporting, autoscaling, idle standdown, cleaning, and the
# launch agents that drive them.
#
# This is what makes on-demand actually hands-off. A push queues a job and the
# pool it needs comes up within a tick, without anyone running a command.

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
# What GitHub actually has for the loaded pool's scope, as "<registered> <online>".
# Echoes "? ?" when the API cannot be reached, so status degrades to a local
# view rather than reporting a confident falsehood.
_rp_gh_runners() {
  local out
  out=$(gh api "$(_rp_scope_path "${POOL_SCOPE}" "${POOL_TARGET}")/actions/runners" \
        --jq '"\(.total_count) \([.runners[] | select(.status == "online")] | length)"' 2>/dev/null)
  [ -n "${out}" ] && echo "${out}" || echo "? ?"
}

# How many of a pool's agents are loaded.
_rp_running_in() {
  local pool="$1" count="$2" i=1 running=0
  while [ "${i}" -le "${count}" ]; do
    _rp_agent_loaded "$(_rp_label "${pool}" "${i}")" && running=$(( running + 1 ))
    i=$(( i + 1 ))
  done
  echo "${running}"
}

# Reports GitHub's view alongside the local one, deliberately. GitHub prunes
# the registration of a long-idle runner, which leaves a pool that starts
# cleanly, looks healthy in every local check, and picks up nothing. Reporting
# only the local view hid exactly that for three weeks.
_rp_status() {
  [ "${1:-}" = "--json" ] && { _rp_status_json; return $?; }

  if _rp_paused; then echo "GLOBAL: paused (runpool off)"; else echo "GLOBAL: active"; fi
  local total_running=0 total_busy=0 p running busy gh reg online note warn=0
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    running="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    busy="$(_rp_busy_in "${POOL_DIR}")"
    gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
    total_running=$(( total_running + running )); total_busy=$(( total_busy + busy ))

    note=""
    if [ "${reg}" = "?" ]; then
      note="  (github unreachable)"
    elif [ "${reg}" = "0" ]; then
      note="  ** NOT REGISTERED — jobs will queue forever **"; warn=1
    elif [ "${running}" -gt 0 ] && [ "${online}" = "0" ]; then
      note="  ** started but not connecting to github **"; warn=1
    elif [ "${reg}" != "${POOL_COUNT}" ]; then
      note="  (github has ${reg}, pool expects ${POOL_COUNT})"
    fi

    printf "  %-10s %-4s %-20s  running %s/%s  busy %s  github %s/%s%s\n" \
      "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" "${running}" "${POOL_COUNT}" \
      "${busy}" "${online}" "${reg}" "${note}"
  done
  echo "  ----"
  echo "  TOTAL running ${total_running}, busy ${total_busy}"
  echo "  github column is online/registered as GitHub sees it"
  [ "${warn}" = "1" ] && echo "  fix a broken pool with: runpool reregister <pool>"
  return 0
}

# Machine-readable status, so anything wrapping this tool reads structured data
# rather than scraping prose. Hand-assembled rather than shelled out to jq,
# because none of these values can contain a character needing escaping: pool
# names and targets come from GitHub, and the rest are integers.
_rp_status_json() {
  local p running busy gh reg online first=1 paused="false"
  _rp_paused && paused="true"
  printf '{"paused":%s,"pools":[' "${paused}"
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    running="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    busy="$(_rp_busy_in "${POOL_DIR}")"
    gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
    [ "${reg}" = "?" ] && reg="null"
    [ "${online}" = "?" ] && online="null"
    [ "${first}" = "1" ] || printf ','
    first=0
    printf '{"name":"%s","scope":"%s","target":"%s","count":%s,"running":%s,"busy":%s,"github_registered":%s,"github_online":%s}' \
      "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" "${POOL_COUNT}" "${running}" "${busy}" "${reg}" "${online}"
  done
  printf ']}\n'
}

_rp_pools() {
  local p found=0
  for p in $(_rp_pool_names); do
    found=1; _rp_load_pool "${p}" || continue
    printf "  %-10s %-4s %-20s count=%s\n" "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" "${POOL_COUNT}"
  done
  [ "${found}" = "0" ] && echo "  (no pools registered — 'runpool register <pool> --repo OWNER/REPO')"
  return 0
}

# ---------------------------------------------------------------------------
# autoscale — bring a pool up when it has queued work
# ---------------------------------------------------------------------------
# Only DOWN pools are polled: one that is already up is serving, so during
# active work this makes no API calls at all. An org pool polls the repos named
# in POOL_WATCH, because GitHub exposes queued runs per repository rather than
# per organisation.
_rp_autoscale() {
  _rp_paused && return 0
  local p up queued q wr
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    up="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    [ "${up}" -gt 0 ] && continue
    queued=0
    if [ "${POOL_SCOPE}" = "repo" ]; then
      q=$(gh api "/repos/${POOL_TARGET}/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)
      queued="${q:-0}"
    else
      for wr in $(echo "${POOL_WATCH:-}" | tr ',' ' '); do
        [ -n "${wr}" ] || continue
        q=$(gh api "/repos/${wr}/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)
        queued=$(( queued + ${q:-0} ))
      done
    fi
    case "${queued}" in ''|*[!0-9]*) queued=0 ;; esac
    if [ "${queued}" -gt 0 ]; then
      _rp_log "autoscale: '${p}' has ${queued} queued job(s) — bringing up"
      _rp_up "${p}"
    fi
  done
}

# ---------------------------------------------------------------------------
# sweep — stand pools down once nothing has run for a while
# ---------------------------------------------------------------------------
_rp_sweep() {
  local p busy_total=0 any_loaded=0 last idle
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    busy_total=$(( busy_total + $(_rp_busy_in "${POOL_DIR}") ))
    [ "$(_rp_running_in "${p}" "${POOL_COUNT}")" -gt 0 ] && any_loaded=1
  done
  # Something is running: keep everything up and reset the idle clock.
  if [ "${busy_total}" -gt 0 ]; then _rp_touch_activity; return 0; fi
  [ "${any_loaded}" = "1" ] || return 0
  last=$(cat "${RUNPOOL_ACTIVITY}" 2>/dev/null || echo 0)
  idle=$(( $(_rp_now) - last ))
  if [ "${idle}" -ge "${RUNPOOL_IDLE_SECS}" ]; then
    _rp_log "sweep: idle ${idle}s, threshold ${RUNPOOL_IDLE_SECS}s — standing all pools down"
    _rp_down_all --force
  fi
}

# ---------------------------------------------------------------------------
# clean — prune accumulated state (skips any pool with a job running)
# ---------------------------------------------------------------------------
# Persistent runners never clean up after themselves, which is the price of
# warm caches. Everything here is either regenerable or already collected
# elsewhere, so nothing is lost.
_rp_clean() {
  # Every local declared once, at the top. Re-running 'local' for an existing
  # local inside a loop makes some shells print it as a typeset assignment,
  # which once leaked stray lines into the nightly log.
  local only="${1:-}" p freed_kb=0 sz rd wd dd td live keep vols nvols
  for p in $(_rp_pool_names); do
    [ -n "${only}" ] && [ "${only}" != "${p}" ] && continue
    _rp_load_pool "${p}" || continue
    if [ "$(_rp_busy_in "${POOL_DIR}")" -gt 0 ]; then
      _rp_log "clean: '${p}' has a job running — skipping"; continue
    fi
    # Every runner directory that exists, not 1..POOL_COUNT: a pool whose count
    # was lowered leaves higher-numbered directories behind, and counting to
    # POOL_COUNT means their junk is never collected again.
    for rd in "${POOL_DIR}"/runner-*/; do
      [ -d "${rd}" ] || continue
      rd="${rd%/}"

      # Job checkouts and build output.
      wd="${rd}/_work"
      if [ -d "${wd}" ]; then
        sz=$(du -sk "${wd}" 2>/dev/null | awk '{print $1}')
        find "${wd:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        freed_kb=$(( freed_kb + ${sz:-0} ))
      fi

      # Per-runner temp. Safe to wipe wholesale: nothing but this runner's own
      # jobs ever writes here, which is the entire reason it is redirected.
      td="${rd}/.tmp"
      if [ -d "${td}" ]; then
        sz=$(du -sk "${td}" 2>/dev/null | awk '{print $1}')
        find "${td:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        freed_kb=$(( freed_kb + ${sz:-0} ))
      fi
      mkdir -p "${td}" 2>/dev/null

      # Runner diagnostics. Rotated loosely and reaching ~150MB per runner. Job
      # logs live in the GitHub UI, so nothing here is the only copy.
      dd="${rd}/_diag"
      if [ -d "${dd}" ]; then
        sz=$(du -sk "${dd}" 2>/dev/null | awk '{print $1}')
        find "${dd:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        freed_kb=$(( freed_kb + ${sz:-0} ))
      fi

      # Superseded runner binaries. Self-update unpacks a new bin.<version> and
      # externals.<version>, repoints the symlinks, and leaves the previous
      # version behind for good: roughly 580MB per runner per upgrade.
      for keep in bin externals; do
        live="$(readlink "${rd}/${keep}" 2>/dev/null)"; live="${live##*/}"
        [ -n "${live}" ] || continue
        while IFS= read -r dd; do
          [ -d "${dd}" ] || continue
          [ "${dd##*/}" = "${live}" ] && continue
          sz=$(du -sk "${dd}" 2>/dev/null | awk '{print $1}')
          rm -rf "${dd}" 2>/dev/null
          freed_kb=$(( freed_kb + ${sz:-0} ))
        done < <(find "${rd}" -mindepth 1 -maxdepth 1 -type d -name "${keep}.*" 2>/dev/null)
      done

      # Package stores are a cache worth keeping but an unbounded one. Prune
      # rather than delete, so the next run starts warm.
      if [ -d "${rd}/.pnpm-store" ] && command -v pnpm >/dev/null 2>&1; then
        sz=$(du -sk "${rd}/.pnpm-store" 2>/dev/null | awk '{print $1}')
        npm_config_store_dir="${rd}/.pnpm-store" pnpm store prune >/dev/null 2>&1
        freed_kb=$(( freed_kb + sz - $(du -sk "${rd}/.pnpm-store" 2>/dev/null | awk '{print $1}') ))
      fi
    done
  done

  # Anonymous dangling Docker volumes: refuse left by test containers removed
  # without -v, which nothing can reference again. Only the 64-hex anonymous
  # form is pruned, because a *named* dangling volume may be parked on purpose.
  # Safe while jobs run, since a live container's volumes are never dangling.
  if command -v docker >/dev/null 2>&1; then
    vols=$(docker volume ls -qf dangling=true 2>/dev/null | grep -E '^[0-9a-f]{64}$' || true)
    if [ -n "${vols}" ]; then
      nvols=$(printf '%s\n' "${vols}" | wc -l | tr -d ' ')
      printf '%s\n' "${vols}" | xargs docker volume rm >/dev/null 2>&1 || true
      _rp_log "clean: pruned ${nvols} anonymous dangling docker volume(s)"
    fi
  fi

  _rp_now >| "${RUNPOOL_LAST_CLEAN}"
  _rp_log "clean: freed ~$(( freed_kb / 1024 ))MB"
}

# The scheduled clean skips any pool with a job running, and a skipped night
# simply waited 24h for the next one, so a machine busy at 04:00 could go days
# uncleaned. This retries as soon as the pools are genuinely idle.
_rp_clean_if_overdue() {
  _rp_paused && return 0
  local p busy=0 last age
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    busy=$(( busy + $(_rp_busy_in "${POOL_DIR}") ))
  done
  [ "${busy}" -gt 0 ] && return 0
  last=$(cat "${RUNPOOL_LAST_CLEAN}" 2>/dev/null || echo 0)
  age=$(( $(_rp_now) - last ))
  if [ "${age}" -ge 86400 ]; then
    _rp_log "clean: overdue by $(( age / 3600 ))h and pools are idle — running now"
    _rp_clean ""
  fi
}

_rp_tick() { _rp_autoscale; _rp_sweep; _rp_load_check; _rp_health_check; _rp_clean_if_overdue; }

# ---------------------------------------------------------------------------
# pause / resume — global kill switch, default resumed
# ---------------------------------------------------------------------------
_rp_pause()  { : >| "${RUNPOOL_PAUSE_FLAG}"; _rp_down_all --force; _rp_log "paused: all runners down, autoscale off"; }
_rp_resume() { rm -f "${RUNPOOL_PAUSE_FLAG}"; _rp_log "resumed: on-demand again"; }

# ---------------------------------------------------------------------------
# schedule — install or remove the background agents
# ---------------------------------------------------------------------------
_rp_write_cron_plist() {
  local label="$1" arg="$2" interval_key="$3" interval_val="$4" bin="$5"
  cat >| "${HOME}/Library/LaunchAgents/${label}.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array>
    <string>${bin}</string><string>${arg}</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  ${interval_key}${interval_val}
  <key>StandardOutPath</key><string>${RUNPOOL_LOG_DIR}/${arg}.log</string>
  <key>StandardErrorPath</key><string>${RUNPOOL_LOG_DIR}/${arg}.log</string>
</dict></plist>
PL
}

_rp_schedule_install() {
  local bin tick clean
  bin="$(_rp_self_path)"
  tick="${RUNPOOL_LABEL_NS}.tick"
  clean="${RUNPOOL_LABEL_NS}.clean"

  # tick every 60s: bring pools up on queued work, then stand idle ones down.
  # Fast enough that a push from anywhere gets a runner inside a minute.
  _rp_write_cron_plist "${tick}" tick "<key>StartInterval</key>" "<integer>60</integer>" "${bin}"
  _rp_write_cron_plist "${clean}" clean \
    "<key>StartCalendarInterval</key>" "<dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>" \
    "${bin}"

  launchctl unload "${HOME}/Library/LaunchAgents/${tick}.plist" 2>/dev/null
  launchctl load   "${HOME}/Library/LaunchAgents/${tick}.plist"
  launchctl unload "${HOME}/Library/LaunchAgents/${clean}.plist" 2>/dev/null
  launchctl load   "${HOME}/Library/LaunchAgents/${clean}.plist"
  _rp_log "scheduler installed: tick 60s (autoscale, idle-down, contention), clean daily 04:00"
}

_rp_schedule_remove() {
  local p
  for p in "${RUNPOOL_LABEL_NS}.tick" "${RUNPOOL_LABEL_NS}.clean"; do
    launchctl unload "${HOME}/Library/LaunchAgents/${p}.plist" 2>/dev/null
    rm -f "${HOME}/Library/LaunchAgents/${p}.plist"
  done
  _rp_log "scheduler removed"
}

_rp_schedule() {
  case "${1:-}" in
    install) _rp_schedule_install ;;
    remove)  _rp_schedule_remove ;;
    *) _rp_err "usage: runpool schedule install|remove"; return 1 ;;
  esac
}
