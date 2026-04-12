---
description: List background ACP tasks/jobs for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" jobs "$ARGUMENTS"`

Render the output. If no backend was passed, three sections are present — show each backend's tasks on its own line group. If there are no tasks, say so concisely.
