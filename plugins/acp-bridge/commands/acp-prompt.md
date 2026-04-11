---
description: Send a prompt to a persistent ACP session (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" prompt $ARGUMENTS`

Present the bridge response to the user verbatim. Do not re-summarize or paraphrase — the user is interacting with another agent and wants to see exactly what it said.
