---
name: acp-delegation
description: Use when the user wants Claude Code to delegate coding, research, review, implementation, test-fixing, or other long-running work to Gemini, Qwen, or Codex through the claude-acp-bridge plugin. Also use when checking, following, resuming, approving, denying, or managing ACP bridge background jobs and permissions.
---

# ACP Delegation

Use the ACP bridge to delegate bounded work to another agent while Claude Code remains the coordinator.

The bridge talks to ACP-capable/local backends such as Gemini, Qwen, and Codex. Treat it as a background delegation system: package the task clearly, submit it, monitor it, handle permission requests, then verify the result before reporting success.

## When To Delegate

Use ACP delegation when:
- The task is long-running and can run without constant interaction.
- The task can be described with a clear workspace, goal, scope, and stop conditions.
- Another agent can inspect or edit a repository independently.
- The user asks to hand work to another agent.
- The user asks to check, follow, or manage existing ACP jobs.

Prefer working locally when:
- The task is small or urgent.
- The next step depends on immediate local feedback.
- The task is ambiguous and a wrong change would be costly.
- The task requires credentials, destructive actions, or broad permissions.
- The delegated agent would need context that cannot be safely summarized.

## Backend Choice

If the user does not choose a backend:
- Prefer `qwen` for implementation-heavy coding tasks.
- Prefer `gemini` for analysis, review, planning, and alternate reasoning.
- Prefer `codex` for coding or verification when the user specifically wants Codex involved.

Only use backends that are installed and healthy.

## Core Commands

Check health and bridge state:

```text
/acp-doctor
/acp-status
/acp-status <backend>
```

Submit background work:

```text
/acp-submit <backend> "<delegation prompt>"
```

List jobs:

```text
/acp-jobs
/acp-jobs <backend>
```

Inspect one job:

```text
/acp-job-status <backend> <job-id>
```

Wait for one job to finish:

```text
/acp-follow <backend> <job-id>
```

Manage permission requests:

```text
/acp-permissions
/acp-permissions <backend>
/acp-approve <backend> <request-id> --session
/acp-deny <backend> <request-id>
```

Close an idle bridge:

```text
/acp-close <backend>
```

Do not close a backend while it has active jobs.

## Delegation Workflow

1. Decide whether delegation is appropriate.
2. Identify the backend, workspace, branch expectations, task scope, and success criteria.
3. Write a complete delegation prompt.
4. Submit the work with `/acp-submit`.
5. Record the returned job ID in the conversation.
6. Continue useful non-overlapping work locally if possible.
7. Check status with `/acp-jobs` or `/acp-job-status`.
8. Use `/acp-follow` when the result is needed.
9. Inspect the delegated agent's result before trusting it.
10. Run relevant tests or checks when practical.
11. Summarize what happened, what changed, what passed, and what remains.

## Delegation Prompt Template

Use this structure for implementation tasks:

```text
Workspace: <absolute path>
Branch: <use current branch | create branch name | do not commit>
Task: <short task name>

Goal:
<what should be true when done>

Context:
<relevant files, commands, issue details, constraints, or plan>

Instructions:
1. Inspect the relevant code before editing.
2. Keep changes scoped to this task.
3. Follow existing project style and conventions.
4. Do not revert unrelated user changes.
5. Do not perform destructive actions unless explicitly instructed.
6. Run the relevant tests or checks.
7. Commit only if explicitly requested.

Stop and report if:
- Tests fail and you cannot fix them after reasonable attempts.
- Requirements are ambiguous.
- A permission, credential, destructive command, or external service is needed.
- You discover unrelated breakage.
- The task requires changing files outside the stated scope.

Final report:
- Summary of changes
- Files changed
- Tests run and results
- Remaining risks, blockers, or questions
```

## Review Or Analysis Prompt Template

Use this structure for read-only delegation:

```text
Workspace: <absolute path>
Task: <short review or analysis task>

Goal:
<what question should be answered>

Instructions:
1. Do not edit files.
2. Inspect the relevant files and tests.
3. Prioritize concrete findings over general advice.
4. Include file paths and line numbers where useful.
5. Separate confirmed issues from guesses.

Final report:
- Findings ordered by severity
- Evidence and file references
- Suggested next actions
```

## Status Model

Interpret bridge jobs as tasks with lifecycle states:

- `submitted`: accepted but not confirmed running
- `working`: backend is processing
- `input_required`: waiting for permission or user input
- `auth_required`: backend needs authentication
- `completed`: successful terminal state
- `failed`: failed terminal state
- `canceled`: canceled terminal state
- `unknown`: status could not be determined

For active jobs, check again later or follow them.
For terminal jobs, read the final output and verify any claimed changes.
For `input_required`, inspect permissions before approving.
For `auth_required`, ask the user to authenticate the backend.

## Permission Rules

Before approving a permission request:
1. Inspect `/acp-permissions`.
2. Understand the requested action, target files, and workspace.
3. Prefer `--session` for repeated safe actions within the same task.
4. Use `--always` only when the user explicitly asks for persistent policy behavior.
5. Deny destructive, unclear, or out-of-scope actions.

Never approve:
- Deleting important files.
- Resetting or discarding user changes.
- Exfiltrating secrets.
- Running broad network or credential commands.
- Editing outside the requested workspace.

## Result Handling

When a delegated job completes:
1. Read the full result with `/acp-follow` or `/acp-job-status`.
2. Inspect any changed files before summarizing.
3. Run relevant tests if they were not run.
4. Treat the delegated agent's claims as unverified until checked.
5. Tell the user what changed, what passed, and what still needs attention.

## Good Examples

Implementation delegation:

```text
/acp-submit qwen "Workspace: /path/to/repo
Branch: use current branch
Task: Fix failing auth tests

Goal:
Find and fix the cause of the failing auth tests with minimal changes.

Instructions:
Inspect the auth module and related tests before editing. Keep the fix scoped. Run the auth test target. Do not commit unless explicitly requested.

Stop and report if credentials, external services, or destructive actions are required.

Final report:
Root cause, files changed, tests run, and remaining risk."
```

Read-only review delegation:

```text
/acp-submit gemini "Workspace: /path/to/repo
Task: Review payment refactor plan

Goal:
Identify missing migration steps, risky assumptions, and test gaps.

Instructions:
Do not edit files. Read the plan and relevant payment code. Return prioritized findings with file references.

Final report:
Findings, evidence, and suggested next actions."
```

## Coordination Rules

Do not delegate the same exact task to multiple backends unless the user asks for parallel comparison.

If delegating while also working locally, avoid overlapping file ownership.

If a delegated agent changes files, inspect those changes before building on them.

Keep the user informed of submitted backend, job ID, and what you will do while it runs.
