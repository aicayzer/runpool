#!/usr/bin/env bash
# Install runpool by symlinking it onto PATH. The repository stays where it is,
# so a `git pull` updates the tool with no reinstall.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/runpool"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "runpool is macOS only: it uses launchd, and the Linux and Windows cases are already well served by existing autoscalers." >&2; exit 1 ;;
esac

missing=""
for dep in gh curl tar; do
  command -v "${dep}" >/dev/null 2>&1 || missing="${missing} ${dep}"
done
if [ -n "${missing}" ]; then
  echo "missing dependencies:${missing}" >&2
  echo "gh is the GitHub CLI and must be authenticated: gh auth login" >&2
  exit 1
fi

chmod +x "${ROOT}/bin/runpool" "${ROOT}/contrib/"*.sh

if [ ! -d "${PREFIX}" ]; then
  echo "no such directory: ${PREFIX} (set PREFIX to somewhere on your PATH)" >&2
  exit 1
fi
ln -sf "${ROOT}/bin/runpool" "${PREFIX}/runpool"
echo "linked ${PREFIX}/runpool -> ${ROOT}/bin/runpool"

mkdir -p "${CONFIG_DIR}"
if [ ! -f "${CONFIG_DIR}/config" ]; then
  cp "${ROOT}/runpool.conf.example" "${CONFIG_DIR}/config"
  echo "wrote ${CONFIG_DIR}/config (all defaults, edit as needed)"
else
  echo "kept existing ${CONFIG_DIR}/config"
fi

cat <<'NEXT'

Next:
  runpool register <pool> --repo OWNER/REPO   # or --org ORG
  runpool schedule install                    # background autoscale and clean
  runpool status

Pools come up on their own when a job queues. Nothing starts at login.
NEXT
