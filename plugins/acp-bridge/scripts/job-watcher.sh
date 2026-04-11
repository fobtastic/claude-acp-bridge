#!/usr/bin/env bash
# job-watcher.sh — long-lived background ACP job transition watcher.
#
# Invoked by the SessionStart hook with asyncRewake: true. Polls all three
# ACP backends (gemini, qwen, codex) on a configurable interval, detects
# jobs that transition into a terminal state (completed/failed/etc.), and
# exits with code 2 to wake the model via Claude Code's asyncRewake hook
# mechanism. Also fans out notifications to notify-telegram.sh for AFK
# push notifications when ACP_BRIDGE_TELEGRAM_CHAT_ID is configured.
#
# Design notes:
# - Polls ALL three backends, not just ones tracked in $CLAUDE_ACP_SESSION_FILE
#   (Option Y — broader coverage at the cost of occasional cross-session noise).
# - First poll establishes a baseline; no notifications fire on startup.
# - Re-arming after a fire requires a Claude Code session restart (asyncRewake
#   is a once-per-hook-spawn mechanism in v0.1).
#
# Env vars:
#   ACP_BRIDGE_WATCH_INTERVAL   — seconds between polls (default 30)
#   ACP_TOOL_BIN                — override acp-tool path
#   ACP_BRIDGE_TELEGRAM_CHAT_ID — if set, forward notifications via telegram

set -uo pipefail

BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"
BACKENDS=(gemini qwen codex)
INTERVAL="${ACP_BRIDGE_WATCH_INTERVAL:-30}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(readlink -f "$0")")")}"

# Read session_id from stdin JSON (same pattern as session-hook.sh).
input=$(cat 2>/dev/null || true)
session_id=""
if [ -n "$input" ]; then
  session_id=$(python3 -c "
import json, sys
try:
    print(json.loads(sys.stdin.read()).get('session_id', ''))
except Exception:
    print('')
" <<<"$input" 2>/dev/null || true)
fi

if [ -z "$session_id" ]; then
  exit 0
fi

if [ ! -x "$BIN" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/${session_id}.watcher.pid"
LAST_FILE="$STATE_DIR/${session_id}.lastjobs"

echo $$ > "$PID_FILE"

# Track the temp file used in the current poll iteration so the trap can
# clean it up if SIGTERM arrives mid-loop. Normal exit paths mv or rm it.
TMP_CURRENT=""

cleanup_and_exit() {
  [ -n "$TMP_CURRENT" ] && rm -f "$TMP_CURRENT"
  rm -f "$PID_FILE"
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
#
# Parser rules:
#   - skip blank lines
#   - skip header line (first token literally "JOB")
#   - skip tracebacks/errors (first token contains non-id characters)
#   - a data line has at least two whitespace-separated tokens; token[0]
#     must start with "job_" to be considered a job id.
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
  # before"). The python block is invoked via heredoc with the file
  # paths passed as argv to avoid embedded-quote surprises.
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
    lines.append("Note: re-arming the watcher requires a Claude Code session restart.")
    print("\n".join(lines))
PY
)

  if [ -n "$report" ]; then
    # Persist the new snapshot so a re-armed watcher doesn't re-report.
    mv "$TMP_CURRENT" "$LAST_FILE"

    # Fan out to telegram (best-effort; never fails the watcher).
    if [ -x "$PLUGIN_ROOT/scripts/notify-telegram.sh" ]; then
      printf '%s\n' "$report" | "$PLUGIN_ROOT/scripts/notify-telegram.sh" 2>/dev/null || true
    fi

    printf '%s\n' "$report"
    rm -f "$PID_FILE"
    exit 2
  fi

  mv "$TMP_CURRENT" "$LAST_FILE"
done
