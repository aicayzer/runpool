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

  local dir_base cache_base labels tarball i runner_dir cache_dir runner_name token
  dir_base="${RUNPOOL_RUNNER_DIR}/${name}"
  cache_base="${RUNPOOL_CACHE_DIR}/pools/${name}"
  labels="self-hosted,macOS,ARM64,${name}"
  tarball="$(_rp_fetch_runner_tarball)" || return 1
  mkdir -p "${dir_base}"

  i=1
  while [ "${i}" -le "${count}" ]; do
    runner_dir="${dir_base}/runner-${i}"
    cache_dir="${cache_base}/runner-${i}"
    if [ -f "${runner_dir}/.runner" ]; then
      _rp_log "${name} runner-${i}: already registered, skipping"
    else
      mkdir -p "${runner_dir}"
      mkdir -p "${cache_dir}/work" "${cache_dir}/pnpm" "${cache_dir}/npm" "${cache_dir}/tmp"
      [ -f "${runner_dir}/config.sh" ] || tar -xzf "${tarball}" -C "${runner_dir}" || return 1
      token="$(_rp_registration_token "${scope}" "${target}")" \
        || { _rp_err "${name} runner-${i}: no registration token — check 'gh auth status', that ${target} exists, and that you have admin on it"; return 1; }
      runner_name="$(hostname -s)-${name}-${i}"
      _rp_log "${name} runner-${i}: registering as '${runner_name}'"
      ( cd "${runner_dir}" && ./config.sh --unattended --replace \
          --url "https://github.com/${target}" --token "${token}" \
          --name "${runner_name}" --labels "${labels}" --work "${cache_dir}/work" \
          >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
    fi
    _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}" "${cache_dir}" 0
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
POOL_CACHE_DIR="${cache_base}"
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

# Arguments used to be read as $1 and $2 with anything further ignored in
# silence, which is how a mistyped flag became invisible. They are parsed
# properly now and anything unrecognised is refused.
_rp_set_count_usage() { echo "usage: runpool set-count <pool> <n> [--if-count <n>]"; }

_rp_set_count() {
  _rp_require gh || return 1
  local name="" want="" expect="" rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --if-count)
        [ $# -ge 2 ] || { _rp_err "--if-count needs a value ($(_rp_set_count_usage))"; return 1; }
        expect="$2"; shift 2 ;;
      --if-count=*)
        expect="${1#*=}"; shift ;;
      -*)
        _rp_err "unknown flag: $1 ($(_rp_set_count_usage))"; return 1 ;;
      *)
        if   [ -z "${name}" ]; then name="$1"
        elif [ -z "${want}" ]; then want="$1"
        else _rp_err "unexpected argument: $1 ($(_rp_set_count_usage))"; return 1
        fi
        shift ;;
    esac
  done

  [ -n "${name}" ] && [ -n "${want}" ] || { _rp_err "$(_rp_set_count_usage)"; return 1; }
  # Checked before the name reaches a lock path, which is built from it.
  _rp_valid_pool_name "${name}" || { _rp_err "invalid pool name: '${name}'"; return 1; }
  _rp_valid_count "${want}" || { _rp_err "count: $(_rp_count_rule), got '${want}'"; return 1; }
  if [ -n "${expect}" ]; then
    _rp_valid_count "${expect}" || { _rp_err "--if-count: $(_rp_count_rule), got '${expect}'"; return 1; }
  fi

  # Held across the whole resize, and released on every exit path by doing the
  # work in a separate function rather than with a trap. `apply` calls this in
  # a loop and installs traps of its own, which a trap set here would clobber.
  _rp_resize_lock "${name}" || return 1
  _rp_set_count_locked "${name}" "${want}" "${expect}"
  rc=$?
  _rp_resize_unlock "${name}"
  return ${rc}
}

_rp_set_count_locked() {
  local name="$1" want="$2" expect="$3"
  _rp_load_pool "${name}" || return 1

  local have="${POOL_COUNT}"

  # Compare-and-swap. `set-count` writes an absolute number, so a caller that
  # read the count, asked the user a question, and then wrote what it worked
  # out beforehand can turn a growth into a shrink and deregister runners
  # nobody agreed to. Refusing on a moved count is what makes that caller safe.
  #
  # Checked before the "already at that count" shortcut below, because a
  # premise that no longer holds is a failure whatever the target happens to
  # be: returning success for `set-count p 6 --if-count 4` on a pool that has
  # become 6 would tell the caller its stale view was right.
  if [ -n "${expect}" ] && [ "${expect}" != "${have}" ]; then
    _rp_err "'${name}' has ${have} runner(s), not ${expect} — refusing to resize. Something else changed it; re-read the count and retry."
    return 1
  fi

  if [ "${want}" = "${have}" ]; then _rp_log "pool '${name}': already ${have} runner(s)"; return 0; fi

  # Resizing either kills a live job or races a registration against one.
  local busy; busy="$(_rp_busy_in "${POOL_DIR}")"
  if [ "${busy}" -gt 0 ]; then
    _rp_err "'${name}' has ${busy} job(s) running — refusing to resize. Wait, then retry."
    return 1
  fi

  local was_up=0 orphaned=0 i runner_dir cache_dir label token runner_name tarball
  _rp_agent_loaded "$(_rp_label "${name}" 1)" && was_up=1

  if [ "${want}" -gt "${have}" ]; then
    tarball="$(_rp_fetch_runner_tarball)" || return 1
    i=$(( have + 1 ))
    while [ "${i}" -le "${want}" ]; do
      runner_dir="${POOL_DIR}/runner-${i}"
      cache_dir="$(_rp_runner_cache_dir "${name}" "${i}")"
      mkdir -p "${runner_dir}"
      _rp_prepare_runner_cache "${name}" "${i}"
      [ -f "${runner_dir}/config.sh" ] || tar -xzf "${tarball}" -C "${runner_dir}" || return 1
      if [ ! -f "${runner_dir}/.runner" ]; then
        token="$(_rp_registration_token "${POOL_SCOPE}" "${POOL_TARGET}")" \
          || { _rp_err "${name} runner-${i}: no registration token — check 'gh auth status', that ${POOL_TARGET} exists, and that you have admin on it"; return 1; }
        runner_name="$(hostname -s)-${name}-${i}"
        _rp_log "${name} runner-${i}: registering as '${runner_name}'"
        ( cd "${runner_dir}" && ./config.sh --unattended --replace \
            --url "https://github.com/${POOL_TARGET}" --token "${token}" \
            --name "${runner_name}" --labels "${POOL_LABELS}" --work "$(_rp_runner_work_dir "${name}" "${i}")" \
            >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
      fi
      _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}" "${cache_dir}" "${POOL_LEGACY_LAYOUT}"
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
      cache_dir="$(_rp_runner_cache_dir "${name}" "${i}")"
      label="$(_rp_label "${name}" "${i}")"
      _rp_agent_loaded "${label}" && launchctl unload "${RUNPOOL_AGENT_DIR}/${label}.plist" 2>/dev/null
      # Deregister before deleting. A runner removed locally but left
      # registered shows on GitHub as permanently offline and still gets
      # counted when a job looks for somewhere to run.
      #
      # Counted rather than fatal. Stopping here would leave the pool half
      # shrunk against a count already written, so the local cleanup finishes
      # and the command reports the failure at the end instead.
      _rp_deregister_runner "${runner_dir}" "${POOL_SCOPE}" "${POOL_TARGET}" || orphaned=$(( orphaned + 1 ))
      rm -f "${RUNPOOL_AGENT_DIR}/${label}.plist"
      rm -rf "${runner_dir}"
      [ "${POOL_LEGACY_LAYOUT}" = "1" ] || rm -rf "${cache_dir}"
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
  if [ "${was_up}" = "1" ] && ! _rp_pool_paused "${name}"; then
    _rp_load_pool "${name}" && _rp_up "${name}"
  fi

  # Reported last, and as a failure, because everything above succeeded and it
  # would otherwise read as a clean resize. A registration GitHub still holds
  # for a runner that no longer exists attracts jobs that then queue forever,
  # which is the failure this whole tool exists to avoid. The DELETE for each
  # one is in the log above, and `runpool doctor` keeps reporting the mismatch
  # until they are gone.
  if [ "${orphaned}" -gt 0 ]; then
    _rp_err "${orphaned} runner(s) are still registered on ${POOL_TARGET} — resize finished locally but GitHub was not updated."
    return 1
  fi
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
  _rp_down "${name}" || return 1

  local i runner_dir runner_name token
  i=1
  while [ "${i}" -le "${POOL_COUNT}" ]; do
    runner_dir="${POOL_DIR}/runner-${i}"
    [ -f "${runner_dir}/config.sh" ] || { _rp_err "${name} runner-${i}: no install at ${runner_dir}"; return 1; }
    token="$(_rp_registration_token "${POOL_SCOPE}" "${POOL_TARGET}")" \
      || { _rp_err "${name} runner-${i}: no registration token — check 'gh auth status', that ${POOL_TARGET} exists, and that you have admin on it"; return 1; }
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
        --name "${runner_name}" --labels "${POOL_LABELS}" --work "$(_rp_runner_work_dir "${name}" "${i}")" \
        >> "${RUNPOOL_LOG}" 2>&1 ) || return 1
    _rp_prepare_runner_cache "${name}" "${i}"
    _rp_write_plist "$(_rp_label "${name}" "${i}")" "${runner_dir}" \
                    "$(_rp_runner_cache_dir "${name}" "${i}")" "${POOL_LEGACY_LAYOUT}"
    i=$(( i + 1 ))
  done
  _rp_log "pool '${name}': ${POOL_COUNT} runner(s) re-registered (stopped)"
}

# ---------------------------------------------------------------------------
# migrate-storage — copy a legacy installation into macOS-native roots
# ---------------------------------------------------------------------------
# The migration copies first and leaves the old tree alone. A runner's
# registration credentials stay valid after its files and workFolder move, but
# a failed copy must never turn a recoverable layout change into a lost pool.
# --remove-legacy is deliberately a separate, explicit operation after the
# new tree has been checked.
_rp_migrate_pool_names() {
  find "$1/pools" -maxdepth 1 -name '*.conf' 2>/dev/null \
    | while read -r f; do basename "${f}" .conf; done
}

_rp_migrate_update_pool_conf() {
  local conf="$1" runner_dir="$2" cache_dir="$3" tmp
  tmp="${conf}.tmp"
  awk -v runner_dir="${runner_dir}" -v cache_dir="${cache_dir}" '
    /^POOL_DIR=/ { print "POOL_DIR=\"" runner_dir "\""; next }
    /^POOL_CACHE_DIR=/ { print "POOL_CACHE_DIR=\"" cache_dir "\""; cache_seen=1; next }
    { print }
    END { if (!cache_seen) print "POOL_CACHE_DIR=\"" cache_dir "\"" }
  ' "${conf}" >| "${tmp}" && mv -f "${tmp}" "${conf}"
}

_rp_migrate_update_config_base() {
  local source="$1" target="$2" tmp mode
  [ -f "${RUNPOOL_CONFIG}" ] || return 0
  grep -q '^RUNPOOL_BASE=' "${RUNPOOL_CONFIG}" || return 0
  tmp="${RUNPOOL_CONFIG}.tmp"
  mode=$(stat -f '%Lp' "${RUNPOOL_CONFIG}" 2>/dev/null) || return 1
  awk -v target="${target}" '
    /^RUNPOOL_BASE=/ { print "RUNPOOL_BASE=\"" target "\""; changed=1; next }
    { print }
  ' "${RUNPOOL_CONFIG}" >| "${tmp}" || return 1
  chmod "${mode}" "${tmp}" || return 1
  mv -f "${tmp}" "${RUNPOOL_CONFIG}" || return 1
  _rp_log "Updated RUNPOOL_BASE in ${RUNPOOL_CONFIG}: ${source} -> ${target}"
}

_rp_migrate_update_work_folder() {
  local runner_dir="$1" work_dir="$2" work_escaped tmp
  [ -f "${runner_dir}/.runner" ] || return 0
  grep -q '"workFolder"' "${runner_dir}/.runner" || {
    _rp_err "${runner_dir}/.runner has no workFolder setting"
    return 1
  }
  work_escaped=$(printf '%s' "${work_dir}" | sed 's/[\\&|]/\\&/g')
  tmp="${runner_dir}/.runner.tmp"
  sed -E "s|(\"workFolder\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"|\\1\"${work_escaped}\"|" \
    "${runner_dir}/.runner" >| "${tmp}" && mv -f "${tmp}" "${runner_dir}/.runner"
}

_rp_migrate_move_cache_dir() {
  local from="$1" to="$2"
  [ -d "${from}" ] || return 0
  [ ! -e "${to}" ] || { _rp_err "migration target already has ${to}"; return 1; }
  mkdir -p "$(dirname "${to}")" || return 1
  mv "${from}" "${to}"
}

_rp_migrate_rewrite_runner_links() {
  local runner_dir="$1" name link target target_name
  for name in bin externals; do
    link="${runner_dir}/${name}"
    [ -L "${link}" ] || continue
    target=$(readlink "${link}") || return 1
    target_name="${target##*/}"
    [ -n "${target_name}" ] && [ -d "${runner_dir}/${target_name}" ] || {
      _rp_err "migration copied an unresolved runner link: ${link} -> ${target}"
      return 1
    }
    # GitHub's runner updater creates absolute links to its versioned bin and
    # externals directories. Make the copied installation self-contained so
    # removing the legacy tree cannot break Runner.Listener afterwards.
    ln -sfn "${target_name}" "${link}" || return 1
  done
}

_rp_migrate_storage() {
  local dry=0 remove_legacy=0 source="" target="" active_base="${RUNPOOL_BASE}" arg p conf old_dir new_dir cache_pool i runner_dir cache_dir busy=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --remove-legacy) remove_legacy=1; shift ;;
      --from|--to)
        [ $# -ge 2 ] || { _rp_err "$1 needs a path"; return 1; }
        if [ "$1" = "--from" ]; then source="$2"; else target="$2"; fi
        shift 2
        ;;
      *) _rp_err "unknown flag: $1 (usage: runpool migrate-storage [--dry-run] [--from PATH] [--to PATH] [--remove-legacy])"; return 1 ;;
    esac
  done

  if [ -z "${source}" ]; then
    if [ "${RUNPOOL_BASE}" != "${RUNPOOL_DEFAULT_BASE}" ] && [ -d "${RUNPOOL_BASE}/pools" ]; then
      source="${RUNPOOL_BASE}"
    elif [ -d "${RUNPOOL_LEGACY_BASE}" ]; then
      source="${RUNPOOL_LEGACY_BASE}"
    else
      _rp_err "no legacy installation was found (expected ${RUNPOOL_LEGACY_BASE})"
      return 1
    fi
  fi
  if [ -z "${target}" ]; then
    if [ "${source}" = "${RUNPOOL_BASE}" ] && [ "${source}" != "${RUNPOOL_DEFAULT_BASE}" ]; then
      target="${RUNPOOL_DEFAULT_BASE}"
    else
      target="${RUNPOOL_BASE}"
    fi
  fi
  [ -d "${source}" ] || { _rp_err "legacy installation not found: ${source}"; return 1; }
  [ "${source}" != "${target}" ] || { _rp_err "migration source and target are both ${source}"; return 1; }

  if [ "${remove_legacy}" = "1" ]; then
    find "${target}/pools" -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q . || {
      _rp_err "no migrated pool definitions at ${target}"
      return 1
    }
    [ "${dry}" = "1" ] && { echo "Would remove legacy installation: ${source}"; return 0; }
    rm -rf "${source}"
    _rp_log "Removed legacy installation: ${source}"
    return 0
  fi

  [ -d "${source}/pools" ] || { _rp_err "${source} has no pool definitions"; return 1; }
  if find "${target}/pools" -maxdepth 1 -name '*.conf' 2>/dev/null | grep -q .; then
    _rp_err "migration target already has pool definitions: ${target}"
    return 1
  fi

  for p in $(_rp_migrate_pool_names "${source}"); do
    conf="${source}/pools/${p}.conf"
    POOL_COUNT=""; POOL_DIR=""
    # shellcheck disable=SC1090
    . "${conf}" || { _rp_err "could not read ${conf}"; return 1; }
    [ -n "${POOL_DIR}" ] && [ -n "${POOL_COUNT}" ] || { _rp_err "${conf} is incomplete"; return 1; }
    busy=$(( busy + $(_rp_busy_in "${POOL_DIR}") ))
  done
  if [ "${busy}" -gt 0 ]; then
    _rp_err "${busy} job(s) are running — refusing to migrate. Wait for them to finish, then retry."
    return 1
  fi

  echo "Storage migration"
  echo "  From: ${source}"
  echo "  To:   ${target}"
  echo "  Cache: ${RUNPOOL_CACHE_DIR}"
  for p in $(_rp_migrate_pool_names "${source}"); do echo "  Pool: ${p}"; done
  if [ "${dry}" = "1" ]; then
    echo "  Dry run: no files or launch agents were changed."
    return 0
  fi

  # A listener with no job is still a live runner process. Work is already
  # known idle above, so unloading these agents is safe and prevents the old
  # tree from continuing to serve jobs after the copied agents are rewritten.
  for p in $(_rp_migrate_pool_names "${source}"); do
    conf="${source}/pools/${p}.conf"
    POOL_COUNT=""
    # shellcheck disable=SC1090
    . "${conf}" || return 1
    i=1
    while [ "${i}" -le "${POOL_COUNT}" ]; do
      launchctl unload "${source}/agents/$(_rp_label "${p}" "${i}").plist" 2>/dev/null || true
      i=$(( i + 1 ))
    done
  done

  mkdir -p "${target}/pools" "${target}/runners" "${target}/agents" "${target}/state" \
           "${target}/state/pools" "${target}/telemetry" \
           "${RUNPOOL_CACHE_DIR}/downloads" || return 1
  for p in $(_rp_migrate_pool_names "${source}"); do
    conf="${source}/pools/${p}.conf"
    POOL_COUNT=""; POOL_DIR=""
    # shellcheck disable=SC1090
    . "${conf}" || return 1
    old_dir="${POOL_DIR}"
    new_dir="${target}/runners/${p}"
    cache_pool="${RUNPOOL_CACHE_DIR}/pools/${p}"
    [ ! -e "${new_dir}" ] || { _rp_err "migration target already has ${new_dir}"; return 1; }
    cp -R "${old_dir}" "${new_dir}" || return 1
    cp "${conf}" "${target}/pools/${p}.conf" || return 1
    i=1
    while [ "${i}" -le "${POOL_COUNT}" ]; do
      runner_dir="${new_dir}/runner-${i}"
      cache_dir="${cache_pool}/runner-${i}"
      _rp_migrate_rewrite_runner_links "${runner_dir}" || return 1
      mkdir -p "${cache_dir}" || return 1
      # A work tree is regenerable but not necessarily portable. Compilers can
      # bake its absolute path into build artifacts, and a remote cache can
      # later restore those artifacts after this local copy is gone. Start the
      # migrated runner cold instead of presenting moved output as valid.
      if [ -d "${runner_dir}/_work" ]; then
        rm -rf "${runner_dir}/_work" || return 1
      fi
      _rp_migrate_move_cache_dir "${runner_dir}/.pnpm-store" "${cache_dir}/pnpm" || return 1
      _rp_migrate_move_cache_dir "${runner_dir}/.npm-cache" "${cache_dir}/npm" || return 1
      # Job temp belongs to the old workspace in the same way. Nothing in it
      # is durable runner state, so carrying it across creates risk for no gain.
      rm -rf "${runner_dir}/tmp" "${runner_dir}/.tmp" || return 1
      mkdir -p "${cache_dir}/work" "${cache_dir}/pnpm" "${cache_dir}/npm" "${cache_dir}/tmp" || return 1
      _rp_migrate_update_work_folder "${runner_dir}" "${cache_dir}/work" || return 1
      i=$(( i + 1 ))
    done
    _rp_migrate_update_pool_conf "${target}/pools/${p}.conf" "${new_dir}" "${cache_pool}" || return 1
  done
  for arg in agents state telemetry; do
    if [ -d "${source}/${arg}" ]; then
      cp -R "${source}/${arg}/." "${target}/${arg}/" || return 1
    fi
  done
  if [ -d "${source}/.cache" ]; then
    cp -R "${source}/.cache/." "${RUNPOOL_CACHE_DIR}/downloads/" || return 1
  fi
  if [ "${active_base}" = "${source}" ] && [ "${target}" != "${source}" ]; then
    _rp_migrate_update_config_base "${source}" "${target}" || return 1
  fi

  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_BASE="${target}"
  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_POOL_DIR="${RUNPOOL_BASE}/pools"
  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_RUNNER_DIR="${RUNPOOL_BASE}/runners"
  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_AGENT_DIR="${RUNPOOL_BASE}/agents"
  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_STATE_DIR="${RUNPOOL_BASE}/state"
  # shellcheck disable=SC2034  # read by lib/common.sh helpers below
  RUNPOOL_POOL_PAUSE_DIR="${RUNPOOL_STATE_DIR}/pools"
  _rp_rewrite_plists || return 1
  _rp_log "Migrated storage to ${target}. Legacy data remains at ${source}."
  _rp_log "Verify with: runpool status --local && runpool doctor"
  _rp_log "After verification, remove it with: runpool migrate-storage --from ${source} --to ${target} --remove-legacy"
}

# ---------------------------------------------------------------------------
# up / down
# ---------------------------------------------------------------------------
_rp_up() {
  _rp_load_pool "$1" || return 1
  if _rp_paused; then _rp_err "runpool is paused — run 'runpool resume' first"; return 1; fi
  if _rp_pool_paused "$1"; then _rp_err "pool '$1' is paused — run 'runpool resume $1' first"; return 1; fi
  local i label plist loaded=0
  [ -z "${RUNPOOL_JOB_HOOK:-}" ] || _rp_write_hook_wrappers || return 1
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

_rp_up_all()   { local p; for p in $(_rp_pool_names); do _rp_pool_paused "${p}" || _rp_up "${p}"; done; }
_rp_down_all() { local p; for p in $(_rp_pool_names); do _rp_down "${p}" "${1:-}"; done; }

# ---------------------------------------------------------------------------
# remove — deregister and delete a pool entirely
# ---------------------------------------------------------------------------
_rp_remove() {
  _rp_load_pool "$1" || return 1
  _rp_down "$1"
  local i runner_dir label orphaned=0
  # Iterate the directories that exist rather than 1..POOL_COUNT. A pool whose
  # count was lowered by hand still has higher-numbered runners on disk and
  # registered with GitHub, and counting to POOL_COUNT would leave them behind
  # as permanently-offline registrations.
  for runner_dir in "${POOL_DIR}"/runner-*/; do
    [ -d "${runner_dir}" ] || continue
    runner_dir="${runner_dir%/}"
    i="${runner_dir##*/runner-}"
    label="$(_rp_label "$1" "${i}")"
    _rp_deregister_runner "${runner_dir}" "${POOL_SCOPE}" "${POOL_TARGET}" || orphaned=$(( orphaned + 1 ))
    rm -f "${RUNPOOL_AGENT_DIR}/${label}.plist"
    rm -rf "${runner_dir}"
  done
  # Only remove a directory strictly beneath the base, never the base itself.
  if [ "${POOL_DIR}" != "${RUNPOOL_BASE}" ]; then
    case "${POOL_DIR}" in "${RUNPOOL_BASE}/"*) rm -rf "${POOL_DIR}" ;; esac
  fi
  [ "${POOL_LEGACY_LAYOUT}" = "1" ] || rm -rf "${POOL_CACHE_DIR}"
  rm -f "$(_rp_pool_pause_flag "$1")"
  rm -f "$(_rp_pool_conf "$1")"
  _rp_log "pool '$1' removed"

  # Worse here than for a shrink, and worth saying so. After a shrink the pool
  # still exists and `status` and `doctor` go on reporting the mismatch; after
  # a remove there is no pool left to report it, so this message and the DELETE
  # commands above it are the only record that anything is outstanding.
  if [ "${orphaned}" -gt 0 ]; then
    _rp_err "${orphaned} runner(s) are still registered on ${POOL_TARGET}. The pool is gone locally, so nothing will report this again — run the DELETE commands above, or remove them from GitHub's runner settings."
    return 1
  fi
  return 0
}
