#!/bin/bash
# A loaded launchd agent says nothing about whether its program still exists.
# Offline: reads plist files in a scratch HOME, loads nothing, calls nothing.
#
# The path a plist records is verified against the running machines rather than
# here: writing one means invoking `schedule install`, which loads agents under
# the real label namespace, and a test that can disturb the live scheduler is
# worse than one that covers less.
set -uo pipefail

repo_dir=$(cd -P "$(dirname "$0")/.." && pwd)
scratch_dir=$(mktemp -d)

cleanup() { rm -rf "${scratch_dir}"; }
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

HOME="${scratch_dir}/home"
export HOME
mkdir -p "${HOME}/Library/LaunchAgents"

# shellcheck source=/dev/null
RUNPOOL_ROOT="${repo_dir}" . "${repo_dir}/lib/common.sh"

write_agent() {
  cat >"${HOME}/Library/LaunchAgents/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$2</string><string>tick</string></array>
</dict></plist>
PLIST
}

# --- a program that is there ---------------------------------------------------
write_agent "probe.present" "/bin/echo"
if _rp_agent_program_missing "probe.present"; then
  fail "an existing program was reported as missing"
fi
[ "$(_rp_agent_program "probe.present")" = "/bin/echo" ] \
  || fail "wrong program reported: $(_rp_agent_program "probe.present")"

# --- a program that has been deleted -------------------------------------------
#
# This is the real case, exactly as it was found: an agent installed under one
# Homebrew version keeps that version's Cellar path, and the next upgrade
# removes the directory. launchd still reports the agent as loaded.
gone="/opt/homebrew/Cellar/runpool/0.0.1/libexec/bin/runpool"
write_agent "probe.gone" "${gone}"
_rp_agent_program_missing "probe.gone" \
  || fail "a deleted program was not reported as missing"
[ "$(_rp_agent_program "probe.gone")" = "${gone}" ] \
  || fail "wrong program reported: $(_rp_agent_program "probe.gone")"

# --- a program that exists but is not executable --------------------------------
touch "${scratch_dir}/not-executable"
write_agent "probe.notexec" "${scratch_dir}/not-executable"
_rp_agent_program_missing "probe.notexec" \
  || fail "a non-executable program was not reported as missing"

# --- no agent at all ------------------------------------------------------------
#
# Not installed and pointing at nothing are different faults with different
# fixes, and doctor reports them separately. This must not claim the first is
# the second.
if _rp_agent_program_missing "probe.absent"; then
  fail "an uninstalled agent was reported as having a missing program"
fi

echo "OK: scheduler agent path"
