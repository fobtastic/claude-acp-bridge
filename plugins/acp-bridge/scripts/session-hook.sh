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

# shellcheck source=_lib.sh
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

ACTION="${1:-}"

case "$ACTION" in
  start)
    session_id=$(read_session_id_from_stdin)
    [ -z "$session_id" ] && exit 0

    mkdir -p "$STATE_DIR"
    session_paths "$session_id"
    : > "$SESSION_LIST_FILE"
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      printf 'export CLAUDE_ACP_SESSION_FILE=%q\n' "$SESSION_LIST_FILE" >> "$CLAUDE_ENV_FILE"
    fi
    ;;

  end)
    session_id=$(read_session_id_from_stdin)
    [ -z "$session_id" ] && exit 0
    session_paths "$session_id"

    # Kill the watcher daemon first so it can't race a final poll against
    # a backend we're about to close. Fire-and-forget — the watcher's trap
    # removes its PID file, but we rm it too in case SIGTERM was ignored.
    if [ -f "$SESSION_PID_FILE" ]; then
      watcher_pid=$(cat "$SESSION_PID_FILE" 2>/dev/null || true)
      if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        kill -TERM "$watcher_pid" 2>/dev/null || true
      fi
      rm -f "$SESSION_PID_FILE"
    fi
    rm -f "$SESSION_LASTJOBS_FILE" "$SESSION_PENDING_FILE" "$SESSION_INFLIGHT_FILE"

    if [ ! -f "$SESSION_LIST_FILE" ]; then
      exit 0
    fi

    if [ ! -x "$ACP_CLIENT_BIN" ]; then
      rm -f "$SESSION_LIST_FILE"
      exit 0
    fi

    # Iterate tracked backends (deduped at read time — acp.sh always
    # appends, never checks). Skip any backend with active background
    # jobs; close the rest.
    while IFS= read -r backend; do
      [ -z "$backend" ] && continue

      status_json=$("$ACP_CLIENT_BIN" --backend "$backend" status 2>/dev/null || echo "{}")
      active_jobs=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(int(d.get("activeJobs", 0)))
except Exception:
    print(0)
' <<<"$status_json" 2>/dev/null || echo "0")

      if [ "$active_jobs" -gt 0 ]; then
        echo "acp-bridge: skipping ${backend} — ${active_jobs} active jobs" >&2
      else
        "$ACP_CLIENT_BIN" --backend "$backend" close >/dev/null 2>&1 || true
        echo "acp-bridge: closed idle ${backend}" >&2
      fi
    done < <(sort -u "$SESSION_LIST_FILE")

    rm -f "$SESSION_LIST_FILE"
    ;;

  *)
    echo "session-hook.sh: unknown action '${ACTION}' (expected 'start' or 'end')" >&2
    exit 2
    ;;
esac
