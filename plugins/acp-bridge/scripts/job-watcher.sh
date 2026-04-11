#!/usr/bin/env bash
# job-watcher.sh — long-lived background ACP job transition watcher.
#
# Invoked by the SessionStart hook (asyncRewake: true, timeout 24h). Polls
# all three ACP backends (gemini, qwen, codex) on a configurable interval
# and detects jobs that transition into a terminal state (completed/failed/
# etc.). On each transition:
#   - appends a formatted report to the per-session pending-notifications
#     file, which the UserPromptSubmit hook (inject-pending.sh) drains on
#     the user's next message and injects as additional context
#   - fans out the same report to notify-telegram.sh for AFK push
#
# The watcher then keeps polling — it does NOT exit after firing. This is
# the "Option B" design: no asyncRewake wake (it's never sent), no re-arming
# needed, notifications accumulate in the pending file until the next user
# turn delivers them to the model.
#
# Design notes:
# - Polls ALL three backends, not just ones tracked in $CLAUDE_ACP_SESSION_FILE
#   (Option Y — broader coverage at the cost of occasional cross-session noise).
# - First poll establishes a baseline; no notifications fire on startup.
# - Single-instance guaranteed by atomic mkdir lock (mkdir fails with EEXIST
#   if another watcher already holds the lock — race-free unlike a PID file
#   check-then-write).
# - On SIGTERM from SessionEnd, the trap cleans up the lock dir and exits 0.
#
# Env vars:
#   ACP_BRIDGE_WATCH_INTERVAL    — seconds between polls (default 30)
#   ACP_TOOL_BIN                 — override acp-tool path
#   ACP_BRIDGE_TELEGRAM_CHAT_ID  — if set, forward notifications via telegram
#   ACP_BRIDGE_WATCHER_SESSION_ID — explicit session id (bypasses stdin JSON);
#                                   used by inject-pending.sh when respawning
#                                   a crashed watcher

set -uo pipefail

BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"
BACKENDS=(gemini qwen codex)
INTERVAL="${ACP_BRIDGE_WATCH_INTERVAL:-30}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"
# Always derive PLUGIN_ROOT from this script's real path. We intentionally
# do NOT trust $CLAUDE_PLUGIN_ROOT here: the Claude Code parent process can
# leak another plugin's root into the hook subprocess environment, which
# would make $PLUGIN_ROOT/scripts/notify-telegram.sh resolve to a non-
# existent path and silently skip Telegram dispatch.
PLUGIN_ROOT="$(dirname "$(dirname "$(readlink -f "$0")")")"

# Resolve session_id: prefer explicit env (respawn path), fall back to stdin
# JSON (hook spawn path).
session_id="${ACP_BRIDGE_WATCHER_SESSION_ID:-}"
if [ -z "$session_id" ]; then
  input=$(cat 2>/dev/null || true)
  if [ -n "$input" ]; then
    session_id=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.stdin.read()).get('session_id', ''))
except Exception:
    print('')
" <<<"$input" 2>/dev/null || true)
  fi
fi

if [ -z "$session_id" ]; then
  exit 0
fi

if [ ! -x "$BIN" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR"
LOCK_DIR="$STATE_DIR/${session_id}.watcher.lock"
LAST_FILE="$STATE_DIR/${session_id}.lastjobs"
PENDING_FILE="$STATE_DIR/${session_id}.pending"

# Single-instance guard via atomic mkdir. mkdir is guaranteed to fail with
# EEXIST if another process won the race — no TOCTOU window like a PID file
# check-then-write. The loser exits silently; the winner writes its PID
# inside the lock dir so SessionEnd can signal it.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Lock exists. Is the holder still alive?
  existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    exit 0
  fi
  # Stale lock from a crashed watcher — take it over.
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"

# Track the temp file used in the current poll iteration so the trap can
# clean it up if SIGTERM arrives mid-loop.
TMP_CURRENT=""

cleanup_and_exit() {
  [ -n "$TMP_CURRENT" ] && rm -f "$TMP_CURRENT"
  rm -rf "$LOCK_DIR"
  exit 0
}
trap cleanup_and_exit TERM INT

# snapshot_jobs: emit one line per (backend, job_id) pair in the format
#   backend:job_id:status
# sorted and deduplicated. Silently skips backends whose bridge is not
# running or whose `jobs` call errors (stderr is swallowed).
#
# Expected acp-tool output format (verified via reconnaissance):
#   JOB ID           STATUS     CREATED AT      PROMPT
#   job_15ec13237179 failed     1775881017.86968 Reply with exactly: ...
snapshot_jobs() {
  local b output
  for b in "${BACKENDS[@]}"; do
    # Wrap acp-tool in `timeout` so a hung bridge socket can't freeze the
    # watcher loop. 10s is well above normal response time (~500ms) while
    # staying far below the default 30s poll interval.
    output=$(timeout 10 "$BIN" --backend "$b" jobs 2>/dev/null || true)
    if [ -z "$output" ]; then
      continue
    fi
    BACKEND="$b" python3 -c '
import os, sys

backend = os.environ["BACKEND"]
for line in sys.stdin:
    line = line.rstrip()
    if not line:
        continue
    parts = line.split()
    if len(parts) < 2:
        continue
    job_id, status = parts[0], parts[1]
    # Skip header row and anything that is not a real job id.
    if not job_id.startswith("job_"):
        continue
    print(f"{backend}:{job_id}:{status.lower()}")
' <<<"$output"
  done | sort -u
}

# Establish baseline snapshot — no notifications on first poll.
snapshot_jobs > "$LAST_FILE"

while true; do
  sleep "$INTERVAL"

  TMP_CURRENT=$(mktemp)
  snapshot_jobs > "$TMP_CURRENT"

  # Detect transitions: any (backend, job_id) whose current status is
  # terminal and differs from its previous status (including "not seen
  # before").
  report=$(LAST_FILE="$LAST_FILE" CURR_FILE="$TMP_CURRENT" python3 <<'PY'
import os

TERMINAL = {"completed", "succeeded", "failed", "error", "cancelled", "canceled", "done"}

def parse(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split(":", 2)
                if len(parts) == 3:
                    d[(parts[0], parts[1])] = parts[2]
    except FileNotFoundError:
        pass
    return d

last = parse(os.environ["LAST_FILE"])
curr = parse(os.environ["CURR_FILE"])

transitions = []
for key, curr_status in curr.items():
    last_status = last.get(key)
    if curr_status in TERMINAL and last_status != curr_status:
        backend, job_id = key
        transitions.append((backend, job_id, curr_status))

if transitions:
    lines = ["Detected ACP job status changes:", ""]
    for b, jid, s in transitions:
        mark = "✓" if s in ("completed", "succeeded", "done") else "✗"
        lines.append(f"  {mark} {b} job {jid}: {s}")
    lines.append("")
    lines.append("Run /acp-follow <backend> <job-id> to see the full output.")
    print("\n".join(lines))
PY
)

  if [ -n "$report" ]; then
    # Persist the new snapshot so we don't re-fire on the same transition.
    mv "$TMP_CURRENT" "$LAST_FILE"

    # Append the report to the pending-notifications file for the
    # UserPromptSubmit hook to drain on the user's next turn. A blank
    # line separates multiple reports so they stack readably if several
    # queue up between user turns.
    {
      printf '%s\n\n' "$report"
    } >> "$PENDING_FILE"

    # Fan out to telegram (best-effort; never fails the watcher).
    if [ -x "$PLUGIN_ROOT/scripts/notify-telegram.sh" ]; then
      printf '%s\n' "$report" | "$PLUGIN_ROOT/scripts/notify-telegram.sh" 2>/dev/null || true
    fi

    # Continue polling — do NOT exit. Multiple transitions across the
    # session accumulate in the pending file until drained.
    TMP_CURRENT=""
    continue
  fi

  mv "$TMP_CURRENT" "$LAST_FILE"
  TMP_CURRENT=""
done
