---
description: Close the ACP bridge for a given backend
argument-hint: '<backend>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" close "$ARGUMENTS"`

Report whether the close succeeded. If the backend argument was missing, surface the usage error to the user and suggest rerunning with a backend name.
