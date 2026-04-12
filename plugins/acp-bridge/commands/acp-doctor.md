---
description: Run ACP bridge health diagnostics
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" doctor "$ARGUMENTS"`

Present the output as a health check report. Each line starts with a status indicator:
- `✓` = healthy / available
- `✗` = problem detected
- `-` = not configured or not applicable

Flag any `✗` items and suggest remediation steps.
