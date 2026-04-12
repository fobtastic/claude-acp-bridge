#!/usr/bin/env bash
# inject-pending.sh — UserPromptSubmit hook that drains pending ACP job
# notifications into the model's context.
#
# How it fits into Option B's delivery pipeline:
#   1. job-watcher.sh (long-lived daemon) detects job transitions and
#      appends reports to <session>.pending
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

# shellcheck source=_lib.sh
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

session_id=$(read_session_id_from_stdin)
[ -z "$session_id" ] && exit 0
session_paths "$session_id"

# Self-heal: if no live watcher holds the PID file, spawn a replacement.
# Done BEFORE draining so a crashed watcher gets replaced regardless of
# whether there's anything to inject this turn.
watcher_alive=0
if [ -f "$SESSION_PID_FILE" ]; then
  existing_pid=$(cat "$SESSION_PID_FILE" 2>/dev/null || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    watcher_alive=1
  fi
fi

if [ "$watcher_alive" = "0" ] && [ -x "$PLUGIN_ROOT/scripts/job-watcher.sh" ]; then
  # Respawn detached. setsid + </dev/null + disown fully detaches from the
  # hook's process group so the watcher survives this hook exiting. The
  # watcher reads session_id from $ACP_BRIDGE_WATCHER_SESSION_ID rather
  # than stdin JSON, since we've already consumed stdin here.
  ACP_BRIDGE_WATCHER_SESSION_ID="$session_id" \
    setsid bash "$PLUGIN_ROOT/scripts/job-watcher.sh" \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# Drain pending job reports and permission requests atomically.
# mv is atomic on the same filesystem.
mv "$SESSION_PENDING_FILE" "$SESSION_INFLIGHT_FILE" 2>/dev/null || true
mv "$SESSION_PERM_PENDING" "$SESSION_PERM_INFLIGHT" 2>/dev/null || true

# If both are missing or empty, exit.
if [ ! -s "$SESSION_INFLIGHT_FILE" ] && [ ! -s "$SESSION_PERM_INFLIGHT" ]; then
  rm -f "$SESSION_INFLIGHT_FILE" "$SESSION_PERM_INFLIGHT"
  exit 0
fi

# Format job reports.
PENDING_CONTENT=""
if [ -s "$SESSION_INFLIGHT_FILE" ]; then
  PENDING_CONTENT=$(cat "$SESSION_INFLIGHT_FILE")
  rm -f "$SESSION_INFLIGHT_FILE"
fi

# Format permission requests human-readably.
PERM_CONTENT=""
if [ -s "$SESSION_PERM_INFLIGHT" ]; then
  PERM_CONTENT=$(python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        p = json.loads(line)
        print(f"--- PERMISSION REQUEST: {p[\"backend\"]} ---")
        print(f"ID: {p[\"requestId\"]}")
        print(f"Description: {p[\"description\"]}")
        action = p.get("action", {})
        if action.get("type") and action.get("type") != "unknown":
            print(f"Action Type: {action[\"type\"]}")
        if action.get("path"):
            print(f"Path: {action[\"path\"]}")
        if action.get("command"):
            print(f"Command: {action[\"command\"]}")
        print(f"Approve: /acp-approve {p[\"backend\"]} {p[\"requestId\"]}")
        print(f"Deny:    /acp-deny {p[\"backend\"]} {p[\"requestId\"]}")
        print("")
    except Exception:
        continue
' < "$SESSION_PERM_INFLIGHT")
  rm -f "$SESSION_PERM_INFLIGHT"
fi

# Combine and emit the hook response.
# Claude Code injects `additionalContext` as a system reminder.
FULL_CONTENT=""
if [ -n "$PENDING_CONTENT" ]; then
  FULL_CONTENT="$PENDING_CONTENT"
fi
if [ -n "$PERM_CONTENT" ]; then
  if [ -n "$FULL_CONTENT" ]; then
    FULL_CONTENT="${FULL_CONTENT}"$'\n\n'"${PERM_CONTENT}"
  else
    FULL_CONTENT="$PERM_CONTENT"
  fi
fi

python3 -c '
import json, sys
content = sys.stdin.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": content,
    }
}))
' <<<"$FULL_CONTENT"
