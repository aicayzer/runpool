# shellcheck shell=bash
# lifecycle.sh — creating, resizing, starting, stopping and destroying pools.
#
# A pool is a set of runners bound to one GitHub scope. GitHub offers
# repository, organisation and enterprise scopes and no user-account scope, so
# an organisation shares one pool across all its repos while a personal
# repository needs its own. That constraint is why a pool is the unit here.

# ---------------------------------------------------------------------------
# register — create and configure a new pool (left stopped)
# ---------------------------------------------------------------------------
_rp_register() {
  _rp_require gh   || return 1
  _rp_require curl || return 1
  _rp_require tar  || return 1

  local name="${1:-}"; [ $# -gt 0 ] && shift
  [ -n "${name}" ] || { _rp_err "usage: runpool register <pool> --repo OWNER/REPO|--org ORG [--count N] [--watch OWNER/REPO,...] [--allow-public]"; return 1; }
  _rp_valid_pool_name "${name}" || {
    _rp_err "invalid pool name: '${name}'"
    _rp_err "Letters, digits, dot, underscore and hyphen only: the name becomes a directory, a launch-agent label and a JSON field."
    return 1
  }

  local scope="" target="" count="2" watch="" clean="" tok allow_public=0 vis=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--org|--count|--watch)
        # Checked before shifting two, the same way lib/apply.sh checks it.
        # Without this 'runpool register zz --org' died on a raw '$2: unbound
        # variable' with an internal line number and no usage message.
        [ $# -ge 2 ] || { _rp_err "$1 needs a value"; return 1; }
        case "$1" in
          --repo)  scope="repo"; target="$2" ;;
          --org)   scope="org";  target="$2" ;;
          --count) count="$2" ;;
          # Repeated --watch accumulates, matching the pools file: one
          # vocabulary means the same flag given twice means the same thing
          # in both places.
          --watch) watch="${watch},$2" ;;
        esac
        shift 2
        ;;
      --allow-public) allow_public=1; shift ;;
      *) _rp_err "unknown flag: $1"; return 1 ;;
    esac
  done
  [ -n "${scope}" ] && [ -n "${target}" ] || { _rp_err "one of --repo OWNER/REPO or --org ORG is required"; return 1; }

  # The same validators lib/apply.sh runs over the pools file. They lived in
  # lib/common.sh with only that one caller, so a target given on the command
  # line reached the config file unchecked and 'runpool register x --org a"b'
  # wrote POOL_TARGET="a"b" — a config that then fails to source at all, taking
  # the pool with it.
  if [ "${scope}" = "org" ]; then
    _rp_valid_gh_name "${target}" || { _rp_err "'${target}' is not an organisation name"; return 1; }
  else
    _rp_valid_gh_repo "${target}" || { _rp_err "'${target}' is not OWNER/REPO"; return 1; }
  fi
  _rp_valid_count "${count}" || { _rp_err "--count: $(_rp_count_rule), got '${count}'"; return 1; }

  # Spaces are dropped so that --watch "a/b, c/d" reads as the pools file
  # writes it. Entries are rebuilt from what was validated rather than kept as
  # typed, so ',a/b' cannot be checked as one entry and stored as two.
  watch="${watch#,}"; watch="${watch// /}"
  if [ -n "${watch}" ]; then
    # A repo pool polls its own target and _rp_autoscale never reads POOL_WATCH
    # for one. Refused rather than ignored: silently doing nothing is how a
    # pool ends up never waking and nobody knowing why.
    [ "${scope}" = "org" ] || {
      _rp_err "--watch applies to org pools only — a repo pool polls ${target} itself"
      return 1
    }
    for tok in $(echo "${watch}" | tr ',' ' '); do
      _rp_valid_gh_repo "${tok}" || { _rp_err "watched repository '${tok}' is not OWNER/REPO"; return 1; }
      clean="${clean},${tok}"
    done
    watch="${clean#,}"
  fi

  # Whose job the public-repository check is depends on the scope, and the two
  # cases are genuinely different.
  #
  # At REPOSITORY scope it is RunPool's, because GitHub has no per-repository
  # equivalent of the runner group's allows_public_repositories. A pull request
  # from an untrusted fork runs its own workflow file, so wiring a public repo
  # to a self-hosted runner hands any stranger a shell on this machine.
  #
  # Refused by default rather than absolutely. A refusal with no way past it
  # invites a forked copy of the tool or a hand-registered runner, and neither
  # is visible here afterwards; an explicit flag keeps the decision in the open.
  if [ "${scope}" = "repo" ]; then
    vis=$(gh repo view "${target}" --json visibility --jq '.visibility' 2>/dev/null)
    case "${vis}" in
      PRIVATE|INTERNAL) ;;
      PUBLIC)
        if [ "${allow_public}" = "1" ]; then
          _rp_log "WARNING: ${target} is PUBLIC and --allow-public was given. Any fork's pull request can run its own workflow file here, as your user. Require approval for fork pull requests on that repository."
        else
          _rp_err "${target} is PUBLIC — refusing to register self-hosted runners on a public repo."
          _rp_err "A pull request from any fork would run its own workflow file here, as your user."
          _rp_err "If that is genuinely what you want: runpool register ${name} --repo ${target} --allow-public"
          return 1
        fi
        ;;
      *)
        # Fails closed. An empty answer means the API call failed, not that the
        # repository is private, and treating those the same skipped the check
        # exactly when GitHub was being unreliable.
        _rp_err "could not determine the visibility of ${target} — refusing."
        _rp_err "Check 'gh auth status' and that the repository exists, then retry."
        return 1
        ;;
    esac
  else
    # At ORGANISATION scope it is GitHub's, and GitHub already defaults it
    # safely. A runner group carries allows_public_repositories, it is false by
    # default, and runners registered here land in the default group because
    # config.sh is never passed --runnergroup. So report GitHub's setting;
    # do not enumerate the org's public repositories and re-derive the answer.
    #
    # A warning rather than a refusal, and no failing closed, precisely because
    # this is not RunPool's control to enforce.
    #
    # The read itself lives in lib/common.sh, because `doctor` reports the same
    # setting and this one is consulted only at create: it can be switched on
    # the day after and nothing here would ever mention it again.
    case "$(_rp_org_allows_public "${target}")" in
      true)
        _rp_log "WARNING: the default runner group on ${target} has allows_public_repositories=true, so public repositories in that organisation can use these runners. Turn it off in the organisation's Actions runner-group settings unless that is deliberate."
        ;;
      false) ;;
      *)
        _rp_log "note: could not read the runner groups for ${target} (needs admin:org). Whether public repositories there can use these runners is GitHub's allows_public_repositories setting, in the organisation's Actions settings."
        ;;
    esac
  fi

  local dir_base labels tarball i runner_dir runner_name token
  dir_base="${RUNPOOL_BASE}/${name}"
  labels="self-hosted,macOS,ARM64,${name}"
  tarball="$(_rp_fetch_runner_tarball)" || return 1
  mkdir -p "${dir_base}"

  i=1
  while [ "${i}" -le "${count}" ]; do
    runner_dir="${dir_base}/runner-${i}"
    if [ -f "${runner_dir}/.runner" ]; then
      _rp_log "${name} runner-${i}: already registered, skipping"
    else
      mkdir -p "${runner_dir}"
      [ -f "${runner_dir}/config.sh" ] || tar -xzf "${tarball}" -C "${runner_dir}" || return 1
      token=$(gh api -X POST "$(_rp_scope_path "${scope}" "${target}")/actions/runners/registration-token" \
                --jq '.token' 2>/dev/null)
      [ -n "${token}" ] || { _rp_err "${name} runner-${i}: no registration token (need admin on ${target})"; return 1; }
      runner_name="$(hostname -s)-${name}-${i}"
      _rp_log "${name} runner-${i}: registering as '${runner_name}'"
      ( cd "${runner_dir}" && ./config.sh --unattended --replace \
          --url "https://github.com/${target}" --token "${token}" \
          --name "${runner_name}" --labels "${labels}" --work "_work" \
          >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
    fi
    _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}"
    i=$(( i + 1 ))
  done

  # POOL_WATCH is written here, in the same file write as everything else,
  # rather than added afterwards by whoever called this. An org pool with no
  # watch list never autoscales, so a create that succeeds and a write that
  # follows it leaves a window where a crash produces a pool that works, looks
  # healthy, and silently never wakes — with nothing recording why. One write,
  # no window. Repo pools get no line at all: they poll their own target.
  {
    cat <<CONF
POOL_NAME="${name}"
POOL_SCOPE="${scope}"
POOL_TARGET="${target}"
POOL_COUNT="${count}"
POOL_DIR="${dir_base}"
POOL_LABELS="${labels}"
CONF
    if [ -n "${watch}" ]; then printf 'POOL_WATCH="%s"\n' "${watch}"; fi
  } >| "$(_rp_pool_conf "${name}")"
  _rp_log "pool '${name}' registered: ${count} runner(s) on ${scope} ${target} (stopped)"
  _rp_log "it will come up on its own when a job queues, or now with: runpool up ${name}"
}

# ---------------------------------------------------------------------------
# set-count — change a pool's runner count after registration
#
# GitHub has no concept of a pool. config.sh configures exactly one runner and
# takes no count, so a pool of N is N separate installations and changing N
# means creating or destroying whole runners. Hiding that is why this exists.
# ---------------------------------------------------------------------------
# POOL_COUNT is written in two places and in a different order depending on
# whether the pool is growing or shrinking, so it lives in one function.
_rp_write_pool_count() {
  local conf; conf="$(_rp_pool_conf "$1")"
  sed "s/^POOL_COUNT=.*/POOL_COUNT=\"$2\"/" "${conf}" >| "${conf}.tmp" \
    && mv -f "${conf}.tmp" "${conf}"
}

# The watched repositories an org pool autoscales on. Only `apply`'s change
# path uses this: a create writes POOL_WATCH inside register's own heredoc, so
# a pool never exists without the watch list it was asked for.
#
# Rebuilt whole and moved into place, exactly like _rp_write_pool_count, and
# for a sharper reason than symmetry. This used to append when the line was
# absent, and against a config whose last line had no newline the append landed
# on the end of POOL_LABELS:
#
#   POOL_LABELS="self-hosted,macOS,ARM64,acme"POOL_WATCH="acme-inc/api"
#
# which corrupts POOL_LABELS permanently and leaves POOL_WATCH empty. POOL_LABELS
# is what `set-count` and `reregister` hand to config.sh, so the runners come
# back registered under a label set no workflow's runs-on matches, and the pool
# looks healthy the whole time.
#
# awk rather than cat or sed: awk terminates every record with ORS, which is
# what supplies the newline a file was missing. The value needs no quoting —
# _rp_valid_gh_repo has already rejected anything but GitHub identifiers and
# commas.
_rp_write_pool_watch() {
  local conf; conf="$(_rp_pool_conf "$1")"
  awk -v v="$2" '
    /^POOL_WATCH=/ { print "POOL_WATCH=\"" v "\""; seen = 1; next }
                   { print }
    END            { if (!seen) print "POOL_WATCH=\"" v "\"" }
  ' "${conf}" >| "${conf}.tmp" && mv -f "${conf}.tmp" "${conf}"
}

_rp_set_count() {
  _rp_require gh || return 1
  local name="$1" want="$2"
  [ -n "${name}" ] && [ -n "${want}" ] || { _rp_err "usage: runpool set-count <pool> <n>"; return 1; }
  _rp_valid_count "${want}" || { _rp_err "count: $(_rp_count_rule), got '${want}'"; return 1; }
  _rp_load_pool "${name}" || return 1

  local have="${POOL_COUNT}"
  if [ "${want}" = "${have}" ]; then _rp_log "pool '${name}': already ${have} runner(s)"; return 0; fi

  # Resizing either kills a live job or races a registration against one.
  local busy; busy="$(_rp_busy_in "${POOL_DIR}")"
  if [ "${busy}" -gt 0 ]; then
    _rp_err "'${name}' has ${busy} job(s) running — refusing to resize. Wait, then retry."
    return 1
  fi

  local was_up=0 i runner_dir label token runner_name tarball
  _rp_agent_loaded "$(_rp_label "${name}" 1)" && was_up=1

  if [ "${want}" -gt "${have}" ]; then
    tarball="$(_rp_fetch_runner_tarball)" || return 1
    i=$(( have + 1 ))
    while [ "${i}" -le "${want}" ]; do
      runner_dir="${POOL_DIR}/runner-${i}"
      mkdir -p "${runner_dir}"
      [ -f "${runner_dir}/config.sh" ] || tar -xzf "${tarball}" -C "${runner_dir}" || return 1
      if [ ! -f "${runner_dir}/.runner" ]; then
        token=$(gh api -X POST "$(_rp_scope_path "${POOL_SCOPE}" "${POOL_TARGET}")/actions/runners/registration-token" \
                  --jq '.token' 2>/dev/null)
        [ -n "${token}" ] || { _rp_err "${name} runner-${i}: no registration token"; return 1; }
        runner_name="$(hostname -s)-${name}-${i}"
        _rp_log "${name} runner-${i}: registering as '${runner_name}'"
        ( cd "${runner_dir}" && ./config.sh --unattended --replace \
            --url "https://github.com/${POOL_TARGET}" --token "${token}" \
            --name "${runner_name}" --labels "${POOL_LABELS}" --work "_work" \
            >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
      fi
      _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}"
      i=$(( i + 1 ))
    done
  else
    # Write the smaller count before deleting anything.
    #
    # A scheduler tick landing mid-shrink otherwise reads a POOL_COUNT that no
    # longer matches the agents on disk, so bringing the pool up fails on a
    # plist that has just been removed. That failure returns before the
    # activity timestamp is touched, and the sweep in the same tick then stands
    # every pool down on stale idle data — including one autoscale was trying
    # to start for queued work. Shrinking first makes any tick in the window
    # see the smaller pool, which is entirely valid.
    _rp_write_pool_count "${name}" "${want}"
    i=$(( want + 1 ))
    while [ "${i}" -le "${have}" ]; do
      runner_dir="${POOL_DIR}/runner-${i}"
      label="$(_rp_label "${name}" "${i}")"
      _rp_agent_loaded "${label}" && launchctl unload "${RUNPOOL_AGENT_DIR}/${label}.plist" 2>/dev/null
      # Deregister before deleting. A runner removed locally but left
      # registered shows on GitHub as permanently offline and still gets
      # counted when a job looks for somewhere to run.
      _rp_deregister_runner "${runner_dir}" "${POOL_SCOPE}" "${POOL_TARGET}"
      rm -f "${RUNPOOL_AGENT_DIR}/${label}.plist"
      rm -rf "${runner_dir}"
      _rp_log "${name} runner-${i}: removed"
      i=$(( i + 1 ))
    done
  fi

  # Growing writes the count last, which is safe in that direction: a tick
  # landing mid-grow sees the old smaller count and starts a subset of agents
  # that all exist. Shrinking has already written it above, and doing so again
  # here is a harmless no-op that keeps one exit path for both.
  _rp_write_pool_count "${name}" "${want}"
  _rp_log "pool '${name}': ${have} -> ${want} runner(s)"
  [ "${was_up}" = "1" ] && { _rp_load_pool "${name}" && _rp_up "${name}"; }
  return 0
}

# ---------------------------------------------------------------------------
# reregister — recreate GitHub registrations, keeping the local install
#
# GitHub deletes the registration of a runner that has not connected for a
# while. The local install is untouched by that and still looks healthy: it
# starts, connects, then fails to create a session. Nothing in any repository
# needs changing, because routing lives in the workflow; only GitHub's record
# has to be recreated.
# ---------------------------------------------------------------------------
_rp_reregister() {
  _rp_require gh || return 1
  local name="$1"
  [ -n "${name}" ] || { _rp_err "usage: runpool reregister <pool>"; return 1; }
  _rp_load_pool "${name}" || return 1
  _rp_down "${name}" >/dev/null 2>&1

  local i runner_dir runner_name token
  i=1
  while [ "${i}" -le "${POOL_COUNT}" ]; do
    runner_dir="${POOL_DIR}/runner-${i}"
    [ -f "${runner_dir}/config.sh" ] || { _rp_err "${name} runner-${i}: no install at ${runner_dir}"; return 1; }
    token=$(gh api -X POST "$(_rp_scope_path "${POOL_SCOPE}" "${POOL_TARGET}")/actions/runners/registration-token" \
              --jq '.token' 2>/dev/null)
    [ -n "${token}" ] || { _rp_err "${name} runner-${i}: no registration token (need admin on ${POOL_TARGET})"; return 1; }
    runner_name="$(hostname -s)-${name}-${i}"
    # config.sh refuses to reconfigure over an existing registration, and
    # --replace only covers a name collision on the server side. Note that
    # .runner_migrated counts as "configured" exactly as .runner does, so
    # leaving it behind fails the reconfigure with a misleading "already
    # configured" — remove the whole set, not the obvious one.
    rm -f "${runner_dir}/.runner" "${runner_dir}/.credentials" \
          "${runner_dir}/.credentials_rsaparams" "${runner_dir}/.runner_migrated" \
          "${runner_dir}/.service"
    _rp_log "${name} runner-${i}: re-registering as '${runner_name}'"
    ( cd "${runner_dir}" && ./config.sh --unattended --replace \
        --url "https://github.com/${POOL_TARGET}" --token "${token}" \
        --name "${runner_name}" --labels "${POOL_LABELS}" --work "_work" \
        >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
    _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}"
    i=$(( i + 1 ))
  done
  _rp_log "pool '${name}': ${POOL_COUNT} runner(s) re-registered (stopped)"
}

# ---------------------------------------------------------------------------
# up / down
# ---------------------------------------------------------------------------
_rp_up() {
  _rp_load_pool "$1" || return 1
  if _rp_paused; then _rp_err "runpool is paused — run 'runpool resume' first"; return 1; fi
  local i label plist loaded=0
  i=1
  while [ "${i}" -le "${POOL_COUNT}" ]; do
    label="$(_rp_label "$1" "${i}")"
    plist="${RUNPOOL_AGENT_DIR}/${label}.plist"
    [ -f "${plist}" ] || { _rp_err "missing agent: ${plist}"; return 1; }
    if _rp_agent_loaded "${label}"; then
      loaded=$(( loaded + 1 ))
    else
      launchctl load "${plist}" 2>/dev/null && loaded=$(( loaded + 1 ))
    fi
    i=$(( i + 1 ))
  done
  _rp_touch_activity
  _rp_log "Started pool '$1' (${loaded} of ${POOL_COUNT} runners online)."
}

# Refuses while a job is in flight unless --force. Unloading a launch agent
# kills Runner.Worker mid-job and the job fails on GitHub seconds later with
# nothing to explain why. Six live jobs were once lost this way. 'sweep' never
# hits the guard because it only runs when nothing is busy; 'pause' forces
# deliberately.
_rp_down() {
  _rp_load_pool "$1" || return 1
  local force=0 busy i label plist
  [ "${2:-}" = "--force" ] && force=1
  busy="$(_rp_busy_in "${POOL_DIR}")"
  if [ "${busy}" -gt 0 ] && [ "${force}" = "0" ]; then
    _rp_err "'$1' has ${busy} job(s) running — refusing to stand down (they would fail). Wait, or: runpool down $1 --force"
    return 1
  fi
  i=1
  while [ "${i}" -le "${POOL_COUNT}" ]; do
    label="$(_rp_label "$1" "${i}")"
    plist="${RUNPOOL_AGENT_DIR}/${label}.plist"
    _rp_agent_loaded "${label}" && launchctl unload "${plist}" 2>/dev/null
    i=$(( i + 1 ))
  done
  _rp_log "Stopped pool '$1'. Runners remain registered."
}

_rp_up_all()   { local p; for p in $(_rp_pool_names); do _rp_up "${p}"; done; }
_rp_down_all() { local p; for p in $(_rp_pool_names); do _rp_down "${p}" "${1:-}"; done; }

# ---------------------------------------------------------------------------
# remove — deregister and delete a pool entirely
# ---------------------------------------------------------------------------
_rp_remove() {
  _rp_load_pool "$1" || return 1
  _rp_down "$1"
  local i runner_dir label
  # Iterate the directories that exist rather than 1..POOL_COUNT. A pool whose
  # count was lowered by hand still has higher-numbered runners on disk and
  # registered with GitHub, and counting to POOL_COUNT would leave them behind
  # as permanently-offline registrations.
  for runner_dir in "${POOL_DIR}"/runner-*/; do
    [ -d "${runner_dir}" ] || continue
    runner_dir="${runner_dir%/}"
    i="${runner_dir##*/runner-}"
    label="$(_rp_label "$1" "${i}")"
    _rp_deregister_runner "${runner_dir}" "${POOL_SCOPE}" "${POOL_TARGET}"
    rm -f "${RUNPOOL_AGENT_DIR}/${label}.plist"
    rm -rf "${runner_dir}"
  done
  # Only remove a directory strictly beneath the base, never the base itself.
  if [ "${POOL_DIR}" != "${RUNPOOL_BASE}" ]; then
    case "${POOL_DIR}" in "${RUNPOOL_BASE}/"*) rm -rf "${POOL_DIR}" ;; esac
  fi
  rm -f "$(_rp_pool_conf "$1")"
  _rp_log "pool '$1' removed"
}
