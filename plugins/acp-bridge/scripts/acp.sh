#!/usr/bin/env bash
# acp.sh — shared dispatcher for the acp-bridge Claude Code plugin.
# Invoked from each slash command in ../commands/*.md.
#
# Usage: acp.sh <subcommand> [arguments...]

set -euo pipefail

# shellcheck source=_lib.sh
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

if [ ! -x "$ACP_CLIENT_BIN" ]; then
  echo "acp-bridge: client not found or not executable: $ACP_CLIENT_BIN" >&2
  echo "The plugin ships with a bundled client at $DEFAULT_ACP_CLIENT_BIN." >&2
  echo "Override with ACP_CLIENT_BIN if you want a different binary." >&2
  exit 127
fi

if [ "$#" -lt 1 ]; then
  echo "acp.sh: missing subcommand" >&2
  exit 2
fi

SUBCOMMAND="$1"
shift
# Slash commands pass "$ARGUMENTS" as one quoted argument, so $# is typically 0 or 1.
ARGS="${*:-}"

track_invocation() {
  # Append the backend to the session state file. Called for every bridge
  # touch so session-end cleanup knows which bridges this session used.
  #
  # We track backend only (not per-workspace): acp-client bridges are
  # global singletons per backend; --workspace just scopes working dir.
  #
  # Always append — the consumer (session-hook.sh end) reads with
  # `sort -u`, so duplicates are free and avoiding the check dodges a
  # TOCTOU window between concurrent slash commands.
  local backend="$1"
  if [ -z "${CLAUDE_ACP_SESSION_FILE:-}" ] || [ ! -f "$CLAUDE_ACP_SESSION_FILE" ]; then
    return 0
  fi
  printf '%s\n' "$backend" >> "$CLAUDE_ACP_SESSION_FILE"
}

split_backend_and_text() {
  # Populates BACKEND and TEXT from $1. Splits on any run of whitespace
  # (space or tab) and trims surrounding whitespace from both halves.
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  if [ -z "$raw" ]; then
    BACKEND=""
    TEXT=""
    return
  fi
  if [[ "$raw" =~ ^([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
    BACKEND="${BASH_REMATCH[1]}"
    TEXT="${BASH_REMATCH[2]}"
  else
    BACKEND="$raw"
    TEXT=""
  fi
}

invalid_backend_exit() {
  echo "acp-bridge: invalid backend '$1' (expected $(backends_display))" >&2
  exit 2
}

run_info_command() {
  # Subcommands where an empty backend means "run for all three".
  local sub="$1"
  if [ -z "$ARGS" ]; then
    for b in "${BACKENDS[@]}"; do
      echo "## $b"
      track_invocation "$b"
      "$ACP_CLIENT_BIN" --backend "$b" "$sub" || true
      echo
    done
  else
    is_valid_backend "$ARGS" || invalid_backend_exit "$ARGS"
    track_invocation "$ARGS"
    "$ACP_CLIENT_BIN" --backend "$ARGS" "$sub"
  fi
}

run_backend_only_command() {
  # Subcommands where a backend argument is required (close, reset).
  local sub="$1"
  if [ -z "$ARGS" ]; then
    echo "Usage: /acp-$sub <backend>" >&2
    exit 2
  fi
  is_valid_backend "$ARGS" || invalid_backend_exit "$ARGS"
  track_invocation "$ARGS"
  "$ACP_CLIENT_BIN" --backend "$ARGS" "$sub"
}

run_backend_and_text_command() {
  # Subcommands requiring both a backend and free-form text (prompt, resume,
  # pick, new, submit, job-status, follow).
  local sub="$1"
  local usage_text="$2"
  split_backend_and_text "$ARGS"
  if [ -z "$BACKEND" ] || [ -z "$TEXT" ]; then
    echo "Usage: /acp-$sub <backend> $usage_text" >&2
    exit 2
  fi
  is_valid_backend "$BACKEND" || invalid_backend_exit "$BACKEND"
  track_invocation "$BACKEND"
  "$ACP_CLIENT_BIN" --backend "$BACKEND" "$sub" "$TEXT"
}

case "$SUBCOMMAND" in
  status|sessions|jobs)
    run_info_command "$SUBCOMMAND"
    ;;
  close|reset)
    run_backend_only_command "$SUBCOMMAND"
    ;;
  prompt|resume|pick|new|submit)
    run_backend_and_text_command "$SUBCOMMAND" "<text>"
    ;;
  job-status|follow)
    run_backend_and_text_command "$SUBCOMMAND" "<job-id>"
    ;;
  *)
    echo "acp-bridge: unknown subcommand '$SUBCOMMAND'" >&2
    exit 2
    ;;
esac
