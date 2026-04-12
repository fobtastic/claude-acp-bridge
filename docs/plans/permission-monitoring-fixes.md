# Permission Monitoring — Post-Review Fixes

**Context**: Codex reviewed gemini's permission monitoring implementation and found 7 issues (1 critical, 3 high, 2 medium, 1 low). This plan addresses all of them.

**Priority**: Fix #1 and #2 first (feature is broken without them), then #3-#4 (correctness), then #5-#6 (robustness), then #7 (polish).

---

## Fix 1 — CRITICAL: Shell command approvals silently become wildcard rules

### Problem

When a user approves a shell command permission with `--session` or `--always`, the rule is derived from `action["path"]` (which is null for shell commands) and falls back to `pathPattern: "*"`. The rule matcher only checks backend + actionType + pathPattern. Since `action["command"]` is captured but never stored in the rule or checked by `rule_matches()`, approving `npm test --always` creates a rule equivalent to "allow ALL shell_command requests for this backend forever."

### Fix

1. **Add `commandPattern` field to policy rules** for shell_command type actions.

2. **In `resolve_permission`** (where rules are derived from approved requests): when the action type is `shell_command`, store the command value as `commandPattern` instead of falling back to `"*"`. For exact commands, use the literal string. For broader approval, use a prefix glob (e.g., `npm *`).

3. **In `rule_matches()`**: when evaluating a rule with `actionType == "shell_command"`, ALSO check `commandPattern` against `action["command"]` using fnmatch. A rule without `commandPattern` (or `commandPattern: "*"`) is explicitly broad and should only be creatable via a dedicated `/acp-policy add` command, not implicitly from a single approval.

4. **Refuse overly broad implicit rules**: if a permission request has `type: "unknown"` (no structured fields to match on), `--session` and `--always` should be rejected with an error message explaining that a manual policy rule is needed for unstructured actions. One-time approval (`--once`) should always work.

### Affected code
- `acp-client`: `resolve_permission` handler (~line 1548), `rule_matches()` (~line 1183), `save_policy_rule()`
- Policy file schema: add optional `commandPattern` field

---

## Fix 2 — HIGH: Permission requests written under wrong session ID

### Problem

The bridge daemon writes permission pending files as `<self.session_id>.permission.pending` where `self.session_id` is the **ACP backend session ID** (a UUID for the gemini/qwen/codex chat session). But `inject-pending.sh` drains files keyed by the **Claude Code session ID** (from the hook's stdin JSON). These are completely different IDs. Result: permission requests are queued to a file nobody ever reads.

### Fix

The bridge daemon needs to know the Claude Code session ID so it can write to the correct pending file. Two approaches:

**Option A (simpler)**: Pass the Claude Code session state directory path to the bridge via the RPC request. Every request from acp.sh already passes `--workspace`. Similarly, acp.sh can pass the `$CLAUDE_ACP_SESSION_FILE` path (which is set by session-hook.sh start) as a field in the RPC payload. The bridge writes permission requests to the same directory, using the session file's name to derive the Claude session ID.

**Option B (cleaner)**: Export `CLAUDE_ACP_SESSION_ID` as an env var from session-hook.sh start (alongside `CLAUDE_ACP_SESSION_FILE`). Have acp.sh pass it in every RPC request as `claudeSessionId`. The bridge uses this to construct the pending file path.

**Recommended: Option B.**

Implementation:
1. `session-hook.sh start`: also export `CLAUDE_ACP_SESSION_ID=$session_id` via `$CLAUDE_ENV_FILE`
2. `_lib.sh`: no change needed (STATE_DIR is already shared)
3. `acp.sh`: pass `--claude-session "$CLAUDE_ACP_SESSION_ID"` to every acp-client invocation (or add it as an env var the client reads directly — simpler)
4. `acp-client`: in handle_connection, read `claudeSessionId` from the request payload (or from env `CLAUDE_ACP_SESSION_ID` inherited by the bridge subprocess)
5. `_handle_permission_request`: write to `$STATE_DIR/<claudeSessionId>.permission.pending` instead of `<self.session_id>.permission.pending`

**Wait — there's a subtlety**: the bridge is a long-lived daemon process. It was spawned at session start by the asyncRewake hook. At spawn time, Claude Code exports env vars (including `CLAUDE_ACP_SESSION_FILE`). The bridge inherits these. So `CLAUDE_ACP_SESSION_FILE` IS available in the bridge's env already.

Let me verify: the bridge process is spawned by `start_server_process()` which is called from `ensure_server()`. `ensure_server()` is called from the one-shot CLI process (acp.sh -> acp-client). The CLI process inherits Claude Code's env. But the DAEMON (spawned via `subprocess.Popen` with `start_new_session=True`) — does IT inherit the env?

Looking at `start_server_process` (line ~1091): `subprocess.Popen([...], start_new_session=True, ...)`. By default Popen inherits the parent's env. So yes, the daemon DOES inherit `CLAUDE_ACP_SESSION_FILE`.

**Simplest fix**: In `_handle_permission_request`, derive the pending file path from `os.environ.get("CLAUDE_ACP_SESSION_FILE")`. Extract the session ID from the filename (it's `$STATE_DIR/<session_id>.list`), then write to `$STATE_DIR/<session_id>.permission.pending`.

No RPC payload changes needed. The bridge already has the right env var.

### Affected code
- `acp-client`: `_handle_permission_request` and/or a new helper `_get_claude_session_pending_path()`
- Maybe `_queue_permission_to_pending()` — change the path derivation

---

## Fix 3 — HIGH: /acp-policy clear/reset cannot be dispatched

### Problem

`acp.sh` routes `policy` through `run_info_command`, which treats any non-empty `$ARGUMENTS` as a backend name. So `/acp-policy clear --all` tries to validate "clear" as a backend name and fails.

### Fix

Add a dedicated `run_policy_command` handler in `acp.sh`:

```bash
run_policy_command() {
  # Policy accepts: no args (list all), or a subcommand (list/clear/reset)
  # with optional flags (--session, --all).
  # Pass everything through to acp-client without backend validation.
  "$ACP_CLIENT_BIN" --workspace "$ACP_WORKSPACE" policy $ARGS
}
```

And in the case block:
```bash
policy)
    run_policy_command
    ;;
```

The acp-client CLI handles parsing "list", "clear", "reset" as policy subcommands.

### Affected code
- `acp.sh`: new `run_policy_command` function, update case block
- `acp-client`: verify the policy CLI handler parses subcommands from `args.text`

---

## Fix 4 — HIGH: Older broad rules override later specific rules

### Problem

`_match_persistent_rule()` iterates rules in file order (oldest appended first). `save_policy_rule()` appends to the end. So an old broad `allow *` rule always matches before a newer specific `deny /sensitive/**` rule.

### Fix

Sort rules by specificity before evaluation. Specificity order (most specific first):
1. Exact path (no glob chars) > glob pattern > `"*"` wildcard
2. Specific backend > `"*"` backend
3. Specific actionType > `"*"` actionType
4. For equal specificity: most recently created wins (higher `createdAt`)

Implementation: in `_match_persistent_rule()`, after loading rules, sort them by a specificity score before iterating. Helper:

```python
def _rule_specificity(rule: dict) -> tuple:
    """Higher = more specific. Used as sort key (descending)."""
    path = rule.get("pathPattern", "*")
    path_score = 0 if path == "*" else (2 if "*" not in path and "?" not in path else 1)
    backend_score = 0 if rule.get("backend") == "*" else 1
    action_score = 0 if rule.get("actionType") == "*" else 1
    cmd_score = 0 if rule.get("commandPattern", "*") == "*" else 1
    recency = rule.get("createdAt", 0)
    return (path_score, backend_score, action_score, cmd_score, recency)
```

Sort descending by this tuple before iterating.

### Affected code
- `acp-client`: `_match_persistent_rule()` (add sort), new `_rule_specificity()` helper

---

## Fix 5 — MEDIUM: SessionEnd deletes permission files for preserved jobs

### Problem

`session-hook.sh end` unconditionally deletes `$SESSION_PERM_PENDING` and `$SESSION_PERM_INFLIGHT` BEFORE checking whether backends have active jobs. A background job that's preserved (activeJobs > 0) may be blocked on a permission request — its queued prompt is now gone.

### Fix

Move the permission file deletion to AFTER the bridge-cleanup loop, and only delete if ALL tracked backends were closed. If any backend was preserved (activeJobs > 0), also preserve the permission pending files.

```bash
# Track whether any backend was preserved.
any_preserved=0
while IFS= read -r backend; do
    ...
    if [ "$active_jobs" -gt 0 ]; then
        any_preserved=1
        ...
    fi
done < <(sort -u "$SESSION_LIST_FILE")

# Only delete permission files if nothing was preserved.
if [ "$any_preserved" = "0" ]; then
    rm -f "$SESSION_PERM_PENDING" "$SESSION_PERM_INFLIGHT"
fi
```

### Affected code
- `session-hook.sh`: reorder deletion, add preservation logic

---

## Fix 6 — MEDIUM: Concurrent policy file writes can lose rules

### Problem

Two bridge processes (e.g., gemini and qwen bridges) both call `save_policy_rule()` concurrently. Both load the same file, each appends their rule, each does atomic-replace. The second replace overwrites the first's addition.

### Fix

Use advisory file locking around policy reads+writes:

```python
import fcntl

POLICY_LOCK = Path.home() / ".config" / "claude-acp-bridge" / ".policy.lock"

def _with_policy_lock(func):
    """Decorator: hold an advisory lock on the policy file during read-modify-write."""
    def wrapper(*args, **kwargs):
        POLICY_LOCK.parent.mkdir(parents=True, exist_ok=True)
        with open(POLICY_LOCK, "w") as lock_fd:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            try:
                return func(*args, **kwargs)
            finally:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
    return wrapper
```

Apply to `save_policy_rule()` and `clear_policy()`. Note: this flock is on a SEPARATE lock file (not the policy file itself), so it doesn't interfere with readers that just want to check rules (the bridge's `_match_persistent_rule` can read without locking — worst case it misses a just-written rule for one poll cycle, which is acceptable).

### Affected code
- `acp-client`: `save_policy_rule()`, `clear_policy()` — add flock wrapper

---

## Fix 7 — LOW: Debug logging may expose sensitive params

### Problem

`_extract_action_info()` logs unrecognized fields from permission params to stderr. These could contain tokens, passwords, or other secrets depending on what the backend sends.

### Fix

Gate the debug logging behind an env var (`ACP_BRIDGE_DEBUG=1`). Without it, don't log the raw params. When enabled, redact values for keys matching common sensitive patterns:

```python
SENSITIVE_KEYS = re.compile(r"(token|password|secret|key|auth|header|cookie)", re.IGNORECASE)

def _safe_log_params(params: dict) -> dict:
    return {k: ("***" if SENSITIVE_KEYS.search(k) else v) for k, v in params.items()}
```

### Affected code
- `acp-client`: `_extract_action_info()` debug log path

---

## Implementation Order

1. **Fix 2** (session ID mismatch) — unblocks the entire feature
2. **Fix 1** (wildcard command rules) — security-critical
3. **Fix 4** (rule ordering) — correctness
4. **Fix 3** (policy dispatch) — usability
5. **Fix 5** (preserved job permissions) — robustness
6. **Fix 6** (concurrent writes) — robustness
7. **Fix 7** (log redaction) — polish

## Delegation strategy

All 7 fixes can be dispatched to gemini as a single /acp-submit job with this plan as the spec. Estimated complexity: medium (~300 lines of changes). The most architecturally tricky one is Fix 2 (session ID plumbing), but the "just read CLAUDE_ACP_SESSION_FILE from env" approach is simple and already available in the bridge's process env.
