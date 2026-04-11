#!/usr/bin/env bash
# notify-telegram.sh — post acp-bridge notifications to a Telegram chat.
#
# Reads the message from stdin. Silently no-ops unless both of these are set:
#   - TELEGRAM_BOT_TOKEN (read from env or ~/.claude/channels/telegram/.env)
#   - ACP_BRIDGE_TELEGRAM_CHAT_ID (read from env)
#
# Reuses the telegram plugin's existing bot token by default — if the user
# wants a separate bot, they can set TELEGRAM_BOT_TOKEN in their shell env.
#
# Exit codes:
#   0 — success, or graceful no-op when config is missing
#   1 — telegram API call returned non-200 (advisory; caller ignores this)

set -uo pipefail

CHAT_ID="${ACP_BRIDGE_TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT_ID" ]; then
  exit 0
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TELEGRAM_ENV_FILE="$HOME/.claude/channels/telegram/.env"
  if [ -r "$TELEGRAM_ENV_FILE" ]; then
    while IFS='=' read -r key value; do
      # Strip optional surrounding quotes on the value.
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      if [ "$key" = "TELEGRAM_BOT_TOKEN" ]; then
        TOKEN="$value"
        break
      fi
    done < "$TELEGRAM_ENV_FILE"
  fi
fi

if [ -z "$TOKEN" ]; then
  exit 0
fi

MESSAGE=$(cat)
if [ -z "$MESSAGE" ]; then
  exit 0
fi

# HTML-escape the message body so arbitrary characters (job ids with
# underscores, angle brackets in the "/acp-follow <backend> <job-id>" hint,
# etc.) don't break Telegram's parser. HTML mode only requires escaping
# three characters (&, <, >), unlike MarkdownV2 which escapes 18. Then
# wrap a recognizable <b>acp-bridge</b> header around the body for the
# bolded app tag users asked for.
#
# Important: bash 5.2 enables `patsub_replacement` by default, which makes
# a bare `&` in the replacement string expand to the matched text. We
# backslash-escape `&` in the replacement so it stays literal — otherwise
# `&lt;` would expand to `<lt;` (matched `<` plus literal `lt;`).
ESCAPED_BODY=${MESSAGE//&/\&amp;}
ESCAPED_BODY=${ESCAPED_BODY//</\&lt;}
ESCAPED_BODY=${ESCAPED_BODY//>/\&gt;}
FULL_MESSAGE=$(printf '<b>acp-bridge</b>\n\n%s' "$ESCAPED_BODY")

# POST to Telegram Bot API. Capture the HTTP status code via -w.
STATUS_TMP=$(mktemp)
curl -sS -o /dev/null -w '%{http_code}' \
  "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${FULL_MESSAGE}" \
  --data "parse_mode=HTML" \
  > "$STATUS_TMP" 2>/dev/null || true

status=$(cat "$STATUS_TMP" 2>/dev/null || echo "000")
rm -f "$STATUS_TMP"

if [ "$status" = "200" ]; then
  exit 0
fi
exit 1
