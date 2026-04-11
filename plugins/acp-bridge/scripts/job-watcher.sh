#!/usr/bin/env bash
# job-watcher.sh — long-lived daemon that watches ACP jobs and queues
# completion reports for the UserPromptSubmit hook to inject.
#
# Invoked by the SessionStart hook (asyncRewake: true, timeout 24h). Polls
# all three ACP backends on a configurable interval and detects jobs that
# transition into a terminal state. On each transition:
#   - appends a formatted report to <session>.pending (drained by
#     inject-pending.sh on the user's next message)
#   - fans out the same report to notify-telegram.sh for AFK push
#
# The watcher runs forever — it does NOT exit after firing. This is the
# Option B design: no asyncRewake wake, no re-arming needed; notifications
# accumulate in the pending file until the next user turn delivers them.
#
# Env vars:
#   ACP_BRIDGE_WATCH_INTERVAL     — seconds between polls (default 30)
#   ACP_CLIENT_BIN                — override bundled acp-client path
#   ACP_BRIDGE_TELEGRAM_CHAT_ID   — if set, forward reports via Telegram
#   ACP_BRIDGE_WATCHER_SESSION_ID — explicit session id (bypasses stdin JSON),
#                                   used by inject-pending.sh when respawning
#                                   a crashed watcher

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

INTERVAL="${ACP_BRIDGE_WATCH_INTERVAL:-30}"

# Prefer explicit env (respawn path) over stdin JSON (hook spawn path).
session_id="${ACP_BRIDGE_WATCHER_SESSION_ID:-}"
if [ -z "$session_id" ]; then
  session_id=$(read_session_id_from_stdin)
fi
[ -z "$session_id" ] && exit 0
[ -x "$ACP_CLIENT_BIN" ] || exit 0

mkdir -p "$STATE_DIR"
session_paths "$session_id"

# Single-instance guard via atomic-create PID file. `set -C` (noclobber)
# makes `> file` fail if the file already exists — kernel-atomic via
# open(2) O_CREAT|O_EXCL. We intentionally do NOT use flock: its locks
# are fd-associated, and bash's $(...) subshells inherit open fds, so a
# subshell spawned mid-poll can keep a lock alive briefly after the main
# watcher exits — blocking a fresh spawn.
#
# Race: between a winner's create and its echo, a loser's read can see
# an empty PID file. We retry-read for up to 500ms before classifying
# the lock as stale.
if ! (set -C; echo $$ > "$SESSION_PID_FILE") 2>/dev/null; then
  existing_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    existing_pid=$(cat "$SESSION_PID_FILE" 2>/dev/null || true)
    [ -n "$existing_pid" ] && break
    sleep 0.05
  done
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    exit 0
  fi
  # Holder is dead — take over the stale PID file.
  echo $$ > "$SESSION_PID_FILE"
fi

# Temp file from the current poll iteration — the trap must clean it up
# if SIGTERM arrives mid-loop.
TMP_CURRENT=""

cleanup_and_exit() {
  [ -n "$TMP_CURRENT" ] && rm -f "$TMP_CURRENT"
  rm -f "$SESSION_PID_FILE"
  exit 0
}
trap cleanup_and_exit TERM INT

# snapshot_jobs: emit one line per (backend, job_id) pair in the format
#   backend:job_id:status
# plus one synthetic `backend:__probed__:ok` marker per backend whose
# bridge responded. Backends with a down/errored bridge are absent from
# the snapshot entirely.
#
# The __probed__ marker is load-bearing: the diff below only fires for
# backends present in BOTH snapshots' probed set. Without it, a bridge
# coming up mid-session (or an empty-baseline startup) would fire
# discovery of every historical job as a "new" terminal transition.
snapshot_jobs() {
  local b output
  for b in "${BACKENDS[@]}"; do
    # timeout guards against a hung bridge socket freezing the loop.
    output=$(timeout 10 "$ACP_CLIENT_BIN" --backend "$b" jobs 2>/dev/null || true)
    [ -z "$output" ] && continue
    echo "${b}:__probed__:ok"
    BACKEND="$b" python3 -c '
import os, sys
backend = os.environ["BACKEND"]
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 2:
        continue
    job_id, status = parts[0], parts[1]
    if not job_id.startswith("job_"):
        continue
    print(f"{backend}:{job_id}:{status.lower()}")
' <<<"$output"
  done | sort -u
}

# Establish baseline — no reports on the first snapshot, only on diffs.
snapshot_jobs > "$SESSION_LASTJOBS_FILE"

while true; do
  sleep "$INTERVAL"

  TMP_CURRENT=$(mktemp)
  snapshot_jobs > "$TMP_CURRENT"

  report=$(LAST_FILE="$SESSION_LASTJOBS_FILE" CURR_FILE="$TMP_CURRENT" python3 <<'PY'
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
curr_jobs, _ = parse(os.environ["CURR_FILE"])

transitions = []
for (backend, job_id), curr_status in curr_jobs.items():
    # Suppress first-observation fires — a backend must have been
    # probed in the PREVIOUS snapshot for its transitions to count.
    if backend not in last_probed:
        continue
    if curr_status not in TERMINAL:
        continue
    if last_jobs.get((backend, job_id)) != curr_status:
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

  mv "$TMP_CURRENT" "$SESSION_LASTJOBS_FILE"
  TMP_CURRENT=""

  [ -z "$report" ] && continue

  # Queue for in-session injection. Blank line separates stacked reports.
  printf '%s\n\n' "$report" >> "$SESSION_PENDING_FILE"

  # Fire Telegram (best-effort; never fails the watcher).
  if [ -x "$PLUGIN_ROOT/scripts/notify-telegram.sh" ]; then
    printf '%s\n' "$report" | "$PLUGIN_ROOT/scripts/notify-telegram.sh" 2>/dev/null || true
  fi
done
