#!/usr/bin/env bash
# acp.sh — shared dispatcher for the acp-bridge Claude Code plugin.
# Invoked from each slash command in ../commands/*.md.
#
# Usage: acp.sh <subcommand> [arguments...]
#
# Resolves the ACP tool path from $ACP_TOOL_BIN (default: $HOME/agent-extensions/acp-tool),
# parses the remaining arguments according to the subcommand's conventions, and invokes
# the underlying bridge.

set -euo pipefail

BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"
BACKENDS_ALL=(gemini qwen codex)

if [ ! -x "$BIN" ]; then
  echo "acp-bridge: tool not found or not executable: $BIN" >&2
  echo "Set ACP_TOOL_BIN or install to \$HOME/agent-extensions/acp-tool" >&2
  exit 127
fi

if [ "$#" -lt 1 ]; then
  echo "acp.sh: missing subcommand" >&2
  exit 2
fi

SUBCOMMAND="$1"
shift

# Collapse all remaining args back into a single string. Slash commands pass
# "$ARGUMENTS" as one quoted argument, so $# is typically 0 or 1 here.
ARGS="${*:-}"

is_valid_backend() {
  case "$1" in
    gemini|qwen|codex) return 0 ;;
    *) return 1 ;;
  esac
}

track_invocation() {
  # Append <backend> to the session state file, if tracking is active.
  # No-op outside a Claude Code session.
  #
  # NOTE: We track backend only (not (backend, workspace)) because acp-tool
  # bridges are global singletons per backend — --workspace only affects the
  # working directory for commands, not the bridge process identity. Closing
  # "the gemini bridge at workspace X" is the same as closing "the gemini
  # bridge".
  local backend="$1"
  if [ -z "${CLAUDE_ACP_SESSION_FILE:-}" ]; then
    return 0
  fi
  if [ ! -f "$CLAUDE_ACP_SESSION_FILE" ]; then
    return 0
  fi
  if ! grep -qxF "$backend" "$CLAUDE_ACP_SESSION_FILE" 2>/dev/null; then
    printf '%s\n' "$backend" >> "$CLAUDE_ACP_SESSION_FILE"
  fi
}

split_backend_and_text() {
  # Populates BACKEND and TEXT from $1. Splits on any run of whitespace
  # (space or tab) and trims surrounding whitespace from both halves.
  local raw="$1"
  # Trim leading whitespace.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  # Trim trailing whitespace.
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

run_info_command() {
  # Subcommands where an empty backend means "run for all three".
  local sub="$1"
  if [ -z "$ARGS" ]; then
    for b in "${BACKENDS_ALL[@]}"; do
      echo "## $b"
      track_invocation "$b"
      "$BIN" --backend "$b" "$sub" || true
      echo
    done
  else
    if ! is_valid_backend "$ARGS"; then
      echo "acp-bridge: invalid backend '$ARGS' (expected gemini, qwen, or codex)" >&2
      exit 2
    fi
    track_invocation "$ARGS"
    "$BIN" --backend "$ARGS" "$sub"
  fi
}

run_backend_only_command() {
  # Subcommands where a backend argument is required (close, reset).
  local sub="$1"
  if [ -z "$ARGS" ]; then
    echo "Usage: /acp-$sub <backend>" >&2
    exit 2
  fi
  if ! is_valid_backend "$ARGS"; then
    echo "acp-bridge: invalid backend '$ARGS' (expected gemini, qwen, or codex)" >&2
    exit 2
  fi
  track_invocation "$ARGS"
  "$BIN" --backend "$ARGS" "$sub"
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
  if ! is_valid_backend "$BACKEND"; then
    echo "acp-bridge: invalid backend '$BACKEND' (expected gemini, qwen, or codex)" >&2
    exit 2
  fi
  track_invocation "$BACKEND"
  "$BIN" --backend "$BACKEND" "$sub" "$TEXT"
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
