# shellcheck shell=bash
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

# The one judgement about a pool's registration, as a single token:
#
#   unreachable   GitHub could not be asked, so nothing here is a pool fault
#   unregistered  GitHub has no runners at all — jobs queue forever
#   offline       runners are up locally and none has reached GitHub
#   miscount      GitHub's count differs from what the pool expects
#   ok
#
# `status` renders this as a note in a table and `doctor` as a check with a
# remedy attached. They are two presentations of one decision, and a second
# copy of the decision is a second thing to keep in step with how GitHub
# actually behaves — which is the part that took three weeks to learn once.
#
# The order is load-bearing: '?' has to be tested before anything treats these
# as numbers, and 'unregistered' before 'miscount', which would otherwise
# swallow it.
#   $1 registered  $2 online  $3 running locally  $4 expected count
_rp_gh_state() {
  if   [ "$1" = "?" ];                       then echo unreachable
  elif [ "$1" = "0" ];                       then echo unregistered
  elif [ "$3" -gt 0 ] && [ "$2" = "0" ];     then echo offline
  elif [ "$1" != "$4" ];                     then echo miscount
  else                                            echo ok
  fi
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
  local as_json=0 local_only=0 arg total_running=0 total_busy=0 p running busy gh reg online gh_display note warn=0
  for arg in "$@"; do
    case "${arg}" in
      --json)  as_json=1 ;;
      --local) local_only=1 ;;
      *) _rp_err "unknown flag: ${arg} (usage: runpool status [--json] [--local])"; return 1 ;;
    esac
  done
  [ "${as_json}" = "1" ] && { _rp_status_json "${local_only}"; return $?; }

  if _rp_paused; then echo "Status: paused"; else echo "Status: active"; fi
  echo ""
  printf "  %-10s %-6s %-20s %7s %5s  %s\n" "Pool" "Scope" "Target" "Running" "Busy" "GitHub"
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    running="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    busy="$(_rp_busy_in "${POOL_DIR}")"
    total_running=$(( total_running + running )); total_busy=$(( total_busy + busy ))

    if [ "${local_only}" = "1" ]; then
      gh_display="not checked"
      note=""
    else
      gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
      gh_display="${online}/${reg}"
      note=""
      case "$(_rp_gh_state "${reg}" "${online}" "${running}" "${POOL_COUNT}")" in
        unreachable)  gh_display="unreachable" ;;
        unregistered) note="  (not registered; jobs will queue)"; warn=1 ;;
        offline)      note="  (started but not connected)"; warn=1 ;;
        miscount)     note="  (pool expects ${POOL_COUNT})" ;;
      esac
    fi

    _rp_pool_paused "${p}" && note="  (paused)${note}"
    printf "  %-10s %-6s %-20s %7s %5s  %s%s\n" \
      "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" "${running}/${POOL_COUNT}" \
      "${busy}" "${gh_display}" "${note}"
  done
  echo ""
  echo "Total: ${total_running} runners online, ${total_busy} jobs running."
  if [ "${local_only}" = "1" ]; then
    echo "GitHub: not checked (--local)."
  else
    echo "GitHub: online / registered."
  fi
  [ "${warn}" = "1" ] && echo "Fix a broken pool with: runpool reregister <pool>"
  return 0
}

# Machine-readable status, so anything wrapping this tool reads structured data
# rather than scraping prose. Hand-assembled rather than shelled out to jq,
# because none of these values can contain a character needing escaping:
# targets and watched repos are GitHub identifiers, pool names are constrained
# by _rp_valid_pool_name at register, and the rest are integers or fixed
# strings. That validation is what makes this safe; before it existed a pool
# name containing a double quote produced malformed JSON here.
#
# $1 local_only: skip the GitHub query and report its two fields as null.
# A caller refreshing on a timer must use it. One API call per pool per minute
# is thousands a day, and it makes a passive readout fail whenever the network
# does, which is the opposite of what a passive readout is for.
_rp_status_json() {
  local local_only="${1:-0}" p running busy gh reg online first=1 paused="false" pool_paused="false" wr wfirst
  _rp_paused && paused="true"
  # Machine state belongs here rather than being recomputed by every caller.
  # The load threshold is configurable, so a status consumer that derived it
  # from core count would quietly disagree with other status consumers.
  local load cores
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
  printf '{"paused":%s,"local":%s,"machine":{"load":%s,"cores":%s,"load_warn":%s},"paths":{"base":"%s","cache":"%s","log":"%s","log_dir":"%s","telemetry":"%s"},"pools":[' \
    "${paused}" "$( [ "${local_only}" = "1" ] && echo true || echo false )" \
    "${load:-0}" "${cores:-0}" "${RUNPOOL_LOAD_WARN}" \
    "${RUNPOOL_BASE}" "${RUNPOOL_CACHE_DIR}" "${RUNPOOL_LOG}" "${RUNPOOL_LOG_DIR}" "${RUNPOOL_BASE}/telemetry/jobs.jsonl"
  for p in $(_rp_pool_names); do
    _rp_load_pool "${p}" || continue
    running="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    busy="$(_rp_busy_in "${POOL_DIR}")"
    if [ "${local_only}" = "1" ]; then
      reg="null"; online="null"
    else
      gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
      [ "${reg}" = "?" ] && reg="null"
      [ "${online}" = "?" ] && online="null"
    fi
    [ "${first}" = "1" ] || printf ','
    first=0
    _rp_pool_paused "${p}" && pool_paused="true" || pool_paused="false"
    printf '{"name":"%s","scope":"%s","target":"%s","count":%s,"running":%s,"busy":%s,"paused":%s,"github_registered":%s,"github_online":%s,"watch":[' \
      "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" "${POOL_COUNT}" "${running}" "${busy}" "${pool_paused}" "${reg}" "${online}"
    # An org pool serves many repositories and only its config knows which.
    # Without this a caller cannot show what a pool actually covers.
    wfirst=1
    for wr in $(echo "${POOL_WATCH:-}" | tr ',' ' '); do
      [ -n "${wr}" ] || continue
      [ "${wfirst}" = "1" ] || printf ','
      wfirst=0
      printf '"%s"' "${wr}"
    done
    printf ']}'
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
# doctor — "why is nothing picking this up", in one command
# ---------------------------------------------------------------------------
# Every check here is answerable today from `status`, the log, and a launchctl
# invocation nobody thinks to run. The value is having them in one place with a
# remedy attached, and one of them is answerable from nothing at all: if the
# tick agent is not loaded, no pool autoscales, every job waits for a manual
# `runpool up`, and `status` reports every pool as perfectly healthy — because
# locally they are.
#
# STRICTLY READ-ONLY, and that is a boundary rather than a preference. A
# diagnostic that repairs is one nobody can run safely while confused, and each
# repair already exists as its own command. This file reports; lib/lifecycle.sh
# changes things. The moment this prunes a disk or re-registers a pool it
# belongs over there instead.
#
# Findings accumulate in two file-scope counters rather than being returned,
# because a function has one integer exit status and these have to survive a
# loop over the pools.
_rp_doctor_fails=0
_rp_doctor_warns=0

# Four markers, all four characters wide so the messages line up:
#   OK    nothing to do
#   INFO  context, or a check that could not be run — not a judgement
#   WARN  worth knowing, does not fail the command
#   FAIL  something is actually wrong, and the exit status says so
# $1 headline, $2 optional remedy on a continuation line.
_rp_doctor_ok()   { printf '  OK    %s\n' "$1"; }
_rp_doctor_note() { printf '  INFO  %s\n' "$1"; }
_rp_doctor_warn() {
  _rp_doctor_warns=$(( _rp_doctor_warns + 1 ))
  printf '  WARN  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  return 0   # the test above is the last command, and an absent remedy is fine
}
_rp_doctor_fail() {
  _rp_doctor_fails=$(( _rp_doctor_fails + 1 ))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  return 0
}

_rp_doctor() {
  [ $# -eq 0 ] || { _rp_err "doctor takes no arguments (usage: runpool doctor)"; return 1; }

  local gh_ok=1 pools=0 seen_orgs="" p running gh reg online
  local tick clean i missing avail_kb cache_avail_kb free mode other phase hook_fails
  local all_repos unwatched

  _rp_doctor_fails=0
  _rp_doctor_warns=0

  echo "runpool doctor"

  # --- the global kill switch --------------------------------------------
  echo ""
  echo "global"
  if _rp_paused; then
    _rp_doctor_fail "runpool is paused: every pool is down and autoscale is off" \
                    "fix: runpool resume"
  else
    _rp_doctor_ok "not paused"
  fi
  [ "${RUNPOOL_USING_LEGACY}" = "1" ] && _rp_doctor_note \
    "legacy storage is active at ${RUNPOOL_BASE}; run 'runpool migrate-storage --dry-run' to preview the move"

  # --- gh ----------------------------------------------------------------
  # _rp_require tests for the binary and stops there, which is the whole gap:
  # an expired token fails every API call and each caller then degrades to its
  # own quiet fallback. _rp_gh_runners echoes '? ?' and reports as unreachable;
  # _rp_autoscale reads a queued count of zero and never brings anything up.
  #
  # command -v rather than _rp_require, because that writes to stderr and this
  # report is a structured thing on stdout.
  echo ""
  echo "github cli"
  if ! command -v gh >/dev/null 2>&1; then
    gh_ok=0
    _rp_doctor_fail "gh is not installed, and every GitHub call runpool makes goes through it" \
                    "fix: brew install gh, then gh auth login"
  elif ! gh auth status >/dev/null 2>&1; then
    gh_ok=0
    _rp_doctor_fail "gh is installed but not authenticated, so nothing can register, poll or report" \
                    "fix: gh auth login   (checks below that ask GitHub are skipped)"
  else
    _rp_doctor_ok "gh is installed and authenticated"
  fi

  # --- the scheduler agents ----------------------------------------------
  # The highest-value check here, and the only one nothing else performs.
  # `schedule install` writes these two once and nothing ever looks at them
  # again.
  echo ""
  echo "scheduler"
  tick="${RUNPOOL_LABEL_NS}.tick"
  clean="${RUNPOOL_LABEL_NS}.clean"
  if _rp_agent_loaded "${tick}"; then
    _rp_doctor_ok "the tick agent is loaded: autoscale, idle standdown and health"
  elif [ -f "${HOME}/Library/LaunchAgents/${tick}.plist" ]; then
    _rp_doctor_fail "the tick agent is installed but not loaded, so nothing autoscales: a queued job waits for a manual 'runpool up' and every pool still reports as healthy" \
                    "fix: runpool schedule install   (rewrites and reloads it)"
  else
    _rp_doctor_fail "the tick agent is not installed, so nothing autoscales: a queued job waits for a manual 'runpool up' and every pool still reports as healthy" \
                    "fix: runpool schedule install"
  fi
  if _rp_agent_loaded "${clean}"; then
    _rp_doctor_ok "the clean agent is loaded: daily prune at 04:00"
  else
    _rp_doctor_warn "the clean agent is not loaded, so work directories, diagnostics and superseded runner binaries accrue with nothing collecting them" \
                    "fix: runpool schedule install, or 'runpool clean' by hand"
  fi

  # --- job hooks ---------------------------------------------------------
  echo ""
  echo "job hooks"
  if [ -z "${RUNPOOL_JOB_HOOK:-}" ]; then
    _rp_doctor_note "no job hook is configured"
  else
    hook_fails="${_rp_doctor_fails}"
    case "${RUNPOOL_HOOK_DIR}" in
      /*) ;;
      *) _rp_doctor_fail "the hook launcher directory is not absolute: ${RUNPOOL_HOOK_DIR}" \
                         "fix: set RUNPOOL_HOOK_DIR to an absolute path without whitespace, then runpool rewrite-agents" ;;
    esac
    case "${RUNPOOL_HOOK_DIR}" in
      *[[:space:]]*)
        _rp_doctor_fail "the hook launcher directory contains whitespace, which the GitHub Actions runner does not quote: ${RUNPOOL_HOOK_DIR}" \
                        "fix: remove RUNPOOL_HOOK_DIR from the config to use the safe default, then runpool rewrite-agents"
        ;;
    esac
    if [ ! -x "${RUNPOOL_JOB_HOOK}" ]; then
      _rp_doctor_fail "the configured job hook is not executable: ${RUNPOOL_JOB_HOOK}" \
                      "fix: correct RUNPOOL_JOB_HOOK or make it executable, then runpool rewrite-agents"
    fi
    for phase in started completed; do
      [ -x "${RUNPOOL_HOOK_DIR}/${phase}.sh" ] || _rp_doctor_fail \
        "the ${phase} job-hook launcher is missing or not executable: ${RUNPOOL_HOOK_DIR}/${phase}.sh" \
        "fix: runpool rewrite-agents"
    done
    [ "${_rp_doctor_fails}" = "${hook_fails}" ] && _rp_doctor_ok "job-hook launchers are executable at a runner-safe path"
  fi

  # --- pools --------------------------------------------------------------
  echo ""
  echo "pools"
  for p in $(_rp_pool_names); do
    # Counted before the load, and a failed load reported rather than skipped.
    # Everything else in the tool passes over an unreadable config with one
    # line on stderr, so a pool that exists and cannot be read looks, from
    # every table, exactly like a pool that was never registered.
    pools=$(( pools + 1 ))
    if ! _rp_load_pool "${p}" 2>/dev/null; then
      _rp_doctor_fail "${p}: $(_rp_pool_conf "${p}") cannot be read, or is missing one of POOL_SCOPE, POOL_TARGET, POOL_COUNT and POOL_DIR — every other command skips this pool silently" \
                      "fix: repair the file, or delete it and register the pool again"
      continue
    fi
    running="$(_rp_running_in "${p}" "${POOL_COUNT}")"
    _rp_pool_paused "${p}" && _rp_doctor_note \
      "${p}: paused; it will not autoscale or start until 'runpool resume ${p}'"

    # A pool is meant to sit down, so 'not loaded' says nothing and is not
    # reported. A MISSING plist is different: _rp_up refuses on the first one
    # it cannot find, and that refusal is the first anybody hears of it.
    missing=0
    i=1
    while [ "${i}" -le "${POOL_COUNT}" ]; do
      [ -f "${RUNPOOL_AGENT_DIR}/$(_rp_label "${p}" "${i}").plist" ] || missing=$(( missing + 1 ))
      i=$(( i + 1 ))
    done
    [ "${missing}" -gt 0 ] && _rp_doctor_fail \
      "${p}: ${missing} of ${POOL_COUNT} launch agent(s) missing, so 'runpool up ${p}' will refuse" \
      "fix: runpool rewrite-agents"

    # An org pool with an empty watch list never autoscales. GitHub reports
    # queued runs per repository and not per organisation, so _rp_autoscale has
    # nothing to poll and the pool waits for a manual 'runpool up' forever —
    # while looking entirely healthy everywhere else, which is exactly the
    # failure this command exists for. Local, free, and no API call.
    [ "${POOL_SCOPE}" = "org" ] && [ -z "${POOL_WATCH:-}" ] && _rp_doctor_fail \
      "${p}: an org pool with no watched repositories never autoscales, because github reports queued runs per repository rather than per organisation" \
      "fix: give it --watch OWNER/REPO,... in ~/.config/runpool/pools and 'runpool apply'"

    # The same defect short of its limit: a watch list that is not empty and
    # is no longer complete. The empty case above is caught locally; this one
    # needs to know what the organisation holds, so it reports rather than
    # fails and it names what it found rather than guessing intent.
    #
    # **It does not decide which repositories should be watched.** A
    # repository at this scope may legitimately route every job to a managed
    # runner, and nothing readable here distinguishes that from one that
    # meant to reach the pool — the routing lives in a repository variable
    # whose name is a convention of whoever set it up, not of RunPool. So
    # the operator is told the difference and judges it.
    #
    # Reported here rather than polled at tick time on purpose. Waking on
    # any queued run in the organisation would also wake for a public
    # repository's, which the runner group refuses to serve, so the pool
    # would come up for work it can never take and idle straight back down.
    # Avoiding that needs the visibility of each repository, and re-deriving
    # the public-repository answer is the one thing AGENTS.md says not to do.
    if [ "${gh_ok}" = "1" ] && [ "${POOL_SCOPE}" = "org" ] && [ -n "${POOL_WATCH:-}" ]; then
      all_repos=$(gh api "/orgs/${POOL_TARGET}/repos?per_page=100" --paginate --jq '.[].full_name' 2>/dev/null)
      if [ -z "${all_repos}" ]; then
        _rp_doctor_note "${p}: could not list ${POOL_TARGET}'s repositories, so the watch list was not checked for staleness"
      else
        unwatched=$(_rp_unwatched_repos "${POOL_WATCH}" "${all_repos}")
        if [ -n "${unwatched}" ]; then
          _rp_doctor_note "${p}: watching $(echo "${POOL_WATCH}" | tr ',' '\n' | grep -c .) of $(printf '%s\n' "${all_repos}" | grep -c .) repositories at ${POOL_TARGET}. A job queued by an unwatched one waits until a watched one happens to wake the pool: $(printf '%s' "${unwatched}" | tr '\n' ' ')"
        else
          _rp_doctor_ok "${p}: every repository at ${POOL_TARGET} is watched"
        fi
      fi
    fi

    if [ "${gh_ok}" = "0" ]; then
      _rp_doctor_note "${p}: ${POOL_SCOPE} ${POOL_TARGET}, ${running}/${POOL_COUNT} running locally (github not checked)"
      continue
    fi
    gh="$(_rp_gh_runners)"; reg="${gh% *}"; online="${gh#* }"
    case "$(_rp_gh_state "${reg}" "${online}" "${running}" "${POOL_COUNT}")" in
      unreachable)
        _rp_doctor_note "${p}: github could not be reached, so only local state is known: ${running}/${POOL_COUNT} running" ;;
      unregistered)
        _rp_doctor_fail "${p}: github has no runners registered for ${POOL_TARGET}, so every job routed here queues forever" \
                        "fix: runpool reregister ${p}   (github prunes registrations after a long idle spell)" ;;
      offline)
        _rp_doctor_fail "${p}: ${running} runner(s) started locally and none has reached github" \
                        "fix: runpool reregister ${p}" ;;
      miscount)
        # A note and not a warning. _rp_gh_runners counts every runner at the
        # scope, and an organisation's scope covers other pools and other
        # machines, so a count above POOL_COUNT is entirely normal there.
        _rp_doctor_note "${p}: github has ${reg} runner(s) at ${POOL_SCOPE} ${POOL_TARGET}, the pool expects ${POOL_COUNT} (an org scope also counts other pools and other machines)" ;;
      *)
        _rp_doctor_ok "${p}: ${POOL_SCOPE} ${POOL_TARGET}, github has ${reg}, ${running}/${POOL_COUNT} running locally" ;;
    esac
  done
  [ "${pools}" = "0" ] && _rp_doctor_fail \
    "no pools are registered, so there is nothing to pick a job up" \
    "fix: runpool register <pool> --repo OWNER/REPO   (or --org ORG)"

  # --- disk ---------------------------------------------------------------
  # Against RUNPOOL_BASE and not '/'. The base can sit on a secondary or
  # external volume, and the only free space that matters is the one the
  # runners actually write into.
  echo ""
  echo "disk"
  avail_kb=$(df -k "${RUNPOOL_BASE}" 2>/dev/null | awk 'NR == 2 {print $4}')
  case "${avail_kb}" in
    ''|*[!0-9]*)
      _rp_doctor_note "could not read the free space on ${RUNPOOL_BASE}" ;;
    *)
      # Reported in MB below a gigabyte. Whole-GB division renders the most
      # alarming case in the range, a nearly full volume, as a flat '0GB'.
      if [ "${avail_kb}" -lt 1048576 ]; then
        free="$(( avail_kb / 1024 ))MB"
      else
        free="$(( avail_kb / 1048576 ))GB"
      fi
      # Persistent runners never clean up after themselves and the numbers are
      # large: a self-update strands roughly 580MB of superseded binaries per
      # runner and diagnostics reach roughly 150MB per runner, so a pool of
      # four turns over several GB between cleans. Pointed at `clean`, never
      # pruned here: see the read-only note above.
      if [ "${avail_kb}" -lt 5242880 ]; then
        _rp_doctor_fail "${free} free on ${RUNPOOL_BASE}: a job that fills the disk fails in ways that look like a defect in the code" \
                        "fix: runpool clean"
      elif [ "${avail_kb}" -lt 20971520 ]; then
        _rp_doctor_warn "${free} free on ${RUNPOOL_BASE}" \
                        "fix: runpool clean prunes work dirs, temp, diagnostics, superseded binaries and package stores"
      else
        _rp_doctor_ok "${free} free on ${RUNPOOL_BASE}"
      fi ;;
  esac
  cache_avail_kb=$(df -k "${RUNPOOL_CACHE_DIR}" 2>/dev/null | awk 'NR == 2 {print $4}')
  case "${cache_avail_kb}" in
    ''|*[!0-9]*) _rp_doctor_note "could not read the free space on ${RUNPOOL_CACHE_DIR}" ;;
    *)
      if [ "${cache_avail_kb}" -lt 1048576 ]; then
        free="$(( cache_avail_kb / 1024 ))MB"
      else
        free="$(( cache_avail_kb / 1048576 ))GB"
      fi
      _rp_doctor_ok "${free} free on cache root ${RUNPOOL_CACHE_DIR}" ;;
  esac

  # --- security -----------------------------------------------------------
  echo ""
  echo "security"
  # The config, and deliberately NOT the pools file. install.sh chmods the
  # config 600 because that is where a notifier's endpoint and token go, and
  # omits the chmod on the pools file on purpose: it holds no credentials,
  # which is the whole reason it is safe to copy between machines.
  #
  # Only a regular file is checked. RUNPOOL_CONFIG=/dev/null is the documented
  # way to isolate an invocation and is mode 666 by definition, so testing it
  # would fail every isolated run for no reason.
  if [ ! -e "${RUNPOOL_CONFIG}" ]; then
    _rp_doctor_note "no config at ${RUNPOOL_CONFIG}, so every setting is at its default"
  elif [ ! -f "${RUNPOOL_CONFIG}" ]; then
    _rp_doctor_note "${RUNPOOL_CONFIG} is not a regular file, so its permissions are not checked"
  else
    mode=$(stat -f '%Lp' "${RUNPOOL_CONFIG}" 2>/dev/null)
    case "${mode}" in
      ''|*[!0-7]*)
        _rp_doctor_note "could not read the mode of ${RUNPOOL_CONFIG}" ;;
      *)
        other=$(( 8#${mode} & 8#077 ))
        if [ "${other}" -ne 0 ]; then
          _rp_doctor_fail "${RUNPOOL_CONFIG} is mode ${mode}, so other users on this machine can read it, and it is where a notifier's endpoint and token live" \
                          "fix: chmod 600 ${RUNPOOL_CONFIG}"
        else
          _rp_doctor_ok "${RUNPOOL_CONFIG} is mode ${mode}, owner only"
        fi ;;
    esac
  fi

  # The organisation runner-group setting. `register` consults it once, when a
  # pool is created; it can be switched on the day after and nothing would ever
  # mention it again. Reported and never re-derived — enumerating an
  # organisation's public repositories to work out the same answer is
  # explicitly not RunPool's job. See SECURITY.md.
  if [ "${gh_ok}" = "1" ]; then
    for p in $(_rp_pool_names); do
      _rp_load_pool "${p}" || continue
      [ "${POOL_SCOPE}" = "org" ] || continue
      # Several pools can share one organisation; ask about each one once.
      case " ${seen_orgs} " in *" ${POOL_TARGET} "*) continue ;; esac
      seen_orgs="${seen_orgs} ${POOL_TARGET}"
      case "$(_rp_org_allows_public "${POOL_TARGET}")" in
        true)
          _rp_doctor_warn "${POOL_TARGET}: the default runner group has allows_public_repositories=true, so a public repository in that organisation can run on these runners" \
                          "fix: turn it off in the organisation's Actions runner-group settings, unless it is deliberate" ;;
        false)
          _rp_doctor_ok "${POOL_TARGET}: allows_public_repositories=false on the default runner group" ;;
        *)
          _rp_doctor_note "${POOL_TARGET}: could not read the runner groups (needs admin:org) — check allows_public_repositories in the organisation's Actions settings" ;;
      esac
    done
  fi

  echo ""
  if [ "${_rp_doctor_fails}" -gt 0 ]; then
    printf '%s problem(s) and %s warning(s). Nothing above was changed.\n' \
      "${_rp_doctor_fails}" "${_rp_doctor_warns}"
    return 1
  fi
  if [ "${_rp_doctor_warns}" -gt 0 ]; then
    printf 'No problems, %s warning(s). Nothing above was changed.\n' "${_rp_doctor_warns}"
    return 0
  fi
  echo "Everything checks out. Nothing above was changed."
  return 0
}

# Repositories at an org pool's scope that its watch list does not name.
#
# `_rp_autoscale` polls POOL_WATCH because GitHub reports queued runs per
# repository and not per organisation, so the list IS the wake mechanism. A
# repository missing from it queues work nothing wakes the pool for, and
# that failure is silent in every direction: a queued job is not a failed
# job, so no alert fires, and the pool reports healthy because it is.
#
# Pure, and separate from the check that reports it, so the rule can be
# exercised without reaching GitHub. $1 is the watch list as stored, $2 is
# the repository list newline-separated.
_rp_unwatched_repos() {
  local watch="$1" all="$2" r
  watch=",$(echo "${watch}" | tr -d ' '),"
  printf '%s\n' "${all}" | while IFS= read -r r; do
    [ -n "${r}" ] || continue
    case "${watch}" in
      *",${r},"*) ;;
      *) printf '%s\n' "${r}" ;;
    esac
  done
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
    _rp_pool_paused "${p}" && continue
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
  local only="${1:-}" p freed_kb=0 sz rd wd dd td i cache_dir pnpm_dir live keep vols nvols ntmp utmp
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
      i="${rd##*/runner-}"
      cache_dir="$(_rp_runner_cache_dir "${p}" "${i}")"

      # Job checkouts and build output.
      wd="$(_rp_runner_work_dir "${p}" "${i}")"
      if [ -d "${wd}" ]; then
        sz=$(du -sk "${wd}" 2>/dev/null | awk '{print $1}')
        find "${wd:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
        freed_kb=$(( freed_kb + ${sz:-0} ))
      fi

      # Per-runner temp. Safe to wipe wholesale: nothing but this runner's own
      # jobs ever writes here, which is the entire reason it is redirected.
      #
      # Both names are swept. TMPDIR moved from '.tmp' to 'tmp' because a dotted
      # component in the absolute path silently disables anything applying
      # dotfile-ignore rules to it. An install predating the rename still holds
      # the old directory, which would otherwise sit uncollected forever.
      if [ "${POOL_LEGACY_LAYOUT}" = "1" ]; then
        td="${rd}/.tmp"
      else
        td=""
      fi
      for td in "${cache_dir}/tmp" "${td}"; do
        if [ -d "${td}" ]; then
          sz=$(du -sk "${td}" 2>/dev/null | awk '{print $1}')
          find "${td:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
          freed_kb=$(( freed_kb + ${sz:-0} ))
        fi
      done
      # The legacy directory goes for good once emptied; the current one stays.
      if [ "${POOL_LEGACY_LAYOUT}" = "1" ]; then
        rmdir "${rd}/.tmp" 2>/dev/null
        mkdir -p "${rd}/tmp" 2>/dev/null
      else
        mkdir -p "${cache_dir}/tmp" 2>/dev/null
      fi

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
      if [ "${POOL_LEGACY_LAYOUT}" = "1" ]; then pnpm_dir="${rd}/.pnpm-store"; else pnpm_dir="${cache_dir}/pnpm"; fi
      if [ -d "${pnpm_dir}" ] && command -v pnpm >/dev/null 2>&1; then
        sz=$(du -sk "${pnpm_dir}" 2>/dev/null | awk '{print $1}')
        npm_config_store_dir="${pnpm_dir}" pnpm store prune >/dev/null 2>&1
        freed_kb=$(( freed_kb + sz - $(du -sk "${pnpm_dir}" 2>/dev/null | awk '{print $1}') ))
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

  # Foundation item-replacement directories in the per-user temp root.
  #
  # Opening a SwiftData store on a file URL makes Foundation create one of
  # these and never remove it: roughly six per run of a Swift test suite that
  # touches a file-backed container. They accumulate without bound, and macOS
  # reports that path as "System Data", so nothing an operator looks at shows
  # them growing. One reading passed ten thousand entries.
  #
  # Two things make this safe to sweep here and unsafe to sweep casually.
  # The path is shared with every process the user runs, unlike the per-runner
  # temp above, so only entries matching Foundation's own name are touched and
  # only ones untouched for days. These directories exist for the moment of an
  # atomic file replacement; one that has sat for three days was abandoned by
  # a process that is no longer running. Anything newer is left alone, which
  # also means a job running right now cannot be interfered with.
  #
  # Not restricted to runner activity on purpose: the same leak comes from
  # local development on this machine, and it is the same directory either way.
  ntmp=0
  utmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  if [ -n "${utmp}" ] && [ -d "${utmp}" ]; then
    sz=$(du -sk "${utmp}" 2>/dev/null | awk '{print $1}')
    while IFS= read -r td; do
      [ -d "${td}" ] || continue
      rm -rf "${td}" 2>/dev/null && ntmp=$(( ntmp + 1 ))
    done < <(find "${utmp%/}" -mindepth 1 -maxdepth 1 -type d \
               -name 'TemporaryDirectory.*' -mtime +2 2>/dev/null)
    if [ "${ntmp}" -gt 0 ]; then
      freed_kb=$(( freed_kb + sz - $(du -sk "${utmp}" 2>/dev/null | awk '{print $1}') ))
      _rp_log "clean: swept ${ntmp} abandoned Foundation temp dir(s)"
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

# A tick polls every watched repository of every pool that is down, one API
# call each, so a pool watching a dozen repos against a slow GitHub can still
# be working when launchd starts the next tick on its 60-second interval. Two
# ticks then interleave autoscale and sweep over the same activity timestamp.
#
# mkdir is the lock: it is atomic on every POSIX filesystem, and macOS has no
# flock. The stale break exists so a killed tick cannot wedge the scheduler
# permanently; 900s is far longer than any real tick and far shorter than the
# time anyone would take to notice.
RUNPOOL_TICK_LOCK="${RUNPOOL_STATE_DIR}/tick.lock"
RUNPOOL_TICK_STALE=900

_rp_tick() {
  local age
  if ! mkdir "${RUNPOOL_TICK_LOCK}" 2>/dev/null; then
    age=$(( $(_rp_now) - $(stat -f %m "${RUNPOOL_TICK_LOCK}" 2>/dev/null || echo 0) ))
    if [ "${age}" -lt "${RUNPOOL_TICK_STALE}" ]; then
      return 0   # a tick is already running; skipping is the whole point
    fi
    _rp_log "tick: breaking a stale lock (${age}s old)"
    rm -rf "${RUNPOOL_TICK_LOCK}"
    mkdir "${RUNPOOL_TICK_LOCK}" 2>/dev/null || return 0
  fi
  trap 'rm -rf "${RUNPOOL_TICK_LOCK}"' EXIT INT TERM
  _rp_autoscale; _rp_sweep; _rp_health_check; _rp_clean_if_overdue
  rm -rf "${RUNPOOL_TICK_LOCK}"
  trap - EXIT INT TERM
}

# ---------------------------------------------------------------------------
# pause / resume — global kill switch, default resumed
# ---------------------------------------------------------------------------
_rp_pause() {
  local name="${1:-}" busy
  if [ -z "${name}" ]; then
    : >| "${RUNPOOL_PAUSE_FLAG}"
    _rp_down_all --force
    _rp_log "Paused: all runners stopped; autoscaling disabled."
    return 0
  fi
  _rp_load_pool "${name}" || return 1
  _rp_pool_paused "${name}" && { _rp_log "Pool '${name}' is already paused."; return 0; }
  busy="$(_rp_busy_in "${POOL_DIR}")"
  if [ "${busy}" -gt 0 ]; then
    _rp_err "'${name}' has ${busy} job(s) running — refusing to pause. Wait for them to finish, then retry."
    return 1
  fi
  : >| "$(_rp_pool_pause_flag "${name}")"
  _rp_down "${name}" || { rm -f "$(_rp_pool_pause_flag "${name}")"; return 1; }
  _rp_log "Paused pool '${name}'. It will not start until resumed."
}

_rp_resume() {
  local name="${1:-}"
  if [ -z "${name}" ]; then
    rm -f "${RUNPOOL_PAUSE_FLAG}"
    _rp_log "Resumed: on-demand scaling enabled."
    return 0
  fi
  _rp_load_pool "${name}" || return 1
  _rp_pool_paused "${name}" || { _rp_log "Pool '${name}' is not paused."; return 0; }
  rm -f "$(_rp_pool_pause_flag "${name}")"
  _rp_log "Resumed pool '${name}'. It will wake when work is queued."
}

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
  _rp_log "scheduler installed: tick 60s (autoscale, idle-down, health), clean daily 04:00"
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
