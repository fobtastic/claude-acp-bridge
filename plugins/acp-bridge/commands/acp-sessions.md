---
description: List ACP sessions for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" sessions "$ARGUMENTS"`

Render the output. If no backend was passed, three sections are present — summarize each backend's session count on its own line, then list the first few sessions if space allows.
