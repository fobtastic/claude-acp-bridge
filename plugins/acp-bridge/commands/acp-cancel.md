---
description: Best-effort cancel an ACP background task
argument-hint: '<backend> <task-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" cancel "$ARGUMENTS"`

Present the updated task state. If the backend reports that the task is not safely cancelable, say so clearly.
