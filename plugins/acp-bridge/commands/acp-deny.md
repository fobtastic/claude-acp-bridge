---
description: Deny a pending permission request for an ACP backend
argument-hint: '<backend> <request-id> [--always]'
allowed-tools: Bash
---

!"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" deny "$ARGUMENTS"

Present the bridge response verbatim. If --always is passed, a permanent deny rule is created.
