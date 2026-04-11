---
description: Show ACP bridge status for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" status $ARGUMENTS`

Render the output to the user. If no backend was passed, three sections (`## gemini`, `## qwen`, `## codex`) are present — display each backend's status on its own line in a compact one-line summary per backend where possible. If a single backend was passed, show its output as-is.
