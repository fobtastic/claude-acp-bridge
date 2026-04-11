---
description: Follow ACP job output until completion. Usage: /acp-follow <backend> <job-id>
argument-hint: '<backend> <job-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" follow $ARGUMENTS`

The bash command blocks until the job finishes and then returns all accumulated output. Present it verbatim. Note: Claude Code slash commands do not stream, so the user sees output only at completion — this is a known limitation vs the equivalent pi-coding-agent widget.
