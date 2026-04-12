# Permission Monitoring - Implementation Plan

**Feature**: Replace auto-approve (--yolo) with a policy-aware permission handler that lets Claude monitor and approve/deny backend permission requests, with progressive trust (approve-once, approve-for-session, approve-always).

**Status**: Plan ready, implementation not started.

## 1. Architecture

```
Backend CLI (gemini/qwen/codex)
    | session/request_permission (structured JSON-RPC)
    v
ACPBridge._handle_permission_request()
    | 1. Check session rules (in-memory) -> auto-resolve if match
    | 2. Check persistent policy file -> auto-resolve if match
    | 3. No match -> queue + block
    v
<session>.permission.pending (file, one JSON line per request)
    | Drained by inject-pending.sh on next UserPromptSubmit
    v
Claude sees: "gemini wants to write /repo/src/foo.ts - approve?"
    | Claude runs /acp-approve or /acp-deny
    v
acp.sh -> acp-client resolve_permission (RPC to bridge)
    | Bridge resolves the asyncio.Future
    | Optionally: create a session or persistent policy rule
    v
Backend CLI resumes
```

## 2. Key Design: Progressive Trust (matching Claude Code's own model)

- `/acp-approve <backend> <request-id>` - approve this one request only
- `/acp-approve <backend> <request-id> --session` - approve AND auto-approve matching requests for this session
- `/acp-approve <backend> <request-id> --always` - approve AND add permanent policy rule
- `/acp-deny <backend> <request-id>` - deny this one request
- `/acp-deny <backend> <request-id> --always` - deny AND add permanent deny rule

Session rules live in-memory (cleared on session end). Permanent rules persist in a policy file.

## 3. Data Structures

### PermissionRequest (queued to pending file)

```json
{
    "requestId": "perm_<uuid12>",
    "backend": "gemini",
    "jobId": "job_abc123 | null",
    "timestamp": 1775960000.0,
    "description": "Write to /repo/src/foo.ts",
    "action": {
        "type": "file_write | shell_command | network | unknown",
        "path": "/repo/src/foo.ts",
        "command": "npm test",
        "raw": {}
    },
    "options": [
        {"kind": "allow_always", "optionId": "opt1"},
        {"kind": "allow_once", "optionId": "opt2"},
        {"kind": "deny", "optionId": "opt3"}
    ],
    "workspaceRoot": "/home/ubuntu/projects/my-repo"
}
```

### PolicyRule (persistent or session-scoped)

```json
{
    "id": "rule_<uuid8>",
    "backend": "gemini | *",
    "actionType": "file_write | shell_command | network | *",
    "pathPattern": "/workspace/** | *",
    "decision": "allow | deny",
    "scope": "session | always",
    "createdAt": 1775960000.0,
    "createdFrom": "perm_abc123"
}
```

### Policy File Location

- Persistent: `~/.config/claude-acp-bridge/permission-policy.json`
  (NOT under ~/.cache - this is user config, should survive cache wipes)
- Session rules: in-memory dict on ACPBridge, cleared on session end

## 4. Phase 1 - Foundation

### 4a. Make --yolo configurable per backend

**File**: `plugins/acp-bridge/bin/acp-client`, BACKENDS dict (line ~64)

Read env vars to decide whether to include --yolo:
```python
def _build_backend_command(name, base_command, yolo_flag="--yolo"):
    env_key = f"ACP_{name.upper()}_YOLO"
    if os.environ.get(env_key, "true").lower() in ("0", "false", "no", "off"):
        return tuple(arg for arg in base_command if arg != yolo_flag)
    return base_command
```

### 4b. Policy-aware permission handler

**File**: `plugins/acp-bridge/bin/acp-client`, replace `_handle_permission_request`

The handler should:
1. Extract structured action info from params (type, path, command, etc.)
2. Check session rules (in-memory list) for a match
3. Check persistent policy file for a match
4. If match found: auto-resolve using the matching rule's decision
5. If no match: create a pending request, queue it to `<session>.permission.pending`, block via asyncio.Future with 30-min timeout

### 4c. New ACPBridge state

```python
self._pending_permissions: dict[str, tuple[asyncio.Future, dict]] = {}
self._session_permission_rules: list[dict] = []
self._current_job_id: Optional[str] = None
```

### 4d. Permission pending file

Separate from job completion reports: `<session>.permission.pending`

One JSON line per request. Drained by inject-pending.sh alongside the regular pending file.

### 4e. New RPC action: resolve_permission

In handle_connection, add handler for `{"action": "resolve_permission", "requestId": "...", "decision": "allow|deny", "scope": "once|session|always"}`.

This resolves the blocked Future, optionally creates a policy rule.

## 5. Phase 2 - Slash Commands

### New commands (4 files)

| Command | File | What |
|---------|------|------|
| `/acp-approve` | `commands/acp-approve.md` | Approve a pending permission |
| `/acp-deny` | `commands/acp-deny.md` | Deny a pending permission |
| `/acp-permissions` | `commands/acp-permissions.md` | List pending permissions |
| `/acp-policy` | `commands/acp-policy.md` | View/manage policy rules |

### acp.sh additions

Add to the case block:
- `permissions` -> `run_info_command`
- `approve|deny` -> `run_backend_and_text_command`
- `policy` -> `run_info_command`

### acp-client CLI additions

Add `permissions`, `approve`, `deny`, `policy` to argparse choices.
Each dispatches via RPC to the bridge.

## 6. Phase 3 - Policy Management

### Policy file: `~/.config/claude-acp-bridge/permission-policy.json`

```json
{
    "version": 1,
    "rules": [
        {
            "id": "rule_abc12345",
            "backend": "gemini",
            "actionType": "file_write",
            "pathPattern": "/home/ubuntu/projects/**",
            "decision": "allow",
            "scope": "always",
            "createdAt": 1775960000.0
        }
    ]
}
```

### Rule creation flow

When `/acp-approve gemini perm_abc --always`:
1. Bridge resolves the future (unblocks the job)
2. Bridge derives a rule from the request's action_info
3. For `--always`: writes rule to persistent policy file (mode 600)
4. For `--session`: stores in-memory, cleared on session end
5. Future matching requests auto-resolve without queuing

### Rule matching priority

1. Session rules (most recent first)
2. Persistent rules (most specific first)
3. No match -> queue for Claude

### Policy commands

- `/acp-policy list` - show all rules (persistent + session)
- `/acp-policy clear --session` - clear session rules only
- `/acp-policy clear --all` - clear all rules
- `/acp-policy reset` - delete the policy file entirely

## 7. inject-pending.sh Changes

Extend to also drain `<session>.permission.pending`:

```bash
# Drain permission requests (separate from job reports)
PERM_FILE="$STATE_DIR/${session_id}.permission.pending"
if [ -f "$PERM_FILE" ]; then
  mv "$PERM_FILE" "${PERM_FILE}.inflight" 2>/dev/null
  if [ -s "${PERM_FILE}.inflight" ]; then
    PERM_CONTENT=$(cat "${PERM_FILE}.inflight")
    rm -f "${PERM_FILE}.inflight"
    # Format each JSON line as a human-readable permission prompt
    # with approve/deny command hints
  fi
fi
```

Combine permission requests and job reports into one additionalContext block.

## 8. session-hook.sh Changes

On session end, also clean up:
- `<session>.permission.pending`
- `<session>.permission.pending.inflight`

## 9. _lib.sh Changes

Add to `session_paths`:
```bash
SESSION_PERM_PENDING="$STATE_DIR/${sid}.permission.pending"
SESSION_PERM_INFLIGHT="$STATE_DIR/${sid}.permission.pending.inflight"
```

## 10. File Change Summary

### New files (4 commands + 1 plan)
- `plugins/acp-bridge/commands/acp-approve.md`
- `plugins/acp-bridge/commands/acp-deny.md`
- `plugins/acp-bridge/commands/acp-permissions.md`
- `plugins/acp-bridge/commands/acp-policy.md`
- `docs/plans/permission-monitoring.md` (this plan)

### Modified files
- `plugins/acp-bridge/bin/acp-client` - major: yolo config, permission handler, new RPC actions, new CLI commands, policy file I/O
- `plugins/acp-bridge/scripts/acp.sh` - 4 new subcommand dispatches
- `plugins/acp-bridge/scripts/inject-pending.sh` - drain permission.pending
- `plugins/acp-bridge/scripts/_lib.sh` - permission path constants
- `plugins/acp-bridge/scripts/session-hook.sh` - permission file cleanup
- `README.md` - new section, updated config table

## 11. Testing Plan

1. Set `ACP_GEMINI_YOLO=false`, restart
2. `/acp-prompt gemini "create a file called test.txt"` -> expect permission prompt
3. `/acp-approve gemini <id>` -> gemini resumes
4. `/acp-approve gemini <id> --always` -> rule persists
5. Repeat same action -> auto-approved silently
6. `/acp-policy list` -> shows the rule
7. `/acp-submit gemini "write 3 files"` -> permission requests queue, injected on next turn
8. Two concurrent permission requests from same job
9. 30-min timeout -> job cancelled gracefully
10. Policy file corruption -> fail-open to "queue for Claude"

## 12. Risks

- **ACP protocol variability**: gemini/qwen/codex may send different params. Start with flexible parser, log unknowns.
- **Blocking jobs**: permission requests block the prompt lock for up to 30 min. This is by design.
- **Policy file security**: must be mode 600. Use existing `ensure_private_file`.
- **Backward compatibility**: --yolo defaults to true, so existing users see no change until they opt in.
