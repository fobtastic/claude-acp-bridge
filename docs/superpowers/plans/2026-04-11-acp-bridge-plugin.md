# acp-bridge Claude Code Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a portable Claude Code plugin that wraps `~/agent-extensions/acp-tool` so both the user and the model can invoke the ACP bridge (Gemini/Qwen/Codex) via slash commands.

**Architecture:** Local git repo at `~/projects/claude-acp-bridge/` containing a Claude Code marketplace + single plugin. Twelve slash commands (`/acp-status`, `/acp-sessions`, `/acp-prompt`, `/acp-resume`, `/acp-pick`, `/acp-new`, `/acp-submit`, `/acp-close`, `/acp-reset`, `/acp-jobs`, `/acp-job-status`, `/acp-follow`) are thin markdown wrappers that delegate to a single shared bash helper `scripts/acp.sh`. The helper resolves the ACP tool via `ACP_TOOL_BIN` env var (default `$HOME/agent-extensions/acp-tool`) so the plugin is portable across machines with different layouts.

**Design refinement vs spec:** The spec left open whether to inline bash in each `.md` file or use a helper script. This plan uses a **shared helper script** (`scripts/acp.sh`) from the start — it keeps each command file trivial, DRY-ifies argument parsing, and matches the openai-codex plugin's pattern. The spec mentioned this as a possible follow-up; we're doing it immediately because the complexity cost is zero.

**Tech Stack:** Claude Code plugin system, Bash, Markdown with frontmatter, git. No runtime dependencies — the plugin only calls an existing binary.

**Testing approach:** No automated test framework (we're wrapping an existing CLI). Each task includes:
1. **Direct bash test** — run `scripts/acp.sh` from the terminal, verify the right command is invoked. Fast feedback, no Claude Code restart required.
2. **Integration smoke test** — after registering the plugin, invoke the slash command from Claude Code. Slower (needs plugin reload) but tests the full path.

Direct bash tests run after every script change; integration smoke tests run after registration and after significant changes.

---

## File Structure

### Files to create in the new repo (`~/projects/claude-acp-bridge/`)

| Path | Purpose |
|---|---|
| `.gitignore` | Ignore OS/editor cruft |
| `LICENSE` | MIT license |
| `README.md` | Install instructions + env var docs + command reference |
| `.claude-plugin/marketplace.json` | Marketplace manifest (declares the one plugin) |
| `plugins/acp-bridge/.claude-plugin/plugin.json` | Plugin manifest |
| `plugins/acp-bridge/scripts/acp.sh` | Shared bash helper — argument parsing and `acp-tool` invocation |
| `plugins/acp-bridge/commands/acp-status.md` | `/acp-status [backend]` |
| `plugins/acp-bridge/commands/acp-sessions.md` | `/acp-sessions [backend]` |
| `plugins/acp-bridge/commands/acp-prompt.md` | `/acp-prompt <backend> <text>` |
| `plugins/acp-bridge/commands/acp-resume.md` | `/acp-resume <backend> <text>` |
| `plugins/acp-bridge/commands/acp-pick.md` | `/acp-pick <backend> <text>` |
| `plugins/acp-bridge/commands/acp-new.md` | `/acp-new <backend> <text>` |
| `plugins/acp-bridge/commands/acp-submit.md` | `/acp-submit <backend> <text>` |
| `plugins/acp-bridge/commands/acp-close.md` | `/acp-close <backend>` |
| `plugins/acp-bridge/commands/acp-reset.md` | `/acp-reset <backend>` |
| `plugins/acp-bridge/commands/acp-jobs.md` | `/acp-jobs [backend]` |
| `plugins/acp-bridge/commands/acp-job-status.md` | `/acp-job-status <backend> <job-id>` |
| `plugins/acp-bridge/commands/acp-follow.md` | `/acp-follow <backend> <job-id>` |
| `docs/superpowers/specs/2026-04-11-acp-bridge-plugin-design.md` | Design doc (already exists) |
| `docs/superpowers/plans/2026-04-11-acp-bridge-plugin.md` | This file (already exists) |

### Host files to modify (not in the repo)

| Path | Change |
|---|---|
| `~/.claude/plugins/known_marketplaces.json` | Register local marketplace (if CLI rejects local path) |
| `~/.claude/plugins/installed_plugins.json` | Register installed plugin (if CLI rejects local path) |
| `~/.claude/settings.json` | Add `"acp-bridge@claude-acp-bridge": true` to `enabledPlugins` |

The exact registration path depends on whether `claude plugin marketplace add <local-path>` is supported — Task 7 determines this empirically.

---

## Task 1: Initialize git repo with personal identity

**Files:**
- Create: `~/projects/claude-acp-bridge/.gitignore`
- Git config: repo-local `user.email` and `user.name`

- [ ] **Step 1.1: Verify the project directory exists and is empty of git state**

Run:
```bash
cd ~/projects/claude-acp-bridge
ls -la
test ! -d .git && echo "no git yet, good" || echo "git already initialized — check before proceeding"
```

Expected: `docs/` directory present (contains spec + this plan), no `.git` directory.

- [ ] **Step 1.2: Initialize git repo**

Run:
```bash
cd ~/projects/claude-acp-bridge
git init -b main
```

Expected: `Initialized empty Git repository in /home/ubuntu/projects/claude-acp-bridge/.git/`

- [ ] **Step 1.3: Set per-repo identity to fobtastic (personal)**

Run:
```bash
cd ~/projects/claude-acp-bridge
git config user.email fobtastic.chris@gmail.com
git config user.name "Chris Tou"
git config --get user.email
git config --get user.name
```

Expected output:
```
fobtastic.chris@gmail.com
Chris Tou
```

Memory note: user has dual git identities (onramplab work = global default, fobtastic personal = per-repo override). Confirmed in `~/.claude/projects/-home-ubuntu/memory/user_git_accounts.md`.

- [ ] **Step 1.4: Create `.gitignore`**

Write `~/projects/claude-acp-bridge/.gitignore`:
```
# OS
.DS_Store
Thumbs.db

# Editors
.vscode/
.idea/
*.swp
*~

# Node (in case we add scripts later)
node_modules/
```

- [ ] **Step 1.5: Stage and commit**

Run:
```bash
cd ~/projects/claude-acp-bridge
git add .gitignore docs/
git status
git commit -m "Initial: design doc + implementation plan"
```

Expected: one commit created with the spec, plan, and .gitignore. Author should show as `Chris Tou <fobtastic.chris@gmail.com>`. Verify with:
```bash
git log --format="%an <%ae>" -1
```
Expected: `Chris Tou <fobtastic.chris@gmail.com>`

---

## Task 2: Write marketplace manifest

**Files:**
- Create: `~/projects/claude-acp-bridge/.claude-plugin/marketplace.json`

- [ ] **Step 2.1: Create directory**

Run:
```bash
mkdir -p ~/projects/claude-acp-bridge/.claude-plugin
```

- [ ] **Step 2.2: Write marketplace.json**

Write `~/projects/claude-acp-bridge/.claude-plugin/marketplace.json`:
```json
{
  "name": "claude-acp-bridge",
  "owner": {
    "name": "fobtastic"
  },
  "metadata": {
    "description": "Personal Claude Code plugin: ACP bridge wrapper for Gemini, Qwen, and Codex",
    "version": "0.1.0"
  },
  "plugins": [
    {
      "name": "acp-bridge",
      "description": "Persistent ACP bridge for Gemini, Qwen, and Codex via ~/agent-extensions/acp-tool",
      "version": "0.1.0",
      "author": {
        "name": "Chris Tou"
      },
      "source": "./plugins/acp-bridge"
    }
  ]
}
```

- [ ] **Step 2.3: Validate JSON**

Run:
```bash
python3 -m json.tool ~/projects/claude-acp-bridge/.claude-plugin/marketplace.json > /dev/null && echo ok
```

Expected: `ok`

---

## Task 3: Write plugin manifest

**Files:**
- Create: `~/projects/claude-acp-bridge/plugins/acp-bridge/.claude-plugin/plugin.json`

- [ ] **Step 3.1: Create directory**

Run:
```bash
mkdir -p ~/projects/claude-acp-bridge/plugins/acp-bridge/.claude-plugin
```

- [ ] **Step 3.2: Write plugin.json**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/.claude-plugin/plugin.json`:
```json
{
  "name": "acp-bridge",
  "version": "0.1.0",
  "description": "Persistent ACP bridge for Gemini, Qwen, and Codex backends via ~/agent-extensions/acp-tool. Set ACP_TOOL_BIN to override the default path.",
  "author": {
    "name": "Chris Tou",
    "email": "fobtastic.chris@gmail.com"
  }
}
```

- [ ] **Step 3.3: Validate JSON**

Run:
```bash
python3 -m json.tool ~/projects/claude-acp-bridge/plugins/acp-bridge/.claude-plugin/plugin.json > /dev/null && echo ok
```

Expected: `ok`

---

## Task 4: Write the shared bash helper

**Files:**
- Create: `~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh`

This script is the heart of the plugin. Every slash command delegates to it. It handles:
- ACP tool path resolution (`$ACP_TOOL_BIN` with default)
- Argument parsing (subcommand + backend + optional text)
- Default behavior when no backend is given (iterate all three for info commands; error for action commands)
- Clear usage errors

- [ ] **Step 4.1: Create scripts directory**

Run:
```bash
mkdir -p ~/projects/claude-acp-bridge/plugins/acp-bridge/scripts
```

- [ ] **Step 4.2: Write `scripts/acp.sh`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh`:
```bash
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

split_backend_and_text() {
  # Populates BACKEND and TEXT from $1.
  local raw="$1"
  # Trim leading whitespace.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  if [ -z "$raw" ]; then
    BACKEND=""
    TEXT=""
    return
  fi
  BACKEND="${raw%% *}"
  if [ "$BACKEND" = "$raw" ]; then
    TEXT=""
  else
    TEXT="${raw#* }"
  fi
}

run_info_command() {
  # Subcommands where an empty backend means "run for all three".
  local sub="$1"
  if [ -z "$ARGS" ]; then
    for b in "${BACKENDS_ALL[@]}"; do
      echo "## $b"
      "$BIN" --backend "$b" "$sub" || true
      echo
    done
  else
    if ! is_valid_backend "$ARGS"; then
      echo "acp-bridge: invalid backend '$ARGS' (expected gemini, qwen, or codex)" >&2
      exit 2
    fi
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
```

- [ ] **Step 4.3: Make the script executable**

Run:
```bash
chmod +x ~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh
ls -l ~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh
```

Expected: `-rwxrwxr-x` (or similar with execute bits).

- [ ] **Step 4.4: Lint with bash -n**

Run:
```bash
bash -n ~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh && echo ok
```

Expected: `ok`

- [ ] **Step 4.5: Direct bash test — usage errors**

Run:
```bash
cd ~
~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh prompt 2>&1 || true
```

Expected stderr:
```
Usage: /acp-prompt <backend> <text>
```
Exit code: 2

Run:
```bash
~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh close 2>&1 || true
```

Expected stderr:
```
Usage: /acp-close <backend>
```
Exit code: 2

Run:
```bash
~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh status notabackend 2>&1 || true
```

Expected stderr contains: `invalid backend 'notabackend'`
Exit code: 2

- [ ] **Step 4.6: Direct bash test — status against real acp-tool**

Run:
```bash
~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh status gemini 2>&1
```

Expected: JSON or plain output from `gemini-acp-bridge status`. Should not error about missing binary (binary exists per Task-0 exploration). Exit code 0.

Run:
```bash
~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh status 2>&1
```

Expected: three sections (`## gemini`, `## qwen`, `## codex`) each followed by the bridge's status output for that backend.

If either of these fails with a "tool not found" error, verify `~/agent-extensions/acp-tool` still exists and is executable, and that `$HOME` is set in the test shell.

- [ ] **Step 4.7: Commit**

Run:
```bash
cd ~/projects/claude-acp-bridge
git add .claude-plugin/ plugins/acp-bridge/.claude-plugin/ plugins/acp-bridge/scripts/
git status
git commit -m "Add marketplace, plugin manifest, and shared bash helper"
```

Expected: one commit with three files (marketplace.json, plugin.json, acp.sh).

---

## Task 5: Write the first slash command (`/acp-status`)

**Files:**
- Create: `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-status.md`

This is the template for all 12 commands. We build and verify one end-to-end before replicating.

- [ ] **Step 5.1: Create commands directory**

Run:
```bash
mkdir -p ~/projects/claude-acp-bridge/plugins/acp-bridge/commands
```

- [ ] **Step 5.2: Write `acp-status.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-status.md`:
```markdown
---
description: Show ACP bridge status for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" status $ARGUMENTS`

Render the output to the user. If no backend was passed, three sections (`## gemini`, `## qwen`, `## codex`) are present — display each backend's status on its own line in a compact one-line summary per backend where possible. If a single backend was passed, show its output as-is.
```

**Note on `$ARGUMENTS` quoting:** Claude Code substitutes `$ARGUMENTS` literally before executing the command. If we wrap it in double quotes (`"$ARGUMENTS"`), an empty argument list yields `""` which is passed as a literal empty string — our helper handles that. Leaving it unquoted means no args become zero positional args, which is also fine for our helper's `${*:-}` handling. We leave it **unquoted** here so that multi-word arguments split correctly at the shell level; the helper re-joins them. (For commands where the text matters as a single string — e.g., `/acp-prompt` — we still pass unquoted and let the helper's `split_backend_and_text` carve out just the first word as backend and the rest as text.)

- [ ] **Step 5.3: Commit**

Run:
```bash
cd ~/projects/claude-acp-bridge
git add plugins/acp-bridge/commands/acp-status.md
git commit -m "Add /acp-status command"
```

---

## Task 6: Register the plugin with Claude Code locally

This task has branching logic: we try the preferred path first (`claude plugin marketplace add <local-path>`) and fall back if unsupported.

**Files potentially modified:**
- `~/.claude/plugins/known_marketplaces.json`
- `~/.claude/plugins/installed_plugins.json`
- `~/.claude/settings.json`

- [ ] **Step 6.1: Attempt the official CLI path**

Run:
```bash
claude plugin marketplace add ~/projects/claude-acp-bridge 2>&1
```

Three possible outcomes:

**A — success:** output indicates the marketplace was added. Then run:
```bash
claude plugin install acp-bridge@claude-acp-bridge 2>&1
```
Expected: the plugin is installed and `~/.claude/settings.json` gets an `enabledPlugins["acp-bridge@claude-acp-bridge"] = true` entry. Skip to Step 6.3.

**B — CLI rejects local path:** error mentions "only github sources supported" or similar. Proceed to Step 6.2 (manual registration).

**C — `claude plugin` command unknown:** the Claude Code version doesn't have this CLI. Proceed to Step 6.2.

Record the outcome and which path was taken in a comment above the README task later.

- [ ] **Step 6.2: Manual registration (fallback)**

Only perform this step if 6.1 did NOT succeed via the CLI.

Symlink the repo into the marketplaces directory:
```bash
ln -sfn ~/projects/claude-acp-bridge ~/.claude/plugins/marketplaces/claude-acp-bridge
ls -la ~/.claude/plugins/marketplaces/claude-acp-bridge
```

Expected: symlink visible pointing at `~/projects/claude-acp-bridge`.

Add to `~/.claude/plugins/known_marketplaces.json`. First back it up, then edit:
```bash
cp ~/.claude/plugins/known_marketplaces.json ~/.claude/plugins/known_marketplaces.json.bak
```

Using Claude Code's Edit tool (not sed), add a new entry before the closing `}`:
```json
"claude-acp-bridge": {
  "source": {
    "source": "local",
    "path": "/home/ubuntu/projects/claude-acp-bridge"
  },
  "installLocation": "/home/ubuntu/.claude/plugins/marketplaces/claude-acp-bridge",
  "lastUpdated": "2026-04-11T00:00:00.000Z"
}
```

Validate JSON:
```bash
python3 -m json.tool ~/.claude/plugins/known_marketplaces.json > /dev/null && echo ok
```
Expected: `ok`. If not, restore from backup and investigate.

Add entry to `~/.claude/plugins/installed_plugins.json` under `plugins`:
```bash
cp ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.bak
```

Add:
```json
"acp-bridge@claude-acp-bridge": [
  {
    "scope": "user",
    "installPath": "/home/ubuntu/projects/claude-acp-bridge/plugins/acp-bridge",
    "version": "0.1.0",
    "installedAt": "2026-04-11T00:00:00.000Z",
    "lastUpdated": "2026-04-11T00:00:00.000Z"
  }
]
```

Validate:
```bash
python3 -m json.tool ~/.claude/plugins/installed_plugins.json > /dev/null && echo ok
```

Finally, enable the plugin in `~/.claude/settings.json`. Back up first:
```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak
```

Using Edit tool, add inside `enabledPlugins`:
```json
"acp-bridge@claude-acp-bridge": true
```

Validate:
```bash
python3 -m json.tool ~/.claude/settings.json > /dev/null && echo ok
```

- [ ] **Step 6.3: Verify files on disk**

Run:
```bash
cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('enabled:', d.get('enabledPlugins', {}).get('acp-bridge@claude-acp-bridge'))"
```

Expected: `enabled: True`

Run:
```bash
cat ~/.claude/plugins/known_marketplaces.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('marketplace:', 'claude-acp-bridge' in d)"
```

Expected: `marketplace: True`

- [ ] **Step 6.4: Pause for user to reload Claude Code**

**STOP HERE** and tell the user:

> "Plugin registered. Please **restart Claude Code** (quit and reopen, or reload the session) so the new plugin is picked up. Reply when ready to smoke-test `/acp-status`."

Do not proceed to Task 7 until the user confirms the restart.

---

## Task 7: Integration smoke test

- [ ] **Step 7.1: Verify the command is visible**

After user restart, I (the assistant) invoke the slash command directly. Call `/acp-status gemini` from within the conversation.

Expected: bridge status output appears. Failure modes and remediation:
- "Unknown command" → plugin not loaded; check `enabledPlugins` and marketplace registration again; may need Claude Code CLI restart, not just session reload.
- "Permission denied" / prompt for Bash — accept once; this is normal first-use behavior.
- "tool not found" → `$HOME` mismatch or `acp-tool` not executable. Investigate `~/agent-extensions/acp-tool`.

- [ ] **Step 7.2: Run `/acp-status` with no args**

Expected: three sections for gemini, qwen, codex.

- [ ] **Step 7.3: Document outcome**

If Task 6.1 (CLI path) worked, record it for the README. If fallback 6.2 was needed, record that too.

---

## Task 8: Write the remaining 11 command files

All follow the same template as `acp-status.md`, differing only in:
- `description` frontmatter
- `argument-hint` frontmatter
- The subcommand passed to `acp.sh`
- The guidance paragraph after the bash invocation

Each command file ends with a short instruction telling Claude how to render the output — preserving structure, not re-summarizing, etc.

- [ ] **Step 8.1: Write `acp-sessions.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-sessions.md`:
```markdown
---
description: List ACP sessions for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" sessions $ARGUMENTS`

Render the output. If no backend was passed, three sections are present — summarize each backend's session count on its own line, then list the first few sessions if space allows.
```

- [ ] **Step 8.2: Write `acp-prompt.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-prompt.md`:
```markdown
---
description: Send a prompt to a persistent ACP session (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" prompt $ARGUMENTS`

Present the bridge response to the user verbatim. Do not re-summarize or paraphrase — the user is interacting with another agent and wants to see exactly what it said.
```

- [ ] **Step 8.3: Write `acp-resume.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-resume.md`:
```markdown
---
description: Resume an ACP session with a new prompt (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" resume $ARGUMENTS`

Present the bridge response verbatim. Do not summarize.
```

- [ ] **Step 8.4: Write `acp-pick.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-pick.md`:
```markdown
---
description: Pick an ACP session interactively and send a prompt (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" pick $ARGUMENTS`

Present the bridge response verbatim. Do not summarize.
```

- [ ] **Step 8.5: Write `acp-new.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-new.md`:
```markdown
---
description: Start a new ACP session with an initial prompt (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" new $ARGUMENTS`

Present the bridge response verbatim. Do not summarize.
```

- [ ] **Step 8.6: Write `acp-submit.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-submit.md`:
```markdown
---
description: Submit a prompt as a background ACP job (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" submit $ARGUMENTS`

Present the bridge response verbatim. Note the returned job ID — it can be inspected with `/acp-job-status` or streamed with `/acp-follow`.
```

- [ ] **Step 8.7: Write `acp-close.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-close.md`:
```markdown
---
description: Close the ACP bridge for a given backend
argument-hint: '<backend>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" close $ARGUMENTS`

Report whether the close succeeded. If the backend argument was missing, surface the usage error to the user and suggest rerunning with a backend name.
```

- [ ] **Step 8.8: Write `acp-reset.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-reset.md`:
```markdown
---
description: Reset ACP bridge state for a given backend
argument-hint: '<backend>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" reset $ARGUMENTS`

Report whether the reset succeeded. If the backend argument was missing, surface the usage error to the user and suggest rerunning with a backend name.
```

- [ ] **Step 8.9: Write `acp-jobs.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-jobs.md`:
```markdown
---
description: List background ACP jobs for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" jobs $ARGUMENTS`

Render the output. If no backend was passed, three sections are present — show each backend's jobs on its own line group. If there are no jobs, say so concisely.
```

- [ ] **Step 8.10: Write `acp-job-status.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-job-status.md`:
```markdown
---
description: Show ACP job status. Usage: /acp-job-status <backend> <job-id>
argument-hint: '<backend> <job-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" job-status $ARGUMENTS`

Present the job status output. Surface the phase, elapsed time, and any actionable fields.
```

- [ ] **Step 8.11: Write `acp-follow.md`**

Write `~/projects/claude-acp-bridge/plugins/acp-bridge/commands/acp-follow.md`:
```markdown
---
description: Follow ACP job output until completion. Usage: /acp-follow <backend> <job-id>
argument-hint: '<backend> <job-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" follow $ARGUMENTS`

The bash command blocks until the job finishes and then returns all accumulated output. Present it verbatim. Note: Claude Code slash commands do not stream, so the user sees output only at completion — this is a known limitation vs the equivalent pi-coding-agent widget.
```

- [ ] **Step 8.12: Smoke-test each command via direct bash**

Run:
```bash
for sub in sessions prompt resume pick new submit close reset jobs job-status follow; do
  echo "--- $sub (expect usage error) ---"
  ~/projects/claude-acp-bridge/plugins/acp-bridge/scripts/acp.sh "$sub" 2>&1 || true
done
```

Expected: each line either shows a usage error (for commands that require args: prompt/resume/pick/new/submit/close/reset/job-status/follow), or shows the three-backend output (for info commands: sessions/jobs).

- [ ] **Step 8.13: Commit**

Run:
```bash
cd ~/projects/claude-acp-bridge
git add plugins/acp-bridge/commands/
git status
git commit -m "Add remaining 11 slash commands"
```

Expected: one commit with 11 new files.

---

## Task 9: Write README.md and LICENSE

**Files:**
- Create: `~/projects/claude-acp-bridge/README.md`
- Create: `~/projects/claude-acp-bridge/LICENSE`

- [ ] **Step 9.1: Write LICENSE (MIT)**

Write `~/projects/claude-acp-bridge/LICENSE`:
```
MIT License

Copyright (c) 2026 Chris Tou

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 9.2: Write README.md**

Write `~/projects/claude-acp-bridge/README.md`. Content should include:
- Title and one-line description
- What this plugin does (one paragraph — wraps `~/agent-extensions/acp-tool` for Claude Code)
- Prerequisites (`acp-tool` binary at `$HOME/agent-extensions/acp-tool` or override with `ACP_TOOL_BIN`)
- Install instructions for the two paths:
  - **Preferred:** `claude plugin marketplace add fobtastic/claude-acp-bridge` then `claude plugin install acp-bridge@claude-acp-bridge`
  - **Local dev:** clone repo and either use the CLI with local path or symlink into `~/.claude/plugins/marketplaces/`
- Full command reference table (name, args, one-line description — same content as the argument table in the spec)
- Environment variables (`ACP_TOOL_BIN`)
- Known limitations (`/acp-follow` returns output at completion, no live stream)
- License

Use the content from the spec and the command files as source material. Target ~150–250 lines of markdown.

- [ ] **Step 9.3: Commit**

Run:
```bash
cd ~/projects/claude-acp-bridge
git add README.md LICENSE
git commit -m "Add README and MIT LICENSE"
```

---

## Task 10: Final end-to-end verification

- [ ] **Step 10.1: Verify file tree**

Run:
```bash
cd ~/projects/claude-acp-bridge
find . -type f -not -path './.git/*' | sort
```

Expected output (17 files):
```
./.claude-plugin/marketplace.json
./.gitignore
./LICENSE
./README.md
./docs/superpowers/plans/2026-04-11-acp-bridge-plugin.md
./docs/superpowers/specs/2026-04-11-acp-bridge-plugin-design.md
./plugins/acp-bridge/.claude-plugin/plugin.json
./plugins/acp-bridge/commands/acp-close.md
./plugins/acp-bridge/commands/acp-follow.md
./plugins/acp-bridge/commands/acp-job-status.md
./plugins/acp-bridge/commands/acp-jobs.md
./plugins/acp-bridge/commands/acp-new.md
./plugins/acp-bridge/commands/acp-pick.md
./plugins/acp-bridge/commands/acp-prompt.md
./plugins/acp-bridge/commands/acp-reset.md
./plugins/acp-bridge/commands/acp-resume.md
./plugins/acp-bridge/commands/acp-sessions.md
./plugins/acp-bridge/commands/acp-status.md
./plugins/acp-bridge/commands/acp-submit.md
./plugins/acp-bridge/scripts/acp.sh
```

(That's 19 including spec + plan; adjust count when counting.)

- [ ] **Step 10.2: Verify git log and authorship**

Run:
```bash
cd ~/projects/claude-acp-bridge
git log --format="%h %an <%ae> %s"
```

Expected: 4 commits, all authored by `Chris Tou <fobtastic.chris@gmail.com>`:
1. Initial: design doc + implementation plan
2. Add marketplace, plugin manifest, and shared bash helper
3. Add /acp-status command
4. Add remaining 11 slash commands
5. Add README and MIT LICENSE

(5 commits if we include this plan revision commit; count may differ.)

- [ ] **Step 10.3: Integration smoke test of multiple commands**

Invoke from within this Claude Code session:
- `/acp-status` (expect all three backends)
- `/acp-status gemini` (expect single-backend output)
- `/acp-sessions gemini`
- `/acp-jobs`

Each should return output from the bridge without errors.

- [ ] **Step 10.4: Report outcome**

Summarize to the user:
- Which registration path worked (6.1 CLI success or 6.2 manual fallback)
- Which commands were verified end-to-end
- What's deferred (GitHub publish, any follow-up refinements)

---

## Task 11: Publish to GitHub (deferred, user-gated)

Only run this task after the user says they're ready to publish. GitHub repo creation under the personal account is separate from the local plugin working.

- [ ] **Step 11.1: Confirm fobtastic GitHub auth is available**

Ask the user to confirm they want to publish AND that `gh auth status` or `git push` will route to the fobtastic account. If they're unsure, help them verify:
```bash
gh auth status 2>&1
```
or
```bash
ssh -T git@github.com 2>&1
```

If routing is ambiguous (e.g., gh CLI logged in as onramplab), pause and ask the user how they normally publish to fobtastic — SSH config alias, `GH_HOST`, `GH_TOKEN`, or per-repo remote URL with a user-specific host alias.

- [ ] **Step 11.2: Create the GitHub repo**

Preferred (via gh CLI):
```bash
gh repo create fobtastic/claude-acp-bridge --public --source ~/projects/claude-acp-bridge --remote origin --push
```

If gh is wrong-account: fall back to creating the repo in the GitHub web UI, then:
```bash
cd ~/projects/claude-acp-bridge
git remote add origin git@github.com:fobtastic/claude-acp-bridge.git
git push -u origin main
```

- [ ] **Step 11.3: Verify the push**

Run:
```bash
cd ~/projects/claude-acp-bridge
git log origin/main --format="%h %an %s" -5
```

Expected: commits are visible on the remote.

- [ ] **Step 11.4: Update README install instructions**

Once the repo exists, verify the README's "preferred install" instructions (`claude plugin marketplace add fobtastic/claude-acp-bridge`) actually work on another machine if possible, or leave a note that they're untested.

---

## Self-review notes

**Spec coverage check:**
- ✅ Goal (wrap acp-tool, model + user invocation, portable, fobtastic account) — Tasks 1, 2, 4, 5, 8, 11
- ✅ Non-goals respected (no reimpl, no streaming widget, no JSON mode, no interactive picker) — explicitly noted in Task 4 and command rendering instructions
- ✅ Architecture — repo layout matches spec exactly except for the addition of `scripts/acp.sh` (documented as a refinement in the plan header)
- ✅ Environment variable override (`ACP_TOOL_BIN`) — Task 4 (script) + README in Task 9
- ✅ Installation flow — Task 6 (local) + Task 11 (GitHub publish)
- ✅ Testing plan — Task 4 direct bash + Task 7 & 10 integration + smoke-test loop in Task 8.12
- ✅ Risks — addressed: local marketplace fallback (Task 6.2), `$ARGUMENTS` parsing via helper script (Task 4), `/acp-follow` limitation documented in Task 8.11 command and README
- ✅ Open decisions deferred to implementation — Task 6.1 determines marketplace registration mechanism; Task 9.2 README will document whichever works

**Placeholder scan:** No TBDs; every code block is complete; every command reference resolves to a task. The one soft area is README content in Task 9.2 — I described the sections rather than giving exact text, because the install path is only known after Task 6 completes. Acceptable.

**Type/name consistency:**
- `acp.sh` subcommands (status/sessions/prompt/resume/pick/new/submit/close/reset/jobs/job-status/follow) match `acp-tool --help` output verified in brainstorming
- Command file names (`acp-*.md`) match the slash command names exactly
- `ACP_TOOL_BIN` used consistently in Task 4 script and Task 9 README

No issues found.
