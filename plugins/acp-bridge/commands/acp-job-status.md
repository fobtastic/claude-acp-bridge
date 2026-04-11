---
description: Show ACP job status. Usage: /acp-job-status <backend> <job-id>
argument-hint: '<backend> <job-id>'
allowed-tools: Bash
---

!`"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" job-status $ARGUMENTS`

Present the job status output. Surface the phase, elapsed time, and any actionable fields.
