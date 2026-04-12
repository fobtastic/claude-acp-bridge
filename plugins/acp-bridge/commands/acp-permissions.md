---
description: List pending permission requests for ACP backends
argument-hint: '[backend]'
allowed-tools: Bash
---

!"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" permissions "$ARGUMENTS"

List all currently blocked permission requests that are waiting for user approval.
