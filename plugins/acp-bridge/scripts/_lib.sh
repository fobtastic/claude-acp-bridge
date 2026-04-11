#!/usr/bin/env bash
# _lib.sh — shared helpers for the acp-bridge plugin scripts.
#
# Sourced by acp.sh, session-hook.sh, job-watcher.sh, inject-pending.sh.
# Not an executable — source it with `. "$(dirname ...)/_lib.sh"`.

# Resolve plugin layout from THIS file's location, so every sourcing
# script sees the same PLUGIN_ROOT regardless of where it was invoked
# from. We do NOT trust $CLAUDE_PLUGIN_ROOT — the parent Claude Code
# process can leak another plugin's root into hook subprocess envs.
_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PLUGIN_ROOT="$(dirname "$_LIB_DIR")"
DEFAULT_ACP_CLIENT_BIN="$PLUGIN_ROOT/bin/acp-client"
ACP_CLIENT_BIN="${ACP_CLIENT_BIN:-$DEFAULT_ACP_CLIENT_BIN}"

# Per-session state lives under here. One directory, many files keyed
# by session id + a documented suffix set.
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"

# Canonical backend list. Order drives iteration in snapshot_jobs and
# /acp-status fan-outs. Adding a backend means editing this one line.
BACKENDS=(gemini qwen codex)

# Echo the session_id extracted from the JSON on stdin. Echoes empty
# string on empty input, invalid JSON, or missing session_id. Always
# exits zero — hook failures would block the user's prompt, so parse
# problems must be silent.
read_session_id_from_stdin() {
  local input
  input=$(cat 2>/dev/null || true)
  if [ -z "$input" ]; then
    echo ""
    return 0
  fi
  python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read()).get("session_id", ""))
except Exception:
    print("")
' <<<"$input"
}

# session_paths <session_id>
# Populates the per-session path globals from one session id. The
# single source of truth for file suffixes — adding a new per-session
# file means adding one line here and nowhere else.
#
# Sets:
#   SESSION_LIST_FILE     — backends this session has touched
#   SESSION_LASTJOBS_FILE — watcher's last job snapshot for diffing
#   SESSION_PID_FILE      — watcher daemon PID (noclobber-locked)
#   SESSION_PENDING_FILE  — queued transition reports for injection
#   SESSION_INFLIGHT_FILE — transient drained file being injected
session_paths() {
  local sid="$1"
  SESSION_LIST_FILE="$STATE_DIR/${sid}.list"
  SESSION_LASTJOBS_FILE="$STATE_DIR/${sid}.lastjobs"
  SESSION_PID_FILE="$STATE_DIR/${sid}.watcher.pid"
  SESSION_PENDING_FILE="$STATE_DIR/${sid}.pending"
  SESSION_INFLIGHT_FILE="$STATE_DIR/${sid}.pending.inflight"
}

# Human-readable list of backends for error messages: "gemini, qwen, or codex".
backends_display() {
  local n=${#BACKENDS[@]}
  if [ "$n" -eq 0 ]; then echo ""; return; fi
  if [ "$n" -eq 1 ]; then echo "${BACKENDS[0]}"; return; fi
  local head tail
  head=$(IFS=,; echo "${BACKENDS[*]:0:$((n-1))}")
  tail="${BACKENDS[$((n-1))]}"
  echo "${head//,/, }, or ${tail}"
}

# True if $1 is one of the backends in BACKENDS.
is_valid_backend() {
  local target="$1" b
  for b in "${BACKENDS[@]}"; do
    [ "$b" = "$target" ] && return 0
  done
  return 1
}
