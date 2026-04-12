---
description: List ACP background tasks for gemini, qwen, or codex
argument-hint: '[backend]'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" tasks "$ARGUMENTS"`

Render the output. If no backend was passed, three sections are present — show each backend's tasks on its own line group.
