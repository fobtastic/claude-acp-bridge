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
  rm -f "$SESSION_PID_FILE" "$SESSION_WATCHER_HEALTH"
  exit 0
}
trap cleanup_and_exit TERM INT

# snapshot_jobs: emit one tab-separated line per (backend, job_id) pair:
#   backend \t job_id \t status \t prompt_summary
# plus one synthetic `backend \t __probed__ \t ok \t` marker per backend
# whose bridge responded. Backends with a down/errored bridge are absent
# from the snapshot entirely.
#
# The __probed__ marker is load-bearing: the diff below only fires for
# backends present in BOTH snapshots' probed set. Without it, a bridge
# coming up mid-session (or an empty-baseline startup) would fire
# discovery of every historical job as a "new" terminal transition.
#
# Tab is used as the delimiter because prompt text can contain colons
# and other ASCII punctuation but is unlikely to contain tabs (and we
# strip any that sneak through in the parser).
snapshot_jobs() {
  local b output
  for b in "${BACKENDS[@]}"; do
    output=$(timeout 10 "$ACP_CLIENT_BIN" --workspace "$ACP_WORKSPACE" --backend "$b" jobs 2>/dev/null || true)
    [ -z "$output" ] && continue
    printf '%s\t__probed__\tok\t\n' "$b"
    BACKEND="$b" python3 -c '
import os, sys
backend = os.environ["BACKEND"]
# Columns from `acp-client jobs`: JOB_ID STATUS CREATED_AT PROMPT...
# `split(maxsplit=3)` keeps the prompt (which may contain spaces) intact.
for line in sys.stdin:
    parts = line.rstrip("\n").split(maxsplit=3)
    if len(parts) < 2:
        continue
    job_id, status = parts[0], parts[1]
    if not job_id.startswith("job_"):
        continue
    prompt = parts[3] if len(parts) >= 4 else ""
    # Sanitize: strip tabs (our field separator) and collapse whitespace.
    prompt = " ".join(prompt.replace("\t", " ").split())
    if len(prompt) > 80:
        prompt = prompt[:77] + "..."
    print(f"{backend}\t{job_id}\t{status.lower()}\t{prompt}")
' <<<"$output"
  done | sort -u
}

# Establish baseline — no reports on the first snapshot, only on diffs.
snapshot_jobs > "$SESSION_LASTJOBS_FILE"

while true; do
  sleep "$INTERVAL"

  TMP_CURRENT=$(mktemp)
  snapshot_jobs > "$TMP_CURRENT"

  # Write watcher health file atomically (Feature 2: observability).
  health_tmp=$(mktemp)
  HEALTH_FILE="$SESSION_WATCHER_HEALTH" CURR_FILE="$TMP_CURRENT" python3 -c '
import json, os, time

curr_file = os.environ["CURR_FILE"]
health_file = os.environ["HEALTH_FILE"]
poll_results = {}
try:
    with open(curr_file) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[1] == "__probed__":
                backend = parts[0]
                poll_results[backend] = {"ok": True, "jobCount": 0, "error": None}
            elif len(parts) >= 3 and parts[1].startswith("job_"):
                backend = parts[0]
                if backend in poll_results:
                    poll_results[backend]["jobCount"] += 1
except Exception:
    pass

health = {"timestamp": time.time(), "pollResults": poll_results, "errors": []}
with open(health_file + ".tmp", "w") as f:
    json.dump(health, f)
os.replace(health_file + ".tmp", health_file)
' 2>/dev/null || true

  report=$(LAST_FILE="$SESSION_LASTJOBS_FILE" CURR_FILE="$TMP_CURRENT" ACP_CLIENT_BIN="$ACP_CLIENT_BIN" ACP_WORKSPACE="$ACP_WORKSPACE" python3 <<'PY'
import os

TERMINAL = {"completed", "succeeded", "failed", "error", "cancelled", "canceled", "done"}

def parse(path):
    # Returns (jobs, probed) where jobs maps (backend, job_id) -> (status, prompt).
    jobs = {}
    probed = set()
    try:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                backend, key, status = parts[0], parts[1], parts[2]
                prompt = parts[3] if len(parts) >= 4 else ""
                if key == "__probed__":
                    probed.add(backend)
                else:
                    jobs[(backend, key)] = (status, prompt)
    except FileNotFoundError:
        pass
    return jobs, probed

last_jobs, last_probed = parse(os.environ["LAST_FILE"])
curr_jobs, _ = parse(os.environ["CURR_FILE"])

transitions = []
for (backend, job_id), (curr_status, prompt) in curr_jobs.items():
    # Suppress first-observation fires — a backend must have been
    # probed in the PREVIOUS snapshot for its transitions to count.
    if backend not in last_probed:
        continue
    if curr_status not in TERMINAL:
        continue
    last_entry = last_jobs.get((backend, job_id))
    last_status = last_entry[0] if last_entry else None
    if last_status != curr_status:
        transitions.append((backend, job_id, curr_status, prompt))

if transitions:
    import re, subprocess as sp, json

    acp_client = os.environ.get("ACP_CLIENT_BIN", "")
    acp_workspace = os.environ.get("ACP_WORKSPACE", ".")

    def get_job_details(backend: str, job_id: str) -> dict:
        """Query job-status for elapsed time and event count."""
        if not acp_client:
            return {}
        try:
            out = sp.run(
                [acp_client, "--workspace", acp_workspace, "--backend", backend, "job-status", job_id],
                capture_output=True, text=True, timeout=10,
            )
            if out.returncode == 0 and out.stdout.strip():
                return json.loads(out.stdout)
        except Exception:
            pass
        return {}

    def format_elapsed(started: float, completed: float) -> str:
        secs = int(completed - started)
        if secs < 60:
            return f"{secs}s"
        mins, secs = divmod(secs, 60)
        return f"{mins}m{secs:02d}s"

    def summarize_prompt(text: str, max_len: int = 60) -> str:
        """Turn a raw prompt into a concise task summary."""
        if not text:
            return ""
        text = " ".join(text.split())
        text = re.sub(
            r"^(You are (performing |doing |implementing |conducting )?|"
            r"Please |I want you to |I need you to |I'd like you to )",
            "", text, count=1, flags=re.IGNORECASE,
        ).strip()
        text = re.sub(r"^(a |an |the )", "", text, count=1, flags=re.IGNORECASE)
        if text and text[0].isupper():
            text = text[0].lower() + text[1:]
        if len(text) > max_len:
            text = text[: max_len - 3].rstrip() + "..."
        return text

    lines = []
    for b, jid, s, prompt in transitions:
        details = get_job_details(b, jid)
        summary = summarize_prompt(prompt)
        elapsed_str = ""
        events_str = ""
        if details.get("startedAt") and details.get("completedAt"):
            elapsed_str = f" in {format_elapsed(details['startedAt'], details['completedAt'])}"
        event_count = details.get("eventCount")
        if event_count:
            events_str = f" ({event_count} events)"
        meta = f"{elapsed_str}{events_str}"

        if s in ("completed", "succeeded", "done"):
            lines.append(f"✓ {b} completed{meta}: {summary}" if summary else f"✓ {b} completed{meta}")
        elif s in ("failed", "error"):
            lines.append(f"✗ {b} failed{meta}: {summary}" if summary else f"✗ {b} failed{meta}")
        elif s in ("cancelled", "canceled"):
            lines.append(f"⊘ {b} cancelled{meta}: {summary}" if summary else f"⊘ {b} cancelled{meta}")
        else:
            lines.append(f"  {b} {s}{meta}: {summary}" if summary else f"  {b} {s}{meta}")
        lines.append(f"  /acp-follow {b} {jid}")
        lines.append("")
    print("\n".join(lines).rstrip())
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
