#!/usr/bin/env bash
# Reference notifier — POST whatever runpool reports to a webhook.
#
# runpool never delivers anything itself. It writes one JSON object to this
# script's stdin and that is the whole contract, so replacing this with a
# script that writes to a file, rings a bell, or posts to chat needs no change
# to runpool at all.
#
# Enable in ~/.config/runpool/config:
#   RUNPOOL_NOTIFY_CMD="/path/to/runpool/contrib/notify-webhook.sh"
#   RUNPOOL_WEBHOOK_URL="https://example.com/alert"
#   RUNPOOL_WEBHOOK_TOKEN="..."       # optional, sent as a bearer token
#
# The payload runpool produces:
#   {
#     "source":   "runpool",
#     "severity": "critical" | "warning" | "info",
#     "title":    "one line",
#     "key":      "stable id grouping a condition with its recurrence",
#     "detail":   "optional prose",
#     "fields":   { "Label": "value", ... }
#   }
#
# Exit non-zero and runpool logs the delivery failure rather than swallowing it.
set -uo pipefail

: "${RUNPOOL_WEBHOOK_URL:?RUNPOOL_WEBHOOK_URL is not set}"

payload="$(cat)"

auth=()
[ -n "${RUNPOOL_WEBHOOK_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${RUNPOOL_WEBHOOK_TOKEN}")

code=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${RUNPOOL_WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  "${auth[@]+"${auth[@]}"}" \
  --max-time 10 \
  --data-binary "${payload}") || exit 1

case "${code}" in
  2*) exit 0 ;;
  *)  echo "notify-webhook: endpoint returned HTTP ${code}" >&2; exit 1 ;;
esac
