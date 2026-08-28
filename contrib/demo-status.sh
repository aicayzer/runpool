#!/bin/sh
# A stand-in for runpool that reports invented pools on an invented machine.
#
# For screenshots, demos and for developing anything that reads runpool's JSON
# without needing real runners, real repositories or a real GitHub account.
#
# It answers `status` with a fixed payload in the same shape as
# `runpool status --json` and ignores every other command, so nothing it is
# pointed at can be changed by accident. That makes it safe to leave wired up
# while you click around.
#
# Usage:
#   demo-status.sh status --json
#
# With the Raycast extension, set the "Executable Path" preference to this
# file. The extension runs whatever that names, so no demo code has to exist
# inside the extension itself, and clearing the preference puts the real pools
# back. Anything else that shells out to runpool can be pointed here the same
# way.
#
# The three pools are built on GitHub's own public demo repositories, so the
# avatars resolve and nothing private appears, and between them they show all
# three normal states: Active, Idle and Offline.

case "$1" in
  status)
    cat <<'JSON'
{
  "paused": false,
  "local": false,
  "machine": { "load": 3.2, "cores": 10, "load_warn": 20 },
  "paths": {
    "base": "/Users/you/Library/Application Support/runpool",
    "cache": "/Users/you/Library/Caches/runpool",
    "log": "/Users/you/Library/Logs/runpool/runpool.log",
    "log_dir": "/Users/you/Library/Logs/runpool",
    "telemetry": "/Users/you/Library/Application Support/runpool/telemetry/jobs.jsonl"
  },
  "pools": [
    {
      "name": "github",
      "scope": "org",
      "target": "github",
      "count": 4,
      "running": 4,
      "busy": 2,
      "paused": false,
      "github_registered": 4,
      "github_online": 4,
      "watch": ["github/docs", "github/linguist", "github/gitignore", "github/scientist", "github/codeql-action"]
    },
    {
      "name": "hello-world",
      "scope": "repo",
      "target": "octocat/Hello-World",
      "count": 2,
      "running": 2,
      "busy": 0,
      "paused": false,
      "github_registered": 2,
      "github_online": 2,
      "watch": []
    },
    {
      "name": "spoon-knife",
      "scope": "repo",
      "target": "octocat/Spoon-Knife",
      "count": 2,
      "running": 0,
      "busy": 0,
      "paused": true,
      "github_registered": 2,
      "github_online": 0,
      "watch": []
    }
  ]
}
JSON
    ;;
  *)
    # Anything that would change state does nothing and reports success, so
    # nothing here can reach a real pool.
    exit 0
    ;;
esac
