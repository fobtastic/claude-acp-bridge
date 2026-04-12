---
description: Watch an ACP task until it reaches a terminal state
argument-hint: '<backend> <task-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" watch "$ARGUMENTS"`

The bash command polls until the task finishes and then returns accumulated output or final artifacts. Present it verbatim.
