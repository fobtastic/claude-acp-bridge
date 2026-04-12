---
description: View or manage ACP permission policy rules
argument-hint: '[backend] [list|clear|reset] [--all]'
allowed-tools: Bash
---

!"${CLAUDE_PLUGIN_ROOT}/scripts/acp.sh" policy "$ARGUMENTS"

Manage permission rules. 'list' shows all rules. 'clear' removes session rules (or all rules with --all). 'reset' deletes the policy file.
