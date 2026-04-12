---
description: Follow ACP task output until completion. Usage: /acp-follow <backend> <task-id>
argument-hint: '<backend> <task-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" follow "$ARGUMENTS"`

The bash command polls the task until it reaches a terminal state and then returns accumulated output or final artifacts. Present it verbatim. Note: Claude Code slash commands do not stream, so the user sees output only at completion — this is a known limitation vs the equivalent pi-coding-agent widget.
