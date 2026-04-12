---
description: Submit a prompt as a background ACP job (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" submit "$ARGUMENTS"`

Present the bridge response verbatim. Note the returned task ID — existing job commands still work, and the task can also be inspected with `/acp-task`, followed with `/acp-follow`, or canceled with `/acp-cancel`.
