# acp-bridge Claude Code plugin — design

**Date:** 2026-04-11
**Status:** Draft for review
**Owner:** Chris Tou (fobtastic)

## Goal

Give Claude Code access to the persistent ACP bridge at `~/agent-extensions/acp-tool` (which wraps `gemini-acp-bridge` for Gemini, Qwen, and Codex backends), mirroring the functionality of the existing pi-coding-agent extension at `~/.pi/agent/extensions/acp-bridge-tool.ts`.

The result should be:

1. **Usable by Claude (me) autonomously** — so I can invoke the bridge as a tool during conversations.
2. **Usable by the user interactively** via slash commands.
3. **Portable across machines** via a git repo, auto-loaded on startup.
4. **Published under the user's personal (fobtastic) GitHub account**, not the work (onramplab) account.
5. **Smart lifecycle cleanup** — ACP bridges touched during a Claude Code session should be closed on session end *only if they are idle* (no active background jobs). Long-running `/acp-submit` jobs must survive session termination so the user can quit and come back.

## Amendment 2026-04-11 — Session lifecycle hooks

After initial implementation, added a session-lifecycle feature to prevent zombie bridge accumulation across Claude Code sessions in different workspaces.

**Motivation:** ACP bridges are persistent singletons keyed on `(backend, workspace)`. Running `/acp-prompt gemini "foo"` in workspace A and then workspace B leaves two gemini-acp-bridge processes alive indefinitely. Over many Claude Code sessions, these accumulate and consume memory.

**Cleanup policy:** Smart — kill idle bridges, preserve busy ones. On `SessionEnd`, for each `(backend, workspace)` tuple this session touched:

1. Query `acp-tool --backend <b> --workspace <w> status`
2. Parse `activeJobs` from the JSON response
3. If `activeJobs > 0` → leave the bridge running, log to stderr
4. If `activeJobs == 0` → close the bridge, log to stderr

`activeJobs` reflects pending + running background jobs submitted via `/acp-submit`. Synchronous `/acp-prompt` calls don't increment it, but they're always complete by the time `SessionEnd` fires (slash commands are synchronous). Background jobs are exactly the "don't kill my long-running work" case.

**Implementation components:**

- `plugins/acp-bridge/hooks/hooks.json` — declares `SessionStart` and `SessionEnd` hooks invoking a shell script.
- `plugins/acp-bridge/scripts/session-hook.sh` — `start` creates a per-session state file at `~/.cache/claude-acp-bridge/sessions/<session_id>.list` and exports `CLAUDE_ACP_SESSION_FILE` via `$CLAUDE_ENV_FILE` so the plugin's command scripts can see it. `end` reads the state file, applies the smart cleanup policy, removes the file.
- `plugins/acp-bridge/scripts/acp.sh` — modified to append `<backend>\t<$PWD>` to `$CLAUDE_ACP_SESSION_FILE` (dedup via `grep -qxF`) before each bridge invocation. Only active when the env var is set (i.e., inside a Claude Code session); direct shell invocations don't track.

**Known limitations:**

- **Cross-session interference**: if two Claude Code sessions run in the same workspace and one ends while the other has a sync prompt in flight, the first's cleanup can kill the second's bridge mid-call. Rare; recovery is automatic (retry respawns the bridge).
- **Session-scope only**: bridges started outside Claude Code (e.g., by the pi-coding-agent extension) aren't tracked, aren't cleaned up. Intentional — we only manage what we touch.
- **State file leaks on crash**: if Claude Code terminates abnormally without firing `SessionEnd`, the state file is orphaned. Low impact — next `SessionStart` creates a new file, and the orphan is harmless (cleanup on next manual `/acp-close` or a housekeeping sweep could be added later).

## Non-goals

- Reimplementing any of the bridge logic itself. `acp-tool` already does everything; the plugin is a thin wrapper.
- Live streaming UI widgets. The .pi extension has a custom `follow` widget; Claude Code slash commands can only return bash output after the subprocess exits, so `/acp-follow` will return the full accumulated output at completion.
- Interactive backend pickers. The .pi `close`/`reset` pop a UI selector when no backend is passed; the plugin requires the backend as an argument (or defaults to `gemini`) for simplicity.
- JSON event mode (`--no-plain`) in slash commands. Plain text only for legibility. Can be added later if needed.

## Architecture

### Repo layout

```
claude-acp-bridge/                                      (git repo root)
├── .gitignore
├── LICENSE                                             (MIT, user's choice)
├── README.md                                           (install + usage docs)
├── .claude-plugin/
│   └── marketplace.json                                (declares one plugin)
└── plugins/
    └── acp-bridge/
        ├── .claude-plugin/
        │   └── plugin.json                             (plugin manifest)
        └── commands/
            ├── acp-status.md
            ├── acp-sessions.md
            ├── acp-prompt.md
            ├── acp-resume.md
            ├── acp-pick.md
            ├── acp-new.md
            ├── acp-submit.md
            ├── acp-close.md
            ├── acp-reset.md
            ├── acp-jobs.md
            ├── acp-job-status.md
            └── acp-follow.md
```

### Plugin manifest (`plugins/acp-bridge/.claude-plugin/plugin.json`)

```json
{
  "name": "acp-bridge",
  "version": "0.1.0",
  "description": "Persistent ACP bridge for Gemini, Qwen, and Codex backends via ~/agent-extensions/acp-tool",
  "author": { "name": "Chris Tou", "email": "fobtastic.chris@gmail.com" }
}
```

### Marketplace manifest (`.claude-plugin/marketplace.json`)

```json
{
  "name": "claude-acp-bridge",
  "owner": { "name": "fobtastic" },
  "metadata": {
    "description": "Personal Claude Code plugin: ACP bridge for Gemini/Qwen/Codex",
    "version": "0.1.0"
  },
  "plugins": [
    {
      "name": "acp-bridge",
      "description": "Persistent ACP bridge for Gemini, Qwen, and Codex",
      "version": "0.1.0",
      "author": { "name": "Chris Tou" },
      "source": "./plugins/acp-bridge"
    }
  ]
}
```

### Slash commands

Each command is a markdown file with frontmatter that invokes `$ACP_TOOL_BIN` (default: `$HOME/agent-extensions/acp-tool`) via Bash. All commands are left model-invokable (no `disable-model-invocation: true`) so Claude can call them autonomously AND the user can invoke them interactively.

The 12 commands map 1:1 to `acp-tool`'s subcommands: `status`, `sessions`, `prompt`, `resume`, `pick`, `new`, `submit`, `close`, `reset`, `jobs`, `job-status`, `follow`.

**Command argument conventions** (matching the .pi extension):

| Command | Arguments | Notes |
|---|---|---|
| `/acp-status` | `[backend]` | defaults to listing all three backends if no arg |
| `/acp-sessions` | `[backend]` | same |
| `/acp-prompt` | `<backend> <text>` | text required |
| `/acp-resume` | `<backend> <text>` | text required |
| `/acp-pick` | `<backend> <text>` | text required |
| `/acp-new` | `<backend> <text>` | text required |
| `/acp-submit` | `<backend> <text>` | text required |
| `/acp-close` | `<backend>` | backend required |
| `/acp-reset` | `<backend>` | backend required |
| `/acp-jobs` | `[backend]` | |
| `/acp-job-status` | `<backend> <job-id>` | |
| `/acp-follow` | `<backend> <job-id>` | returns full output at completion |

**Example — `acp-status.md`:**

```markdown
---
description: Show ACP bridge status for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"; if [ -n "$ARGUMENTS" ]; then "$BIN" --backend "$ARGUMENTS" status; else for b in gemini qwen codex; do echo "## $b"; "$BIN" --backend "$b" status; echo; done; fi`

Render the output to the user. If the user passed a single backend, show it as-is. If three backends were reported, show each backend's status on its own line in a compact list.
```

**Example — `acp-prompt.md`:**

```markdown
---
description: Send a prompt to a persistent ACP session (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"; BACKEND=$(echo "$ARGUMENTS" | awk '{print $1}'); TEXT=$(echo "$ARGUMENTS" | cut -d' ' -f2-); if [ -z "$BACKEND" ] || [ -z "$TEXT" ]; then echo "Usage: /acp-prompt <backend> <text>" >&2; exit 2; fi; "$BIN" --backend "$BACKEND" prompt "$TEXT"`

Present the bridge response to the user. Preserve its structure; do not re-summarize.
```

The remaining 10 commands follow the same pattern, differing only in the subcommand name and whether text is required.

**Permission note:** `allowed-tools: Bash` (unrestricted Bash) is the simplest declaration. If you'd prefer tighter permissions, we can scope it to `Bash($HOME/agent-extensions/acp-tool:*)` — but that won't match if `ACP_TOOL_BIN` is overridden. A middle ground is `Bash` unrestricted in the plugin and relying on Claude Code's standard permission prompt flow.

### Environment variable override

Every command resolves the tool path as:

```bash
BIN="${ACP_TOOL_BIN:-$HOME/agent-extensions/acp-tool}"
```

Users with non-standard layouts can set `ACP_TOOL_BIN` in their shell profile or Claude Code env config to override. No plugin config file needed.

## Installation & distribution

### Bootstrap on this machine (before GitHub is published)

1. Create the repo at `~/projects/claude-acp-bridge/`:
   ```bash
   mkdir -p ~/projects/claude-acp-bridge
   cd ~/projects/claude-acp-bridge
   git init
   git config user.email fobtastic.chris@gmail.com
   git config user.name "Chris Tou"   # or whatever personal name preferred
   ```
2. Write all files per the layout above.
3. `git add -A && git commit -m "Initial acp-bridge plugin"`
4. Register with Claude Code. Preferred path:
   ```bash
   claude plugin marketplace add ~/projects/claude-acp-bridge
   claude plugin install acp-bridge@claude-acp-bridge
   ```
   If the CLI rejects a local path (some Claude Code versions only accept github sources), fall back to one of:
   - **Symlink into marketplaces dir:**
     ```bash
     ln -s ~/projects/claude-acp-bridge ~/.claude/plugins/marketplaces/claude-acp-bridge
     ```
     then manually add an entry to `~/.claude/plugins/known_marketplaces.json` with `{ "source": { "source": "local", "path": "~/projects/claude-acp-bridge" }, "installLocation": "~/.claude/plugins/marketplaces/claude-acp-bridge" }` and to `enabledPlugins` in `~/.claude/settings.json`.
   - **Publish to GitHub first** (see next section), then register as `github:fobtastic/claude-acp-bridge`.
5. Restart Claude Code. Run `/acp-status gemini` to smoke-test.

During implementation we'll verify which of these actually works in this Claude Code version; the first successful path becomes documented in README.md.

### Publish to GitHub

1. Create `github.com/fobtastic/claude-acp-bridge` (empty, personal account).
2. `git remote add origin git@github.com:fobtastic/claude-acp-bridge.git` (or https with the credential helper routing to the fobtastic account).
3. `git push -u origin main`.

### Install on other machines

```bash
claude plugin marketplace add fobtastic/claude-acp-bridge
claude plugin install acp-bridge@claude-acp-bridge
# optionally: export ACP_TOOL_BIN=/custom/path/to/acp-tool
```

Auto-update is enabled by default for github marketplaces, matching how `openai-codex` and `laravel` are registered today.

## Testing plan

Manual smoke test sequence after install:

1. `/acp-status` → expect all three backends reported (running or not).
2. `/acp-status gemini` → expect single-backend output.
3. Start a gemini session if none exists, then `/acp-sessions gemini` → expect the session listed.
4. `/acp-prompt gemini "respond with the word ready"` → expect a response.
5. `/acp-jobs` → expect job list or empty.
6. `/acp-close gemini` → expect close confirmation.
7. `/acp-reset gemini` → expect reset confirmation.

Each manual test confirms:
- The command is registered and discoverable
- `ACP_TOOL_BIN` resolution works
- Model can invoke the command autonomously (I'll run them from a conversation, not the user's terminal)
- Output rendering is legible

An automated test suite is out of scope for v0.1.0. If the plugin grows, we can add a `tests/` directory with a shell-based harness.

## Risks & unknowns

1. **Local marketplace registration may not be supported** by `claude plugin marketplace add`. Mitigation: fall back to symlink + hand-edited `known_marketplaces.json`, or publish to GitHub first. Both are documented above.
2. **`$ARGUMENTS` parsing** in slash command bash scripts is fragile for multi-word prompts with special characters. Mitigation: the bash snippets use `awk`/`cut` which handles simple cases; for complex prompts users can quote the text. If this becomes a real problem, we switch to `.mjs` helper scripts (matching the openai-codex plugin's pattern) in a follow-up.
3. **`acp-follow` streaming limitation** — slash commands don't stream. Users who want live output still have the .pi widget. Not a regression since we never had this in Claude Code before.
4. **Permission prompt friction** — first invocation of each command will prompt the user to allow Bash. Standard Claude Code behavior; document in README.

## Open decisions deferred to implementation

- Exact marketplace registration mechanism (local path vs symlink vs github-first). Will try `claude plugin marketplace add ~/projects/claude-acp-bridge` first and fall back as needed.
- Whether to use `allowed-tools: Bash` (unrestricted) or `Bash(env:*)` / `Bash(sh:*)` for tighter scoping. Default to unrestricted Bash for v0.1.0.
- README content. Will write after commands work end-to-end so examples are real.

## File inventory to create

- `.gitignore` (node_modules, .DS_Store, etc.)
- `LICENSE` (MIT)
- `README.md` (install + usage + env var docs)
- `.claude-plugin/marketplace.json`
- `plugins/acp-bridge/.claude-plugin/plugin.json`
- `plugins/acp-bridge/commands/acp-status.md`
- `plugins/acp-bridge/commands/acp-sessions.md`
- `plugins/acp-bridge/commands/acp-prompt.md`
- `plugins/acp-bridge/commands/acp-resume.md`
- `plugins/acp-bridge/commands/acp-pick.md`
- `plugins/acp-bridge/commands/acp-new.md`
- `plugins/acp-bridge/commands/acp-submit.md`
- `plugins/acp-bridge/commands/acp-close.md`
- `plugins/acp-bridge/commands/acp-reset.md`
- `plugins/acp-bridge/commands/acp-jobs.md`
- `plugins/acp-bridge/commands/acp-job-status.md`
- `plugins/acp-bridge/commands/acp-follow.md`
- `docs/superpowers/specs/2026-04-11-acp-bridge-plugin-design.md` (this file)

Also, on this machine only (not in the repo):
- Updates to `~/.claude/settings.json` (`enabledPlugins`) and/or `~/.claude/plugins/known_marketplaces.json` to register the local marketplace.
