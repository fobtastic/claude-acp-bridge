---
description: Reset ACP bridge state for a given backend
argument-hint: '<backend>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" reset "$ARGUMENTS"`

Report whether the reset succeeded. If the backend argument was missing, surface the usage error to the user and suggest rerunning with a backend name.
