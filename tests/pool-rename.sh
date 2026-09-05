#!/bin/bash
# Renaming a pool: what moves, what is re-registered, and what it refuses.
#
# The name is a config filename, two directories, the launch-agent labels and
# their logs, three state files, a lock, each runner's registered name, and one
# of the labels those runners carry. Getting one of them wrong is silent, which
# is what this is for.
#
# Offline: gh and each runner's config.sh are stubbed, and both log their
# arguments so the GitHub-facing contract can be asserted without a network.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
bin_dir="${scratch_dir}/bin"
gh_log="${scratch_dir}/gh.log"
cfg_log="${scratch_dir}/config.log"
trap 'rm -rf "${scratch_dir}"' EXIT INT TERM

export RUNPOOL_BASE="${scratch_dir}/base"
export RUNPOOL_STATE_DIR="${scratch_dir}/base/state"
export RUNPOOL_CACHE_DIR="${scratch_dir}/cache"
export RUNPOOL_CONFIG="${scratch_dir}/runpool.conf"
export RUNPOOL_POOLS_FILE="${scratch_dir}/pools"
export RUNPOOL_LOG_DIR="${scratch_dir}/logs"
export RUNPOOL_LOG="${scratch_dir}/logs/runpool.log"
# Derived from RUNPOOL_BASE inside common.sh rather than taken from the
# environment, so this has to agree with it or the assertions below look at an
# empty directory while the tool writes somewhere else.
export RUNPOOL_AGENT_DIR="${scratch_dir}/base/agents"
mkdir -p "${RUNPOOL_BASE}/pools" "${RUNPOOL_STATE_DIR}/pools" "${RUNPOOL_CACHE_DIR}" \
         "${RUNPOOL_LOG_DIR}" "${RUNPOOL_AGENT_DIR}" "${bin_dir}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$(( pass + 1 )); }
present() { [ -e "$1" ] || fail "$2: expected $1 to exist"; ok; }
absent()  { [ ! -e "$1" ] || fail "$2: expected $1 to be gone"; ok; }
holds()   { grep -q -- "$2" "$1" || fail "$3: '$2' not in $1"; ok; }
lacks()   { grep -q -- "$2" "$1" && fail "$3: '$2' should not be in $1"; ok; }

# gh: a registration token for the POST, success for the DELETE, and a record
# of every call. The DELETE is what proves the old registrations are removed
# rather than left behind, which --replace cannot do when the name changes.
cat >"${bin_dir}/gh" <<STUB
#!/bin/bash
echo "\$*" >> "${gh_log}"
case "\$*" in
  *registration-token*) echo "TOKEN123" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${bin_dir}/gh"
export PATH="${bin_dir}:${PATH}"

# ---------------------------------------------------------------------------
# a pool to rename
# ---------------------------------------------------------------------------
build_pool() {
  local name="$1" count="$2" legacy="${3:-0}" i dir cache
  rm -rf "${RUNPOOL_BASE}/runners" "${RUNPOOL_CACHE_DIR}/pools" "${RUNPOOL_AGENT_DIR:?}"/*
  rm -f "${RUNPOOL_BASE}/pools"/*.conf "${RUNPOOL_STATE_DIR}/pools"/*
  : >"${gh_log}"; : >"${cfg_log}"
  dir="${RUNPOOL_BASE}/runners/${name}"
  cache="${RUNPOOL_CACHE_DIR}/pools/${name}"
  {
    echo "POOL_NAME=\"${name}\""
    echo "POOL_SCOPE=\"org\""
    echo "POOL_TARGET=\"acme-inc\""
    echo "POOL_COUNT=\"${count}\""
    echo "POOL_DIR=\"${dir}\""
    [ "${legacy}" = "1" ] || echo "POOL_CACHE_DIR=\"${cache}\""
    echo "POOL_LABELS=\"self-hosted,macOS,ARM64,${name},xcode\""
    echo "POOL_WATCH=\"acme-inc/api,acme-inc/web\""
  } >"${RUNPOOL_BASE}/pools/${name}.conf"

  i=1
  while [ "${i}" -le "${count}" ]; do
    mkdir -p "${dir}/runner-${i}" "${cache}/runner-${i}/work"
    printf '{"agentId": %s0, "workFolder": "%s/runner-%s/work"}\n' "${i}" "${cache}" "${i}" \
      >"${dir}/runner-${i}/.runner"
    # A config.sh that behaves like the real one: refuses nothing, writes a
    # .runner, and records exactly what it was asked for.
    # Faithful to the real one in the way that matters here: it runs
    # ./bin/Runner.Listener, so a dangling bin link makes it fail before it
    # registers anything. A stub that ignored the links would pass whether or
    # not they were rewritten, and prove nothing.
    cat >"${dir}/runner-${i}/config.sh" <<STUB
#!/bin/bash
[ -x ./bin/Runner.Listener ] || { echo "./config.sh: line 80: ./bin/Runner.Listener: No such file or directory" >&2; exit 1; }
echo "\$*" >> "${cfg_log}"
printf '{"agentId": 99, "workFolder": "x"}\n' > .runner
STUB
    chmod +x "${dir}/runner-${i}/config.sh"
    # GitHub's runner updater points bin and externals at versioned directories
    # with ABSOLUTE links. A directory that moves therefore takes two dangling
    # links with it, and config.sh dies on a missing Runner.Listener before it
    # can register anything. The fixture has to carry them or the rename looks
    # like it works.
    mkdir -p "${dir}/runner-${i}/bin.2.337.0" "${dir}/runner-${i}/externals.2.337.0"
    printf '#!/bin/bash\n' >"${dir}/runner-${i}/bin.2.337.0/Runner.Listener"
    chmod +x "${dir}/runner-${i}/bin.2.337.0/Runner.Listener"
    ln -sfn "${dir}/runner-${i}/bin.2.337.0" "${dir}/runner-${i}/bin"
    ln -sfn "${dir}/runner-${i}/externals.2.337.0" "${dir}/runner-${i}/externals"
    printf 'plist for %s runner-%s\n' "${name}" "${i}" \
      >"${RUNPOOL_AGENT_DIR}/runpool.${name}.${i}.plist"
    i=$(( i + 1 ))
  done
  : >"${RUNPOOL_STATE_DIR}/pools/${name}.paused"
  : >"${RUNPOOL_STATE_DIR}/pools/${name}.started"
}

# launchd and process inspection are the two things a test cannot have, and
# neither is what is under test here.
probe() {
  (
    # shellcheck source=/dev/null
    . "${repo_dir}/lib/common.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "${repo_dir}/lib/lifecycle.sh"
    # shellcheck source=/dev/null
    . "${repo_dir}/lib/scheduler.sh"
    _rp_agent_loaded() { return 1; }
    _rp_down() { return 0; }
    _rp_busy_in() { echo "${BUSY:-0}"; }
    _rp_up() { return 0; }
    eval "${EXTRA:-:}"
    _rp_rename "$@"
  )
}

# ---------------------------------------------------------------------------
# the rename itself
# ---------------------------------------------------------------------------
build_pool alpha 2
probe alpha bravo >"${scratch_dir}/out" 2>&1 || fail "rename failed: $(cat "${scratch_dir}/out")"

conf="${RUNPOOL_BASE}/pools/bravo.conf"
present "${conf}" "the new config"
absent  "${RUNPOOL_BASE}/pools/alpha.conf" "the old config"
holds   "${conf}" 'POOL_NAME="bravo"'   "the config names the new pool"
holds   "${conf}" "runners/bravo"       "POOL_DIR moved"
holds   "${conf}" "pools/bravo"         "POOL_CACHE_DIR moved"
holds   "${conf}" 'POOL_COUNT="2"'      "the count survives"
holds   "${conf}" "acme-inc/api"        "the watch list survives"
# The whole point of deriving extras rather than storing them.
holds   "${conf}" 'POOL_LABELS="self-hosted,macOS,ARM64,bravo,xcode"' "the extra label survives the rename"

present "${RUNPOOL_BASE}/runners/bravo/runner-1" "the runner tree moved"
absent  "${RUNPOOL_BASE}/runners/alpha"          "the old runner tree"
present "${RUNPOOL_CACHE_DIR}/pools/bravo"       "the cache moved"
absent  "${RUNPOOL_CACHE_DIR}/pools/alpha"       "the old cache"

# The links have to be relative afterwards, and they have to resolve. An
# absolute link left pointing into the old path is a runner that cannot start,
# and config.sh fails before registering, which leaves the pool half renamed.
for r in 1 2; do
  link="${RUNPOOL_BASE}/runners/bravo/runner-${r}/bin"
  [ -L "${link}" ] || fail "runner-${r}: bin is not a symlink"
  case "$(readlink "${link}")" in
    /*) fail "runner-${r}: bin is still an absolute link into the old path" ;;
  esac
  [ -d "${link}/" ] || fail "runner-${r}: bin does not resolve after the move"
  ok
  [ -d "${RUNPOOL_BASE}/runners/bravo/runner-${r}/externals/" ] || fail "runner-${r}: externals does not resolve"
  ok
done

# Written by _rp_write_plist against the new label, and the old ones removed by
# hand: _rp_rewrite_plists only ever writes.
present "${RUNPOOL_AGENT_DIR}/runpool.bravo.1.plist" "the new launch agent"
absent  "${RUNPOOL_AGENT_DIR}/runpool.alpha.1.plist" "the old launch agent"
absent  "${RUNPOOL_AGENT_DIR}/runpool.alpha.2.plist" "the second old launch agent"

present "${RUNPOOL_STATE_DIR}/pools/bravo.paused" "the pause flag moved"
absent  "${RUNPOOL_STATE_DIR}/pools/alpha.paused" "the old pause flag"
absent  "${RUNPOOL_STATE_DIR}/pools/alpha.started" "the old started stamp"

# The GitHub half. --replace cannot cover a name change, so the old
# registrations have to be deleted explicitly or they are stranded offline
# still carrying the old pool name as a label.
holds "${gh_log}" "DELETE /orgs/acme-inc/actions/runners/10" "runner 1 deregistered"
holds "${gh_log}" "DELETE /orgs/acme-inc/actions/runners/20" "runner 2 deregistered"
holds "${cfg_log}" "$(hostname -s)-bravo-1" "runner 1 registered under the new name"
holds "${cfg_log}" "$(hostname -s)-bravo-2" "runner 2 registered under the new name"
holds "${cfg_log}" "self-hosted,macOS,ARM64,bravo,xcode" "registered with the new label set"
lacks "${cfg_log}" "alpha" "nothing was registered under the old name"

# The lock is taken under both names and released on the way out.
absent "${RUNPOOL_STATE_DIR}/resize.alpha.lock" "the old lock"
absent "${RUNPOOL_STATE_DIR}/resize.bravo.lock" "the new lock"

# ---------------------------------------------------------------------------
# a legacy pool must not gain a cache directory
# ---------------------------------------------------------------------------
# POOL_CACHE_DIR being ABSENT is how _rp_load_pool recognises the legacy
# layout. Writing one here would silently convert the pool while its files
# stayed where they were.
build_pool alpha 1 1
probe alpha bravo >"${scratch_dir}/out" 2>&1 || fail "legacy rename failed: $(cat "${scratch_dir}/out")"
lacks "${RUNPOOL_BASE}/pools/bravo.conf" "POOL_CACHE_DIR" "a legacy pool stays legacy"

# ---------------------------------------------------------------------------
# a count lowered by hand
# ---------------------------------------------------------------------------
# runner-2 is on disk and registered but past the pool's count. It has to be
# deregistered, or it is stranded under a name nothing records; and it must not
# be re-registered, or the pool is a permanent miscount.
build_pool alpha 2
sed -i '' 's/POOL_COUNT="2"/POOL_COUNT="1"/' "${RUNPOOL_BASE}/pools/alpha.conf"
probe alpha bravo >"${scratch_dir}/out" 2>&1 || fail "rename failed: $(cat "${scratch_dir}/out")"
holds "${gh_log}"  "DELETE /orgs/acme-inc/actions/runners/20" "the surplus runner is deregistered"
lacks "${cfg_log}" "bravo-2" "the surplus runner is not re-registered"

# ---------------------------------------------------------------------------
# resumability
# ---------------------------------------------------------------------------
# _rp_move_dir returns success when the source is gone, which is what lets a
# rename interrupted after the move be finished by running it again.
build_pool alpha 1
mv "${RUNPOOL_BASE}/runners/alpha" "${RUNPOOL_BASE}/runners/bravo"
probe alpha bravo >"${scratch_dir}/out" 2>&1 || fail "an interrupted rename did not resume: $(cat "${scratch_dir}/out")"
present "${RUNPOOL_BASE}/pools/bravo.conf" "the resumed rename completed"

# ---------------------------------------------------------------------------
# refusals
# ---------------------------------------------------------------------------
refused() {
  local what="$1"; shift
  local out
  out=$(probe "$@" 2>&1) && fail "${what}: should have been refused"
  [ -f "${RUNPOOL_BASE}/pools/alpha.conf" ] || fail "${what}: the pool was touched"
  [ ! -d "${RUNPOOL_STATE_DIR}/resize.alpha.lock" ] || fail "${what}: left the old lock behind"
  [ ! -d "${RUNPOOL_STATE_DIR}/resize.bravo.lock" ] || fail "${what}: left the new lock behind"
  ok
  printf '%s\n' "${out}"
}

build_pool alpha 1
refused "unknown source pool"   nosuch bravo   >/dev/null
refused "invalid target name"   alpha "b ravo" >/dev/null
refused "renaming to itself"    alpha alpha    >/dev/null
refused "one name only"         alpha          >/dev/null
refused "an unknown flag"       alpha bravo --wat >/dev/null
refused "a zero timeout"        alpha bravo --timeout 0 >/dev/null

# A busy pool, and the message has to name the way through.
out=$(BUSY=1 probe alpha bravo 2>&1) && fail "a busy pool should refuse"
case "${out}" in
  *"--drain"*) ok ;;
  *) fail "the busy refusal does not name --drain: ${out}" ;;
esac

# A name already in use, in both directions.
build_pool alpha 1
cp "${RUNPOOL_BASE}/pools/alpha.conf" "${RUNPOOL_BASE}/pools/bravo.conf"
probe alpha bravo >/dev/null 2>&1 && fail "an existing target name should refuse"
ok
rm -f "${RUNPOOL_BASE}/pools/bravo.conf"

# Both locks are genuinely taken, which only a test holding each in turn shows.
build_pool alpha 1
mkdir -p "${RUNPOOL_STATE_DIR}/resize.alpha.lock"
echo $$ >"${RUNPOOL_STATE_DIR}/resize.alpha.lock/pid"
probe alpha bravo >/dev/null 2>&1 && fail "a locked source should refuse"
ok
rm -rf "${RUNPOOL_STATE_DIR}/resize.alpha.lock"
mkdir -p "${RUNPOOL_STATE_DIR}/resize.bravo.lock"
echo $$ >"${RUNPOOL_STATE_DIR}/resize.bravo.lock/pid"
probe alpha bravo >/dev/null 2>&1 && fail "a locked target should refuse"
ok
[ ! -d "${RUNPOOL_STATE_DIR}/resize.alpha.lock" ] || fail "the source lock was not released after the target lock failed"
ok
rm -rf "${RUNPOOL_STATE_DIR}/resize.bravo.lock"

# ---------------------------------------------------------------------------
# reregister repairs a moved install
# ---------------------------------------------------------------------------
# The documented recovery from a rename that failed part way, so it has to
# cope with the dangling links that failure leaves behind.
build_pool alpha 1
mv "${RUNPOOL_BASE}/runners/alpha" "${RUNPOOL_BASE}/runners/moved"
sed -i '' "s|runners/alpha|runners/moved|" "${RUNPOOL_BASE}/pools/alpha.conf"
(
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/common.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "${repo_dir}/lib/lifecycle.sh"
  _rp_down() { return 0; }
  _rp_busy_in() { echo 0; }
  _rp_reregister alpha
) >"${scratch_dir}/out" 2>&1 || fail "reregister did not repair a moved install: $(cat "${scratch_dir}/out")"
case "$(readlink "${RUNPOOL_BASE}/runners/moved/runner-1/bin")" in
  /*) fail "reregister left an absolute bin link" ;;
  *) ok ;;
esac

echo "ok: ${pass} case(s)"
