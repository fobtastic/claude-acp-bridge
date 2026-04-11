#!/usr/bin/env bash
# session-hook.sh — Claude Code session lifecycle hook for acp-bridge.
#
# Actions:
#   start - Create per-session state file, export CLAUDE_ACP_SESSION_FILE via
#           $CLAUDE_ENV_FILE so subsequent bash invocations can track which
#           backends this session touches.
#   end   - Read the state file and close each tracked bridge, but only if
#           it is idle (activeJobs == 0). Bridges with active background
#           jobs are preserved so long-running /acp-submit work survives
#           session termination.

set -euo pipefail

ACTION="${1:-}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"

read_session_id_from_stdin() {
  # Claude Code hooks receive JSON on stdin with a session_id field.
  local input
  input=$(cat 2>/dev/null || true)
  if [ -z "$input" ]; then
    echo ""
    return
  fi
  python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('session_id', ''))
except Exception:
    print('')
" <<<"$input"
}

case "$ACTION" in
  start)
    session_id=$(read_session_id_from_stdin)
    if [ -z "$session_id" ]; then
      # No session id — nothing to track. Exit silently.
      exit 0
    fi
    mkdir -p "$STATE_DIR"
    state_file="$STATE_DIR/$session_id.list"
    : > "$state_file"
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      printf 'export CLAUDE_ACP_SESSION_FILE=%q\n' "$state_file" >> "$CLAUDE_ENV_FILE"
    fi
    ;;
  end)
    session_id=$(read_session_id_from_stdin)
    if [ -z "$session_id" ]; then
      exit 0
    fi

    # Kill the background job watcher if it is still running, and clean
    # up its lock dir + state files. Done before bridge cleanup so the
    # watcher cannot race a final poll against a backend we are about to
    # close.
    watcher_lock_dir="$STATE_DIR/${session_id}.watcher.lock"
    if [ -d "$watcher_lock_dir" ]; then
      watcher_pid=$(cat "$watcher_lock_dir/pid" 2>/dev/null || true)
      if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        kill -TERM "$watcher_pid" 2>/dev/null || true
        sleep 0.2
      fi
      rm -rf "$watcher_lock_dir"
    fi
    # Also catch legacy PID file from pre-lock-dir versions.
    rm -f "$STATE_DIR/${session_id}.watcher.pid"
    rm -f "$STATE_DIR/${session_id}.lastjobs"
    rm -f "$STATE_DIR/${session_id}.pending"
    rm -f "$STATE_DIR/${session_id}.pending.inflight"

    state_file="$STATE_DIR/$session_id.list"
    if [ ! -f "$state_file" ]; then
      exit 0
    fi

    BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"
    if [ ! -x "$BIN" ]; then
      rm -f "$state_file"
      exit 0
    fi

    # Dedup and iterate tracked backends.
    while IFS= read -r backend; do
      [ -z "$backend" ] && continue

      status_json=$("$BIN" --backend "$backend" status 2>/dev/null || echo "{}")
      active_jobs=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(int(d.get('activeJobs', 0)))
except Exception:
    print(0)
" <<<"$status_json" 2>/dev/null || echo "0")

      if [ "$active_jobs" -gt 0 ]; then
        echo "acp-bridge: skipping ${backend} — ${active_jobs} active jobs" >&2
      else
        "$BIN" --backend "$backend" close >/dev/null 2>&1 || true
        echo "acp-bridge: closed idle ${backend}" >&2
      fi
    done < <(sort -u "$state_file")

    rm -f "$state_file"
    ;;
  *)
    echo "session-hook.sh: unknown action '${ACTION}' (expected 'start' or 'end')" >&2
    exit 2
    ;;
esac
