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
#   ACP_CLIENT_BIN               — override bundled acp-client path
#   ACP_BRIDGE_TELEGRAM_CHAT_ID  — if set, forward notifications via telegram
#   ACP_BRIDGE_WATCHER_SESSION_ID — explicit session id (bypasses stdin JSON);
#                                   used by inject-pending.sh when respawning
#                                   a crashed watcher

set -uo pipefail

# Derive plugin paths from this script's real location. We intentionally do
# NOT trust $CLAUDE_PLUGIN_ROOT — it can be polluted by other plugins when
# the hook subprocess inherits a parent env (observed with the telegram
# plugin leaking its root into the acp-bridge watcher's env).
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
BIN="${ACP_CLIENT_BIN:-$PLUGIN_ROOT/bin/acp-client}"
BACKENDS=(gemini qwen codex)
INTERVAL="${ACP_BRIDGE_WATCH_INTERVAL:-30}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-acp-bridge/sessions"

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
PID_FILE="$STATE_DIR/${session_id}.watcher.pid"
LAST_FILE="$STATE_DIR/${session_id}.lastjobs"
PENDING_FILE="$STATE_DIR/${session_id}.pending"

# Single-instance guard via atomic-create PID file. `set -C` (noclobber)
# makes `> file` fail if the file already exists — this is the open(2)
# O_CREAT|O_EXCL equivalent, which is atomic at the kernel level. We
# intentionally do NOT use flock here: flock locks are fd-associated,
# and bash's $(...) subshells inherit open fds, so a subshell spawned
# mid-poll can keep a lock alive briefly after the main watcher exits,
# blocking a fresh spawn.
#
# Race handling:
#   Winner: `set -C; echo $$ > $PID_FILE` succeeds, writes own PID.
#   Loser:  same command fails (file exists). Reads the file; if PID is
#           alive, exits silently. If the file is momentarily empty
#           (winner hasn't finished the echo yet — a microsecond window),
#           retries a few times before deciding the lock is stale.
#   Stale:  a PID file with a dead PID gets overwritten by the new spawn.
if ! (set -C; echo $$ > "$PID_FILE") 2>/dev/null; then
  # PID file exists. Retry-read in case the winner is mid-write.
  existing_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    [ -n "$existing_pid" ] && break
    sleep 0.05
  done

  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    # A live watcher already holds it. Exit silently.
    exit 0
  fi

  # Stale PID file (holder is dead). Take over.
  echo $$ > "$PID_FILE"
fi

# Track the temp file used in the current poll iteration so the trap can
# clean it up if SIGTERM arrives mid-loop.
TMP_CURRENT=""

cleanup_and_exit() {
  [ -n "$TMP_CURRENT" ] && rm -f "$TMP_CURRENT"
  rm -f "$PID_FILE"
  exit 0
}
trap cleanup_and_exit TERM INT

# snapshot_jobs: emit one line per (backend, job_id) pair in the format
#   backend:job_id:status
# plus one synthetic `backend:__probed__:ok` marker per backend whose
# bridge responded successfully. Silently skips backends whose bridge is
# not running or whose `jobs` call errors — those backends are absent
# from the snapshot, marking them "not probed" for the transition diff.
#
# The __probed__ marker distinguishes "this backend had zero jobs" (probed,
# header row returned, zero data rows) from "this backend was down" (no
# output at all). Transition detection in the python diff only fires for
# backends that were probed in BOTH snapshots — so a bridge that comes up
# for the first time (startup or mid-session) contributes a baseline
# without firing stale reports for its pre-existing jobs.
#
# Expected acp-client output format:
#   JOB ID           STATUS     CREATED AT      PROMPT
#   job_15ec13237179 failed     1775881017.86968 Reply with exactly: ...
snapshot_jobs() {
  local b output
  for b in "${BACKENDS[@]}"; do
    # Wrap acp-client in `timeout` so a hung bridge socket can't freeze
    # the watcher loop. 10s is well above normal response time (~500ms)
    # while staying far below the default 30s poll interval.
    output=$(timeout 10 "$BIN" --backend "$b" jobs 2>/dev/null || true)
    if [ -z "$output" ]; then
      # Bridge is down or errored — do NOT emit a probed marker. This
      # backend is absent from the snapshot, so any jobs it returns
      # later will be treated as discovery, not transitions.
      continue
    fi
    # Bridge responded (even if just the header row). Mark as probed and
    # emit any parseable job rows.
    echo "${b}:__probed__:ok"
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
  # terminal AND whose backend was probed in BOTH snapshots AND whose
  # previous status differs (including "not seen before").
  #
  # The "probed in both snapshots" guard is what prevents stale reports
  # from firing on first-observation of a backend whose bridge was down
  # during the previous poll (e.g., at session startup or after a mid-
  # session bridge restart).
  report=$(LAST_FILE="$LAST_FILE" CURR_FILE="$TMP_CURRENT" python3 <<'PY'
import os

TERMINAL = {"completed", "succeeded", "failed", "error", "cancelled", "canceled", "done"}

def parse(path):
    jobs = {}
    probed = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split(":", 2)
                if len(parts) != 3:
                    continue
                backend, key, status = parts
                if key == "__probed__":
                    probed.add(backend)
                else:
                    jobs[(backend, key)] = status
    except FileNotFoundError:
        pass
    return jobs, probed

last_jobs, last_probed = parse(os.environ["LAST_FILE"])
curr_jobs, _curr_probed = parse(os.environ["CURR_FILE"])

transitions = []
for key, curr_status in curr_jobs.items():
    backend, job_id = key
    # Suppress fires from backends that were NOT probed in the previous
    # snapshot. If we've never successfully observed this backend before,
    # its entries are "discovered history", not transitions.
    if backend not in last_probed:
        continue
    if curr_status not in TERMINAL:
        continue
    last_status = last_jobs.get(key)
    if last_status != curr_status:
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
