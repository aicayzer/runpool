# shellcheck shell=bash
# apply.sh — reconcile the machine's pools to a file describing them.
#
# `register` creates one pool from one command, so a machine's setup exists
# nowhere except as a sequence somebody ran once. That is fine for one machine
# and stops being fine at two: the second is a recall exercise rather than a
# copy, and nothing states what a machine is *meant* to have, so a count
# changed by hand is indistinguishable from one that was always meant to be
# that.
#
# Reconciliation runs in one direction only. A pool in the file and not on the
# machine is created; a count or watch list that differs is changed; a pool on
# the machine and not in the file is reported and left alone. Deleting a pool
# deregisters its runners with GitHub, and a missing line is far too quiet a
# way to ask for that, so `remove` stays explicit.
#
# `register` stays too. One pool from one command is still the right way to add
# one pool; this is the alternative for describing a whole machine.

# ---------------------------------------------------------------------------
# The file format
# ---------------------------------------------------------------------------
# One pool per line, written exactly as its `register` arguments minus the word
# `register`, so there is one vocabulary to learn rather than two:
#
#   acme    --org acme-inc --count 4 --watch acme-inc/api,acme-inc/web
#   side    --repo me/side-project --count 1
#
# Blank lines and '#' comments are ignored, and a trailing '\' continues onto
# the next line, which is what keeps a long --watch list readable.
#
# Parsed by hand rather than sourced. The config file is sourced because it
# assigns shell variables and there is no other sensible way to read it; this
# file is meant to be copied between machines and read by whoever inherits it,
# and a file that is also a shell script is a worse thing to copy. Hand parsing
# is also what lets a bad line name itself by number instead of failing
# somewhere further on.

# Emit one record per declared pool, fields separated by '|':
#
#   name|scope|target|count|watch|allow_public
#
# '|' and not a tab: tab is IFS whitespace, so a run of them collapses and an
# empty field in the middle of a record silently disappears when `read` splits
# it back out. 'watch' is empty for most pools, which is exactly that case.
# Every field is validated below to characters that cannot include '|'.
#
# The body is a subshell so that 'set -f' cannot leak into the caller. Word
# splitting is the tokeniser here, and without noglob an unquoted '*' in the
# file would expand to whatever happens to be in the current directory.
_rp_parse_pools_file() (
  set -f
  local file="$1" line acc="" lineno=0 declared=" " count_declared=0 \
        name scope target count watch allow tok val

  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$(( lineno + 1 ))

    # Continuation is handled before comment stripping, so that a '#' later on
    # the joined line still comments out the rest of it.
    case "${line}" in
      *\\) acc="${acc}${line%\\} "; continue ;;
    esac
    line="${acc}${line}"; acc=""

    line="${line%%#*}"

    # Collapse ', ' to ',' so a watch list can be written the way anyone would
    # naturally write one. Word splitting is the tokeniser, so without this
    # '--watch a/b, c/d' tokenises as three fields and the third is rejected as
    # unknown. Each pass replaces the first occurrence; commas appear in no
    # other field, so nothing else is affected.
    while :; do
      case "${line}" in
        *,\ *) line="${line%%, *},${line#*, }" ;;
        *) break ;;
      esac
    done

    # shellcheck disable=SC2086  # deliberate: this is the tokeniser, noglob is on
    set -- ${line}
    [ $# -gt 0 ] || continue

    name="$1"; shift
    _rp_valid_pool_name "${name}" || {
      _rp_err "${file}:${lineno}: invalid pool name '${name}'"
      _rp_err "Letters, digits, dot, underscore and hyphen only."
      return 1
    }
    case "${declared}" in
      *" ${name} "*) _rp_err "${file}:${lineno}: pool '${name}' is declared more than once"; return 1 ;;
    esac
    declared="${declared}${name} "

    scope=""; target=""; count="2"; watch=""; allow="0"
    while [ $# -gt 0 ]; do
      tok="$1"
      case "${tok}" in
        --org|--repo|--count|--watch)
          # Checked before shifting two. 'shift 2' with one argument left is a
          # failure that does not shift, which turns this into an infinite loop
          # rather than an error.
          [ $# -ge 2 ] || { _rp_err "${file}:${lineno}: ${tok} needs a value"; return 1; }
          val="$2"; shift 2
          case "${tok}" in
            --org|--repo)
              [ -z "${scope}" ] || {
                _rp_err "${file}:${lineno}: give exactly one of --org or --repo"; return 1; }
              case "${tok}" in --org) scope="org" ;; *) scope="repo" ;; esac
              target="${val}"
              ;;
            --count) count="${val}" ;;
            --watch) watch="${watch},${val}" ;;
          esac
          ;;
        --allow-public) allow="1"; shift ;;
        *) _rp_err "${file}:${lineno}: unknown field '${tok}'"; return 1 ;;
      esac
    done

    [ -n "${scope}" ] || {
      _rp_err "${file}:${lineno}: '${name}' needs --org ORG or --repo OWNER/REPO"; return 1; }

    if [ "${scope}" = "org" ]; then
      _rp_valid_gh_name "${target}" || {
        _rp_err "${file}:${lineno}: '${target}' is not an organisation name"; return 1; }
    else
      _rp_valid_gh_repo "${target}" || {
        _rp_err "${file}:${lineno}: '${target}' is not OWNER/REPO"; return 1; }
    fi

    case "${count}" in
      ''|*[!0-9]*) _rp_err "${file}:${lineno}: count must be a positive integer, got '${count}'"; return 1 ;;
    esac
    [ "${count}" -ge 1 ] || { _rp_err "${file}:${lineno}: count must be at least 1"; return 1; }

    watch="${watch#,}"
    if [ -n "${watch}" ]; then
      # A repo pool polls its own target and _rp_autoscale never looks at
      # POOL_WATCH for one, so a watch list here would do nothing at all.
      # Refused rather than ignored: silently doing nothing is how a pool ends
      # up never waking and nobody knowing why.
      [ "${scope}" = "org" ] || {
        _rp_err "${file}:${lineno}: --watch applies to org pools only — a repo pool polls ${target} itself"
        return 1
      }
      for tok in $(echo "${watch}" | tr ',' ' '); do
        _rp_valid_gh_repo "${tok}" || {
          _rp_err "${file}:${lineno}: watched repository '${tok}' is not OWNER/REPO"; return 1; }
      done
    fi

    printf '%s|%s|%s|%s|%s|%s\n' "${name}" "${scope}" "${target}" "${count}" "${watch}" "${allow}"
    count_declared=$(( count_declared + 1 ))
  done < "${file}"

  [ -z "${acc}" ] || { _rp_err "${file}: ends with a trailing '\\' and nothing to continue onto"; return 1; }
  [ "${count_declared}" -gt 0 ] || _rp_err "${file}: declares no pools"
  return 0
)

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
# One line per pool, in the same columns as `runpool pools`, prefixed by what
# would happen to it.
_rp_plan_line() { printf "  %s %-12s %-4s %-24s %s\n" "$1" "$2" "$3" "$4" "$5"; }

_rp_apply() {
  # Every local declared once, at the top.
  local dry=0 file="${RUNPOOL_POOLS_FILE}" records rc=0 seen=" " \
        name scope target count watch allow \
        have_count have_watch what p \
        n_create=0 n_change=0 n_same=0 n_conflict=0 n_absent=0 n_failed=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --file)
        [ $# -ge 2 ] || { _rp_err "--file needs a path"; return 1; }
        file="$2"; shift 2 ;;
      *) _rp_err "unknown flag: $1 (usage: runpool apply [--dry-run] [--file PATH])"; return 1 ;;
    esac
  done

  [ -f "${file}" ] || {
    _rp_err "no pools file at ${file}"
    _rp_err "Write one (runpool.pools.example is a commented template), or pass --file PATH."
    return 1
  }

  # Parsed in full before anything is touched, so a typo on the last line
  # cannot leave the machine half reconciled.
  records="$(_rp_parse_pools_file "${file}")" || return 1

  echo "plan from ${file}"
  [ "${dry}" = "1" ] || echo "  (not a dry run — changes are being made)"
  echo

  # Records arrive on fd 3 rather than stdin. `register` shells out to the
  # runner's config.sh and to gh, and anything in the loop body that read stdin
  # would eat the rest of the plan.
  while IFS='|' read -r name scope target count watch allow <&3; do
    # A file that declares no pools is a valid state, not an error — but an
    # empty record set still feeds one empty line through the printf below,
    # and that reads back as a pool with no name and plans a create for it.
    [ -n "${name}" ] || continue
    seen="${seen}${name} "

    if [ ! -f "$(_rp_pool_conf "${name}")" ]; then
      n_create=$(( n_create + 1 ))
      what="create with ${count} runner(s)"
      [ -n "${watch}" ] && what="${what}, watching ${watch}"
      [ "${allow}" = "1" ] && what="${what} [--allow-public]"
      _rp_plan_line "+" "${name}" "${scope}" "${target}" "${what}"
      [ "${dry}" = "1" ] && continue

      if [ "${allow}" = "1" ]; then
        _rp_register "${name}" "--${scope}" "${target}" --count "${count}" --allow-public
      else
        _rp_register "${name}" "--${scope}" "${target}" --count "${count}"
      fi || { n_failed=$(( n_failed + 1 )); rc=1; continue; }
      # register writes the pool's conf from scratch and takes no --watch, so
      # the watch list is appended to it here. See issue #19.
      if [ -n "${watch}" ]; then
        _rp_write_pool_watch "${name}" "${watch}" || { n_failed=$(( n_failed + 1 )); rc=1; }
      fi
      continue
    fi

    _rp_load_pool "${name}" || { n_failed=$(( n_failed + 1 )); rc=1; continue; }

    # Scope and target are what the runners are registered against. Changing
    # either means deregistering every runner and registering it again
    # somewhere else, which is `remove` followed by `apply`, not something a
    # reconcile should do behind the operator's back.
    if [ "${scope}" != "${POOL_SCOPE}" ] || [ "${target}" != "${POOL_TARGET}" ]; then
      n_conflict=$(( n_conflict + 1 )); rc=1
      _rp_plan_line "!" "${name}" "${POOL_SCOPE}" "${POOL_TARGET}" \
        "registered here, but the file says ${scope} ${target} — 'runpool remove ${name}' first"
      continue
    fi

    have_count="${POOL_COUNT}"
    # Normalised the same way both sides, so a hand-edited conf with spaces
    # after its commas does not read as drift.
    have_watch="$(echo "${POOL_WATCH:-}" | tr -d ' ')"

    what=""
    [ "${count}" != "${have_count}" ] && what="count ${have_count} -> ${count}"
    if [ "${watch}" != "${have_watch}" ]; then
      [ -n "${what}" ] && what="${what}; "
      what="${what}watch ${have_watch:-(none)} -> ${watch:-(none)}"
    fi

    if [ -z "${what}" ]; then
      n_same=$(( n_same + 1 ))
      _rp_plan_line "=" "${name}" "${scope}" "${target}" "up to date (${count} runner(s))"
      continue
    fi

    n_change=$(( n_change + 1 ))
    _rp_plan_line "~" "${name}" "${scope}" "${target}" "${what}"
    [ "${dry}" = "1" ] && continue

    if [ "${watch}" != "${have_watch}" ]; then
      _rp_write_pool_watch "${name}" "${watch}" || { n_failed=$(( n_failed + 1 )); rc=1; }
    fi
    if [ "${count}" != "${have_count}" ]; then
      # Refuses while a job is in flight, and says so. One pool failing that
      # way must not abandon the rest of the plan.
      _rp_set_count "${name}" "${count}" || { n_failed=$(( n_failed + 1 )); rc=1; }
    fi
  done 3< <(printf '%s\n' "${records}")

  # Pools the machine has and the file does not. Reported, never removed.
  for p in $(_rp_pool_names); do
    case "${seen}" in *" ${p} "*) continue ;; esac
    n_absent=$(( n_absent + 1 ))
    _rp_load_pool "${p}" || continue
    _rp_plan_line "?" "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" \
      "not in the file — left alone ('runpool remove ${p}' to delete it)"
  done

  echo
  echo "  ${n_create} to create, ${n_change} to change, ${n_same} unchanged, ${n_absent} not in the file"
  [ "${n_conflict}" -gt 0 ] && echo "  ${n_conflict} conflict(s): scope or target differs — see the '!' lines above"
  [ "${n_failed}" -gt 0 ] && echo "  ${n_failed} failed — see the messages above"
  if [ "${dry}" = "1" ]; then
    echo "  dry run: nothing was changed"
    # A repository's visibility is checked by `register`, which a dry run never
    # reaches. Saying so here is cheaper than a plan that promises a create
    # GitHub will refuse.
    [ "${n_create}" -gt 0 ] && echo "  a '+' line is checked for public visibility only when it is actually registered"
  fi
  return "${rc}"
}
