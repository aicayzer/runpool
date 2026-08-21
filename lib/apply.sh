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
# A '#' comments out the line it is on and nothing else, including when that
# line ends in '\'. See the comment on the stripping below: the other reading
# is what let a commented-out example silently rewrite the pool after it.
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
  local file="$1" line acc="" acc_line=0 lineno=0 declared=" " count_declared=0 \
        name scope target count watch allow clean rest tok val

  while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$(( lineno + 1 ))

    # Comments are stripped per PHYSICAL line, before the trailing '\' is
    # looked at. The other order — continue first, strip the joined line —
    # reads a commented line ending in '\' as a continuation, and the '#'
    # then eats whatever it was joined to. The shipped template taught exactly
    # that: two commented lines, the first ending in '\'. Uncommenting only
    # the first produced a pool with NO watch list, which is precisely the
    # never-autoscales state this whole feature exists to prevent; uncommenting
    # only the second produced "declares no pools" and exit 0. Both silent,
    # both a different pool from the one the file appears to declare.
    #
    # Stripping first costs nothing that was worth having: a trailing comment
    # still works on any physical line, including the last of a continuation.
    # All that is lost is a '#' on one line commenting out the next, which is
    # not what '#' means anywhere else.
    line="${line%%#*}"

    case "${line}" in
      *\\)
        [ -n "${acc}" ] || acc_line="${lineno}"
        acc="${acc}${line%\\} "
        continue ;;
    esac

    # A continuation has to land on a line that still says something. It used
    # to be allowed to land on a blank or a comment, quietly ending the pool
    # early and dropping every flag the author clearly meant to be part of it.
    if [ -n "${acc}" ]; then
      rest="${line// /}"; rest="${rest//$'\t'/}"
      [ -n "${rest}" ] || {
        _rp_err "${file}:${lineno}: nothing here to continue the pool started on line ${acc_line}"
        _rp_err "A trailing '\\' continues onto the next line; a blank line or a comment cannot be that line."
        return 1
      }
    fi
    line="${acc}${line}"; acc=""

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
    # A line starting with a flag is almost always a continuation line whose
    # opening line is commented out, and 'invalid pool name' is a poor way to
    # say so. '--watch' passes _rp_valid_pool_name on its characters.
    case "${name}" in
      -*) _rp_err "${file}:${lineno}: expected a pool name, got '${name}'"
          _rp_err "A flag can only continue a line ending in '\\'. Is the line above it commented out?"
          return 1 ;;
    esac
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
        --allow-public) allow="1"; shift ;;        *) _rp_err "${file}:${lineno}: unknown field '${tok}'"; return 1 ;;
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

    # Shared with `register` rather than repeated, so the pools file and the
    # command line cannot disagree about what a count is. This used to test
    # only for non-digits, which let '007' through to POOL_COUNT and out again
    # as invalid JSON, and let an over-long number through to a raw
    # 'integer expression expected' from `[ -ge ]`.
    _rp_valid_count "${count}" || {
      _rp_err "${file}:${lineno}: count: $(_rp_count_rule), got '${count}'"; return 1; }

    # --allow-public is refused at org scope for the same reason --watch is
    # refused at repo scope, one paragraph down: it does nothing there, and a
    # flag that silently does nothing is how a file ends up saying something
    # the machine never agreed to. `register` consults it only under repo
    # scope, because at org scope the control is GitHub's
    # allows_public_repositories on the runner group. See SECURITY.md.
    if [ "${allow}" = "1" ] && [ "${scope}" = "org" ]; then
      _rp_err "${file}:${lineno}: --allow-public applies to repo pools only"
      _rp_err "At organisation scope the equivalent is GitHub's own allows_public_repositories on the runner group."
      return 1
    fi

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
      # Rebuilt from the entries that were actually validated, not stored as
      # written. Splitting on commas drops empty entries before the check, so
      # ',acme-inc/api' and 'a/b,,c/d' passed validation and were then written
      # to POOL_WATCH verbatim — approving one string and storing another.
      clean=""
      for tok in $(echo "${watch}" | tr ',' ' '); do
        _rp_valid_gh_repo "${tok}" || {
          _rp_err "${file}:${lineno}: watched repository '${tok}' is not OWNER/REPO"; return 1; }
        clean="${clean},${tok}"
      done
      watch="${clean#,}"
    fi

    printf '%s|%s|%s|%s|%s|%s\n' "${name}" "${scope}" "${target}" "${count}" "${watch}" "${allow}"
    count_declared=$(( count_declared + 1 ))
  done < "${file}" || { _rp_err "${file}: could not be read"; return 1; }

  [ -z "${acc}" ] || { _rp_err "${file}:${acc_line}: ends with a trailing '\\' and nothing to continue onto"; return 1; }
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
  local dry=0 file="${RUNPOOL_POOLS_FILE}" records actions="" rc=0 seen=" " \
        name scope target count watch allow verb chg_count chg_watch \
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

  # Present, then not a directory, then readable — three messages rather than
  # one, because the three are fixed differently.
  #
  # '-e' and '-r' rather than '-f'. A '-f' test refuses /dev/null, which is the
  # isolation idiom AGENTS.md recommends for RUNPOOL_CONFIG and which ought to
  # mean the same thing here: a file that declares no pools.
  #
  # The readability test is the one that matters. The redirect feeding the
  # parser was unchecked, so a pools file the user could not read parsed as
  # zero pools and returned 0 — and every pool actually on the machine was then
  # reported as '? not in the file', which is the exact inverse of the truth.
  if [ ! -e "${file}" ]; then
    _rp_err "no pools file at ${file}"
    _rp_err "Write one (runpool.pools.example is a commented template), or pass --file PATH."
    return 1
  fi
  [ ! -d "${file}" ] || { _rp_err "${file} is a directory, not a pools file"; return 1; }
  [ -r "${file}" ]   || { _rp_err "cannot read ${file} — check its permissions"; return 1; }

  # Parsed in full before anything is touched, so a typo on the last line
  # cannot leave the machine half reconciled.
  records="$(_rp_parse_pools_file "${file}")" || return 1

  echo "plan from ${file}"
  [ "${dry}" = "1" ] || echo "  (not a dry run — changes are being made)"
  echo

  # ---- pass one: decide everything and print the whole plan ----------------
  #
  # Deciding and acting used to happen together, so each plan line printed
  # immediately before its own action and `register`'s output landed in the
  # middle of the plan. A plan interleaved with the consequences of its own
  # first half is not a plan, and it is not what the README shows either.
  # Nothing here touches the machine; the actions are collected and run below.
  #
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
      actions="${actions}create|${name}|${scope}|${target}|${count}|${watch}|${allow}|0|0
"
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

    # --allow-public is deliberately not compared. It is not pool state and is
    # not recorded anywhere: it is permission to perform a create, consulted
    # once by `register` and meaningless afterwards. Adding or removing it on a
    # pool that already exists changes nothing, so '=' is the truthful answer.
    chg_count=0; chg_watch=0
    what=""
    [ "${count}" != "${have_count}" ] && { chg_count=1; what="count ${have_count} -> ${count}"; }
    if [ "${watch}" != "${have_watch}" ]; then
      chg_watch=1
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
    actions="${actions}change|${name}|${scope}|${target}|${count}|${watch}|0|${chg_count}|${chg_watch}
"
  done 3< <(printf '%s\n' "${records}")

  # Pools the machine has and the file does not. Reported, never removed.
  for p in $(_rp_pool_names); do
    case "${seen}" in *" ${p} "*) continue ;; esac
    # Counted only once the config is known to have loaded. Counting first made
    # the summary say '2 not in the file' above a single '?' line.
    _rp_load_pool "${p}" || { n_failed=$(( n_failed + 1 )); rc=1; continue; }
    n_absent=$(( n_absent + 1 ))
    _rp_plan_line "?" "${p}" "${POOL_SCOPE}" "${POOL_TARGET}" \
      "not in the file — left alone ('runpool remove ${p}' to delete it)"
  done

  # ---- pass two: act on it ------------------------------------------------
  if [ "${dry}" != "1" ] && [ -n "${actions}" ]; then
    echo
    echo "  applying:"
    while IFS='|' read -r verb name scope target count watch allow chg_count chg_watch <&3; do
      [ -n "${verb}" ] || continue
      case "${verb}" in
        create)
          # Built as an argument list rather than interpolated, so a watch list
          # reaches `register` as one word whatever it contains.
          set -- "${name}" "--${scope}" "${target}" --count "${count}"
          # register writes POOL_WATCH itself, inside the same file write as
          # the rest of the pool (#19). It used to be appended here afterwards,
          # which left a window in which a create could succeed and the watch
          # list never arrive.
          [ -n "${watch}" ] && set -- "$@" --watch "${watch}"
          [ "${allow}" = "1" ] && set -- "$@" --allow-public
          _rp_register "$@" || { n_failed=$(( n_failed + 1 )); rc=1; }
          ;;
        change)
          if [ "${chg_watch}" = "1" ]; then
            _rp_write_pool_watch "${name}" "${watch}" || { n_failed=$(( n_failed + 1 )); rc=1; }
          fi
          if [ "${chg_count}" = "1" ]; then
            # Refuses while a job is in flight, and says so. One pool failing
            # that way must not abandon the rest of the plan.
            _rp_set_count "${name}" "${count}" || { n_failed=$(( n_failed + 1 )); rc=1; }
          fi
          ;;
      esac
    done 3< <(printf '%s' "${actions}")
  fi

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
