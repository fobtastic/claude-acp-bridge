# claude-acp-bridge

A personal [Claude Code](https://claude.ai/code) plugin that gives Claude Code direct access to [ACP](https://github.com/zed-industries/agent-client-protocol) backends — Gemini, Qwen, and Codex — via a persistent bridge. Lets you delegate long-running tasks to another agent, walk away, and be notified when the work is done.

## What this plugin does

- **Bundles its own ACP client** (`plugins/acp-bridge/bin/acp-client`, a single-file Python 3 stdlib implementation) — no separate install step needed for the bridge itself
- Wraps the bundled client in 12 Claude Code slash commands that manage persistent Gemini / Qwen / Codex sessions
- Both you and Claude (the model) can invoke any command — slash commands are model-invokable by default
- **Smart session lifecycle**: idle bridges get closed on session end, but bridges with in-flight background jobs are preserved so long-running work survives a Claude Code restart
- **Background job watcher (daemon mode)**: a long-lived poller runs for the entire session, queues completion reports to a pending file, fires Telegram pings instantly, and injects queued reports into the model's context on your next message via a `UserPromptSubmit` hook. Handles unlimited job completions per session with no restart required.
- **Self-healing**: if the watcher daemon crashes, it's automatically respawned on your next turn
- Portable across machines — install the plugin and everything including the client comes with it

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI installed
- **Python 3.9+** in `$PATH` (the bundled `acp-client` is a pure-stdlib Python script)
- **`curl`** in `$PATH` (used by the Telegram helper)
- **The external backend CLIs you want to use**, installed and authenticated separately:
  - `gemini` — for the gemini backend
  - `qwen` — for the qwen backend
  - `codex` — for the codex backend

  You only need the CLI(s) for backends you actually use. The plugin's `acp-client` shells out to whichever of these are on your `$PATH`.
- Optional: the [Claude Code Telegram plugin](https://github.com/anthropics/claude-plugins-official) configured (for AFK notifications — see [Telegram setup](#telegram-notifications-optional))

## Install

### From GitHub (once published)

```bash
claude plugin marketplace add fobtastic/claude-acp-bridge
claude plugin install acp-bridge@claude-acp-bridge
```

Restart Claude Code. The 12 `/acp-*` slash commands, the lifecycle hooks, and the bundled `acp-client` binary will all load automatically — no separate ACP tool install step.

### From a local clone

```bash
git clone https://github.com/fobtastic/claude-acp-bridge.git ~/projects/claude-acp-bridge
claude plugin marketplace add ~/projects/claude-acp-bridge
claude plugin install acp-bridge@claude-acp-bridge
```

Restart Claude Code.

### Verify

Run `/acp-status` from within a Claude Code session. You should see a status report for all three backends (running / not running, socket paths, active jobs).

## Command reference

All commands accept an optional `[backend]` or `<backend>` argument as `gemini`, `qwen`, or `codex`. Commands marked with `$ARGUMENTS` accept free-form text after the backend name.

| Command | Args | What it does |
|---|---|---|
| `/acp-status` | `[backend]` | Show bridge status. No arg → all three backends. |
| `/acp-sessions` | `[backend]` | List ACP sessions. No arg → all three. |
| `/acp-prompt` | `<backend> <text>` | Send a synchronous prompt to the current session. Blocks until the backend responds. |
| `/acp-resume` | `<backend> <text>` | Resume the latest session with a new prompt. |
| `/acp-pick` | `<backend> <text>` | Pick a session interactively and send a prompt. |
| `/acp-new` | `<backend> <text>` | Start a fresh session with an initial prompt. |
| `/acp-submit` | `<backend> <text>` | Submit a prompt as a **background job**. Returns a job ID immediately; the backend keeps working after you disconnect. This is the command for autonomous delegation. |
| `/acp-jobs` | `[backend]` | List background jobs. |
| `/acp-job-status` | `<backend> <job-id>` | Inspect one job's status (queued / running / completed / failed). |
| `/acp-follow` | `<backend> <job-id>` | Wait for a job to finish and return its full output. Blocking. |
| `/acp-close` | `<backend>` | Close a bridge (stop the backing process). |
| `/acp-reset` | `<backend>` | Reset bridge state. |

**Model invocation:** by default these are model-invokable, meaning Claude can call them autonomously during a conversation. For example, you can say "check on the qwen job from earlier" and Claude will run `/acp-jobs qwen` itself.

## Core workflow: autonomous delegation to Qwen/Gemini/Codex

The headline feature. Use this when you have a well-defined task that another agent can execute autonomously while you work on something else or walk away entirely.

### 1. Write a plan

Use Claude Code's `superpowers:writing-plans` skill (or write one manually) to produce a detailed task-by-task plan. The more specific, the better — backends execute instructions literally, not interpretively.

Save the plan to a file inside the target repo, e.g., `docs/plans/feature-x.md`.

### 2. Submit the plan as a background job

```
/acp-submit qwen "Workspace: ~/projects/my-repo
Branch: create and work on 'qwen/feature-x'
Plan: docs/plans/feature-x.md

Execute the plan task by task. For each task:
1. Read the task fully
2. Implement exactly what it specifies (no scope creep)
3. Run tests as the plan describes
4. Commit with a message referencing the task number
5. Move to the next task

Stop and report if:
- Tests fail and you can't fix them in 2 attempts
- The plan has a contradiction or missing dependency
- You need a decision that isn't in the plan

When all tasks are done, run the full test suite and report PASS/FAIL with a summary."
```

`/acp-submit` returns a job ID immediately. Qwen starts executing in the background. The `activeJobs` counter on the qwen bridge bumps to 1.

### 3. Walk away (or work on something else)

**Quit Claude Code, close your laptop, whatever.** The plugin's `SessionEnd` hook queries each backend's `activeJobs` count before shutting down:

- `activeJobs > 0` → leave the bridge alone, log `skipping qwen — 1 active jobs` to stderr
- `activeJobs == 0` → close the idle bridge (clean, releases memory)

Your qwen job keeps running. Bridges from workspaces you didn't touch this session aren't affected.

### 4. Come back and check

When you reopen Claude Code:

```
/acp-jobs qwen           # list all jobs, with status
/acp-job-status qwen <id> # detailed status of one job
/acp-follow qwen <id>    # block until the job finishes, return full output
```

Or — with the [background watcher](#background-job-watcher) running — you'll get a notification inside your Claude Code session on your next message after qwen finishes.

### 5. (Optional) AFK notifications to your phone

Set up [Telegram notifications](#telegram-notifications-optional) and your phone will buzz when a job completes. You still have to come back to Claude Code to read the full output or steer the next iteration, but you'll know *when* to come back.

## Session lifecycle and smart cleanup

ACP bridges are **persistent singleton processes** — one gemini bridge, one qwen bridge, one codex bridge per machine, regardless of which workspace you invoke them from. If you invoke `/acp-prompt` from workspace A and later from workspace B, you're talking to the same bridge process.

Without cleanup, these bridges would accumulate indefinitely. The plugin tracks which backends you touch in a session and applies smart cleanup on `SessionEnd`:

- For each backend used this session, query its `activeJobs` count
- If `activeJobs > 0`: **leave it alone** (background work in flight)
- If `activeJobs == 0`: **close the bridge** (release memory)

Per-session state files live in `~/.cache/claude-acp-bridge/sessions/`:

| File | Purpose |
|---|---|
| `<session>.list` | Backends touched this session (one per line) |
| `<session>.lastjobs` | Watcher's job snapshot for transition diffing |
| `<session>.watcher.pid` | PID of the running watcher daemon |
| `<session>.pending` | Queued completion reports awaiting the next user turn |
| `<session>.pending.inflight` | Transient — drained-but-not-yet-injected reports |

All are removed on `SessionEnd`.

### Known cleanup limitations

- **Cross-session interference**: because bridges are global singletons, any Claude Code session's `SessionEnd` can close a backend used by another concurrent session. The `activeJobs > 0` guard protects background jobs but not in-flight synchronous prompts from other sessions. Recovery is automatic — next use respawns the bridge.
- **External bridges aren't tracked**: bridges started outside Claude Code (e.g., by the pi-coding-agent extension) aren't cleaned up by this plugin. Intentional.
- **State file leaks on crash**: if Claude Code terminates abnormally, the state file is orphaned. Harmless — next `SessionStart` creates a fresh one.

## Background job watcher

The plugin spawns a long-lived background poller at `SessionStart` (via an asyncRewake hook used purely as a "spawn-and-forget" vehicle — no wake-on-exit semantics). It runs for the entire session:

1. Polls `acp-client --backend <b> jobs` for all three backends every 30 seconds (configurable via `ACP_BRIDGE_WATCH_INTERVAL`)
2. Compares snapshots to detect terminal transitions (any job → completed / succeeded / failed / error / cancelled / done)
3. When a transition is detected:
   - **Appends** a formatted report to `~/.cache/claude-acp-bridge/sessions/<session_id>.pending`
   - **Immediately** fires a Telegram push to your phone (if configured) — this is instant, not deferred
   - **Keeps polling** — the watcher is a true daemon, it does not exit after firing
4. On your next message to Claude, a `UserPromptSubmit` hook (`inject-pending.sh`) atomically drains the pending file and injects its contents into your turn via `hookSpecificOutput.additionalContext`, which Claude Code shows as a system reminder. All queued completions between your last message and now deliver in one block.

### Delivery timing

| Event | Telegram (instant) | In-session reminder |
|---|---|---|
| Job 1 finishes while you're typing | ✅ phone buzzes | queued |
| Job 2 finishes while you're still typing | ✅ phone buzzes | queued |
| You send any message to Claude | — | ✅ both reports delivered as one reminder |
| Watcher daemon crashes | — | — |
| You send next message | — | inject-pending.sh **respawns** the watcher automatically (self-healing) |

Notifications never arrive "mid-turn" while Claude is already responding — that would be disruptive. Telegram is the real-time channel; the in-session path is eventual-consistent, delivered on your next turn boundary.

### Limitations

- **Injection latency = your next-message gap**: if a job finishes and you don't type anything to Claude for an hour, the in-session reminder is delayed by that hour. Telegram bridges the gap for AFK notifications.
- **No progress updates**: only terminal transitions notify. A job that's been running for an hour is silent until it finishes. If you need intermediate status, invoke `/acp-job-status <backend> <id>` manually.

## Configuration

All configuration is via environment variables. Set them in your shell profile or Claude Code's env config.

| Variable | Default | Purpose |
|---|---|---|
| `ACP_CLIENT_BIN` | `<plugin>/bin/acp-client` | Path to the ACP client binary. Defaults to the bundled client; override only if you want to point at a different implementation. |
| `ACP_WORKSPACE` | `$PWD` (caller's cwd) | Workspace root the backend should operate on. Default is the current Claude Code session's working directory. Override when you want to dispatch work from one repo to a backend that should act on a different repo — e.g. `ACP_WORKSPACE=/path/to/other/repo /acp-submit qwen "..."`. The bridge updates its `workspaceRoot` on every prompt/submit/resume/new/pick request, so you can target different workspaces across successive invocations. |
| `ACP_BRIDGE_WATCH_INTERVAL` | `30` | Watcher poll interval in seconds |
| `ACP_BRIDGE_TELEGRAM_CHAT_ID` | *(unset)* | If set, watcher posts job-completion messages to this Telegram chat ID |
| `TELEGRAM_BOT_TOKEN` | *(auto)* | Telegram bot token. If unset, read from `~/.claude/channels/telegram/.env` (reuses the Claude Code Telegram plugin's bot) |

## Telegram notifications (optional)

### How it works

When the [background watcher](#background-job-watcher) detects a completed/failed job, it pipes the notification to `scripts/notify-telegram.sh`, which POSTs to the Telegram Bot API via `curl`. Your phone then buzzes with a message from the bot.

This is **one-way** (bot → you). To respond to Qwen, Gemini, or Codex from the notification, you still have to open Claude Code and invoke a slash command. The Telegram plugin does receive inbound replies when `channelsEnabled: true` is set in your Claude Code settings, but that's a separate flow that feeds your replies back into an active Claude Code session — not a way to directly drive ACP bridges from Telegram.

### Setup

1. **Configure the Claude Code Telegram plugin** first — see that plugin's docs for how to pair a bot and approve your chat. Once paired, `~/.claude/channels/telegram/.env` will contain `TELEGRAM_BOT_TOKEN=...`.

2. **Find your Telegram chat ID.** The easiest way: message [@userinfobot](https://t.me/userinfobot) on Telegram and it'll reply with your numeric ID. Or, after sending a message to your paired bot, run:

   ```bash
   curl -sS "https://api.telegram.org/bot$(grep TELEGRAM_BOT_TOKEN ~/.claude/channels/telegram/.env | cut -d= -f2-)/getUpdates" | python3 -m json.tool
   ```

   and look for the `chat.id` field in the most recent update.

3. **Export the chat ID** in your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

   ```bash
   export ACP_BRIDGE_TELEGRAM_CHAT_ID=123456789
   ```

4. **Restart Claude Code** so the watcher inherits the env var.

5. **Test**: submit a short job via `/acp-submit gemini "reply with the word done"` and watch your phone.

### Multi-session gotcha

The Claude Code Telegram plugin runs one MCP server instance per Claude Code process and uses Telegram's long-polling (`getUpdates`), which only allows **one active consumer per bot**. If you run two Claude Code sessions concurrently, they fight over the bot, only one receives inbound messages at a time, and reply routing is non-deterministic. Outbound posting (watcher → Telegram) works fine from any session because it's a direct POST.

**Workaround:** use one Claude Code session at a time, or run a dedicated bot for the acp-bridge notifier and keep a separate bot for interactive chat with Claude.

## Not implemented (v0.1 explicit non-goals)

- **Live streaming of `/acp-follow` output** — Claude Code slash commands can't stream; you see the full output only when the job finishes. Manual polling via `/acp-job-status` is the workaround.
- **Interactive backend pickers** — slash commands require the backend argument; no UI popup like the pi-coding-agent extension.
- **JSON event mode** (`--no-plain`) — plain text only for legibility.
- **Direct Telegram → ACP interaction** — you can't drive Qwen/Gemini/Codex directly from a Telegram chat. Would require a standalone daemon independent of Claude Code. See the project roadmap in the design doc.
- **Cross-session job ownership** — the watcher notifies on any backend transition, not just "jobs this session submitted." Polling all three backends is the Option Y trade-off documented in the design.

## Development

- **Design doc**: `docs/superpowers/specs/2026-04-11-acp-bridge-plugin-design.md`
- **Implementation plan**: `docs/superpowers/plans/2026-04-11-acp-bridge-plugin.md`
- **Key files**:
  - `plugins/acp-bridge/bin/acp-client` — **the bundled ACP client** (single-file Python 3 stdlib implementation; ~1700 lines). Handles the ACP protocol, per-backend Unix-socket RPC, session state, and background job lifecycle. Shells out to external `gemini` / `qwen` / `codex` CLIs for the actual model calls.
  - `plugins/acp-bridge/commands/*.md` — the 12 slash command definitions
  - `plugins/acp-bridge/scripts/acp.sh` — shared argument parser and dispatcher that invokes the bundled client
  - `plugins/acp-bridge/scripts/session-hook.sh` — SessionStart / SessionEnd handler (tracking + smart cleanup)
  - `plugins/acp-bridge/scripts/job-watcher.sh` — long-lived daemon poller that queues transition reports and fires Telegram
  - `plugins/acp-bridge/scripts/inject-pending.sh` — UserPromptSubmit hook that drains queued reports into the model's context and self-heals the watcher
  - `plugins/acp-bridge/scripts/notify-telegram.sh` — Telegram Bot API helper (HTML-formatted, plain-text-safe)
  - `plugins/acp-bridge/hooks/hooks.json` — hook registration (SessionStart, UserPromptSubmit, SessionEnd)

## License

MIT. See [LICENSE](./LICENSE).
