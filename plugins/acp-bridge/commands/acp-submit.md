---
description: Submit a prompt as a background ACP job (gemini, qwen, or codex)
argument-hint: '<backend> <text>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" submit $ARGUMENTS`

Present the bridge response verbatim. Note the returned job ID — it can be inspected with `/acp-job-status` or streamed with `/acp-follow`.
