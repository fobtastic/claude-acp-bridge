# Feature Backlog

Prioritized by value-per-effort. Sourced from codex's round-3 review (2026-04-12).

## Priority 1 — Small effort, high daily-use value

### 1. `/acp-doctor` — diagnostic command
**What**: One-shot health check: backend CLI availability, socket health, bridge pid/state, watcher liveness, cache permissions, Telegram config.
**Why**: Daily use fails in boring environmental ways (expired auth, missing npx, dead watcher, wrong chat id). Saves spelunking through cache dirs and logs.
**Sketch**: Add `doctor` action to `bin/acp-client` (probe each backend socket, check CLI in PATH, check watcher PID, check Telegram env); add `scripts/acp.sh` dispatch; add `commands/acp-doctor.md`.
**Effort**: small (< 1 day)
**Risk**: False negatives if backend CLIs are slow or interactive; keep checks bounded with timeouts.

### 2. Watcher health and observability
**What**: Track watcher heartbeat, last poll time, per-backend poll errors, last notification error, last delivered pending report.
**Why**: The watcher is intentionally quiet — nice until it silently stops being useful. This gives `/acp-status` something actionable when things go wrong.
**Sketch**: Have `job-watcher.sh` write `<session>.watcher.json` atomically each poll (timestamp, poll results, errors); surface it via `/acp-status` or a new `/acp-watch-status`.
**Effort**: small
**Risk**: More state files and minor races; use atomic temp-file replace.

### 3. Better notification payloads
**What**: Include elapsed time, workspace basename, job id, final status, and a short output/error tail in Telegram and injected reminders.
**Why**: "Something finished" is less useful than "X in /repo/a finished in 4m with 127 lines of output."
**Sketch**: Query `job-status` from `job-watcher.sh` on each transition (before report formatting); update the transition report template; keep under Telegram's 4096-char limit.
**Effort**: small
**Risk**: Pulling job status adds ~200ms per transition per backend to the watcher loop; acceptable since it only happens on transitions.

### 4. Non-plain JSON event mode in slash commands
**What**: Surface the existing `--no-plain` client mode through commands.
**Why**: Debugging ACP backends is much easier when tool calls, usage updates, and raw events are visible structurally.
**Sketch**: Either add `/acp-prompt-json`, `/acp-follow-json` command variants, or parse a leading `--json` flag in `acp.sh` and pass `--no-plain` to the client.
**Effort**: small
**Risk**: Flag parsing must not break free-form prompts (flag appears before backend name).

## Priority 2 — Medium effort, significant capability gap

### 5. Job cancellation and pruning
**What**: `/acp-cancel <backend> <job-id>` and `/acp-prune <backend> [--completed] [--older-than N]`.
**Why**: Long-running delegated work needs an escape hatch; completed job JSON accumulates forever on disk.
**Sketch**: Add `cancel_job` and `prune_jobs` server actions; keep task handles for live jobs; mark canceled jobs terminal; optionally reset the backend if canceling the active prompt can't be cleanly propagated. Add command files + README.
**Effort**: medium (1-3 days)
**Risk**: Canceling an active ACP prompt may require killing/restarting the backend process; regression surface is job lifecycle and session continuity.

### 6. Durable, bounded job logs
**What**: Store large job output in append-only per-job log files with capped metadata in JSON; add `/acp-tail <backend> <job-id> [n]`.
**Why**: Fixes the practical pain of collecting a big result after walking away. Also partially addresses the "large job response exceeds socket buffer" issue (pagination helps, but streaming logs is the proper long-term fix).
**Sketch**: Change `PromptJob.append_event()` / `save_job()` to spill chunk and terminal text to `jobs/<id>.log`; keep event summaries and offsets in JSON; add paginated `job_events` and a `tail_job` action.
**Effort**: medium
**Risk**: Migration from existing job JSON format; `/acp-follow` output compat.

### 7. Session/job ownership filters
**What**: Record Claude session id, workspace, and submission time on each job; let the watcher notify only for jobs owned by the current session by default, with an `--all` mode.
**Why**: Multi-session use makes notifications noisy and sometimes misleading (cross-session interference is a documented limitation today).
**Sketch**: Export `CLAUDE_ACP_SESSION_ID` in `session-hook.sh start`; pass through `acp.sh` to submit payloads; extend `PromptJob`; filter watcher snapshots by owner unless configured otherwise.
**Effort**: medium
**Risk**: Existing jobs lack owner metadata; default them to "legacy/global" to avoid hiding them unexpectedly.

## Priority 3 — Larger scope, future consideration

### 8. Permission monitoring enhancement: command-specific policies
**What**: Build on the permission monitoring feature to support fine-grained command policies (not just path patterns).
**Why**: Currently `--always` on a shell command creates an overly broad rule. The fix plan addresses the immediate bug, but a richer policy DSL (command prefixes, regex patterns, workspace-scoped rules) would make the trust model more useful for real multi-repo delegation.
**Sketch**: Extend `commandPattern` to support prefixes (`npm *`), add `workspacePattern`, add a `/acp-policy add` command for manually creating rules without first encountering a permission request.
**Effort**: medium-large
**Risk**: Policy DSL complexity; hard to test all matching edge cases.

### 9. Safer backend command profiles
**What**: Make backend launch commands fully configurable (replace hardcoded `--yolo` and specific flags).
**Why**: With permission monitoring in place (once bugs are fixed), the `--yolo` flag becomes optional. But different workspaces may want different safety profiles. A bridge that other agents can drive should not force maximum-permission mode.
**Sketch**: Add env vars `ACP_GEMINI_COMMAND`, `ACP_QWEN_COMMAND`, `ACP_CODEX_COMMAND` or a small JSON config; parse with `shlex.split`; document safe/default/aggressive profiles.
**Effort**: small (config reading) to medium (testing all combinations)
**Risk**: Quoting config commands is easy to get wrong; prefer JSON arrays.

---

## Dependency graph

```
Permission monitoring fixes (docs/plans/permission-monitoring-fixes.md)
  |
  v
Feature #1 (/acp-doctor) — independent, can ship anytime
Feature #2 (watcher observability) — independent
Feature #3 (better notifications) — independent
Feature #4 (JSON event mode) — independent
Feature #5 (job cancellation) — independent
Feature #6 (durable logs) — benefits from pagination fix already in place
Feature #7 (session ownership) — builds on Fix 2 (CLAUDE_ACP_SESSION_ID export)
Feature #8 (policy DSL) — requires permission monitoring fixes first
Feature #9 (backend profiles) — requires permission monitoring working
```

## Status

- [x] Permission monitoring v1 shipped (a5d412f)
- [ ] Permission monitoring fixes planned (017663d) — next session
- [ ] Feature backlog documented (this file)
- [ ] Features 1-9 not started
