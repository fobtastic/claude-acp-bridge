#!/usr/bin/env bash
# inject-pending.sh — UserPromptSubmit hook that drains pending ACP job
# notifications into the model's context.
#
# How it fits into Option B's delivery pipeline:
#   1. job-watcher.sh (long-lived daemon) detects job transitions and
#      appends reports to $STATE_DIR/<session>.pending
#   2. On every user prompt, Claude Code runs this hook
#   3. This hook atomically renames .pending -> .pending.inflight so the
#      watcher's next append goes to a fresh .pending without racing our
#      read, then emits the inflight contents as `additionalContext` in
#      the UserPromptSubmit hook JSON response, which Claude Code
#      injects as a system reminder
#   4. This hook also self-heals: if the watcher process is no longer
#      alive (crashed, killed, etc.), it respawns one in the background
#
# Stdin JSON from Claude Code:  {session_id, transcript_path, cwd, ...}
# Stdout: optional JSON with hookSpecificOutput.additionalContext

set -uo pipefail

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"
PLUGIN_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"

# Read session_id from stdin JSON. If we can't parse it, bail silently —
# failing the hook would block the user's prompt.
input=$(cat 2>/dev/null || true)
if [ -z "$input" ]; then
  exit 0
fi

session_id=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.stdin.read()).get('session_id', ''))
except Exception:
    print('')
" <<<"$input" 2>/dev/null || true)

if [ -z "$session_id" ]; then
  exit 0
fi

PENDING_FILE="$STATE_DIR/${session_id}.pending"
INFLIGHT_FILE="$STATE_DIR/${session_id}.pending.inflight"
LOCK_DIR="$STATE_DIR/${session_id}.watcher.lock"

# Self-heal: if the watcher is not alive, spawn a replacement. We do this
# BEFORE draining so a fresh watcher is running regardless of whether
# there's anything to inject right now.
watcher_alive=0
if [ -d "$LOCK_DIR" ]; then
  existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    watcher_alive=1
  fi
fi

if [ "$watcher_alive" = "0" ] && [ -x "$PLUGIN_ROOT/scripts/job-watcher.sh" ]; then
  # Respawn detached. Pass session_id via env so the watcher doesn't need
  # stdin JSON. Route stdio to /dev/null and setsid to fully detach from
  # the hook's process group, so the watcher survives this hook exiting.
  ACP_BRIDGE_WATCHER_SESSION_ID="$session_id" \
    setsid bash "$PLUGIN_ROOT/scripts/job-watcher.sh" \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# Drain the pending file atomically. mv is atomic on the same filesystem,
# so the watcher's next append (to the now-missing .pending) creates a
# fresh file that this hook will pick up on the next turn.
if [ ! -f "$PENDING_FILE" ]; then
  exit 0
fi

if ! mv "$PENDING_FILE" "$INFLIGHT_FILE" 2>/dev/null; then
  exit 0
fi

# Read inflight, remove it, emit as additional context. Skip injection if
# the file is empty (e.g. a prior turn drained it and a race left an
# empty file behind).
if [ ! -s "$INFLIGHT_FILE" ]; then
  rm -f "$INFLIGHT_FILE"
  exit 0
fi

# Emit the hook-specific JSON response. Claude Code injects the
# `additionalContext` string as a system reminder visible to the model.
PENDING_CONTENT=$(cat "$INFLIGHT_FILE")
rm -f "$INFLIGHT_FILE"

# Use python to JSON-encode the content safely (preserves newlines,
# escapes quotes, handles unicode).
PAYLOAD=$(python3 -c "
import json, sys
content = sys.stdin.read()
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': content,
    }
}))
" <<<"$PENDING_CONTENT")

printf '%s\n' "$PAYLOAD"
