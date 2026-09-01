#!/bin/bash
# The join is bounded and reports progress, or it is indistinguishable from a
# hang. Offline: gh is stubbed, so nothing here reaches GitHub.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
base_dir="${scratch_dir}/base"
bin_dir="${scratch_dir}/bin"
telemetry="${base_dir}/telemetry/jobs.jsonl"

cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "${base_dir}/telemetry" "${bin_dir}"

# A gh that answers every run with one job, and records that it was called. The
# call count is the whole point: the window is only real if it cuts calls.
# Only the endpoint is logged, one line per call. Logging "$*" would log the
# --jq argument too, which spans three lines, and every call would count as
# three.
cat >"${bin_dir}/gh" <<'STUB'
#!/bin/bash
run_id=$(printf '%s\n' "$2" | sed -n 's#.*/runs/\([0-9]*\)/jobs#\1#p')
echo "${run_id}" >> "${GH_CALLS}"
printf '%s|runner-1\t1000\t1030\n' "${run_id}"
STUB
chmod +x "${bin_dir}/gh"

# One run an hour old, one ten days old. That straddles both the one-day window
# asked for explicitly below and the seven-day default, so the same pair of
# records exercises each.
now=$(date +%s)
recent=$(( now - 3600 ))
old=$(( now - 10 * 86400 ))

emit() {
  local run_id="$1" ts="$2"
  cat >>"${telemetry}" <<JSON
{"phase":"started","run_id":"${run_id}","job":"build","repo":"acme/widget","workflow":"CI","runner":"runner-1","concurrent":1,"load1":1.0,"cores":8,"ts":${ts}}
{"phase":"completed","run_id":"${run_id}","job":"build","duration":60}
JSON
}
emit 111 "${recent}"
emit 222 "${old}"

join_sh() {
  env PATH="${bin_dir}:${PATH}" GH_CALLS="${scratch_dir}/calls" \
      "${repo_dir}/contrib/telemetry-join.sh" "${telemetry}" "$@"
}

runpool() {
  env RUNPOOL_BASE="${base_dir}" PATH="${bin_dir}:${PATH}" GH_CALLS="${scratch_dir}/calls" \
      "${repo_dir}/bin/runpool" "$@"
}

calls() { grep -c . "${scratch_dir}/calls" 2>/dev/null || echo 0; }

# --- the window actually bounds the API calls ---------------------------------
: >"${scratch_dir}/calls"
out=$(join_sh --days 1 2>/dev/null) || fail "--days 1 exited non-zero"
[ "$(calls)" = "1" ] || fail "--days 1 made $(calls) call(s), expected 1"
printf '%s\n' "${out}" | grep -q . || fail "--days 1 produced no output at all"

: >"${scratch_dir}/calls"
join_sh --all >/dev/null 2>&1 || fail "--all exited non-zero"
[ "$(calls)" = "2" ] || fail "--all made $(calls) call(s), expected 2"

# Default is a window, not everything. If this ever reads 2, the default has
# silently become unbounded again, which is the bug this file exists for.
: >"${scratch_dir}/calls"
join_sh >/dev/null 2>&1 || fail "the default run exited non-zero"
[ "$(calls)" = "1" ] || fail "the default made $(calls) call(s), expected 1 (7-day window)"

# --- it says what it is doing before it does it -------------------------------
err=$(join_sh --days 1 2>&1 >/dev/null)
case "${err}" in
  *"Joining 1 run"*) ;;
  *) fail "the join did not report its run count: ${err}" ;;
esac
case "${err}" in
  *"at a time"*) ;;
  *) fail "the join did not report its concurrency: ${err}" ;;
esac

err=$(join_sh --all 2>&1 >/dev/null)
case "${err}" in
  *"all 2 run"*) ;;
  *) fail "--all did not report an unbounded join: ${err}" ;;
esac

# --- flag parsing, both entry points ------------------------------------------
assert_refused() {
  local what="$1"; shift
  "$@" >/dev/null 2>&1 && fail "${what}: expected a non-zero exit"
  return 0
}

assert_refused "join --days with no value"   join_sh --days
assert_refused "join --days abc"             join_sh --days abc
assert_refused "join --days 0"               join_sh --days 0
assert_refused "join unknown flag"           join_sh --bogus

assert_refused "stats --days with no value"  runpool stats --days
assert_refused "stats --days abc"            runpool stats --days abc
assert_refused "stats --days 0"              runpool stats --days 0
assert_refused "stats unknown flag"          runpool stats --nope

# --days and --all imply --queue: they mean nothing to the local table, and
# accepting them there would silently ignore what the caller asked for.
out=$(runpool stats --days 1 2>&1) || fail "stats --days 1 exited non-zero"
case "${out}" in
  *"Queue time"*) ;;
  *) fail "stats --days 1 did not run the join: ${out}" ;;
esac

out=$(runpool stats --all 2>&1) || fail "stats --all exited non-zero"
case "${out}" in
  *"Queue time"*) ;;
  *) fail "stats --all did not run the join: ${out}" ;;
esac

echo "OK: stats queue window"
