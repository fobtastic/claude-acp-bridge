---
description: Show ACP task status. Usage: /acp-task <backend> <task-id>
argument-hint: '<backend> <task-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" task "$ARGUMENTS"`

Present the task status output. Surface the state, status message, workspace, and artifacts.
