---
description: Approve a pending permission request for an ACP backend
argument-hint: '<backend> <request-id> [--session|--always]'
allowed-tools: Bash
---

!"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" approve "$ARGUMENTS"

Present the bridge response verbatim. If --session is passed, matching requests are auto-approved for this session. If --always is passed, a permanent policy rule is created.
