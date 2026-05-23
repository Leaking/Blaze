#!/usr/bin/env bash
# notify-resume.sh — sends a Telegram message to the local Claude Code user
# so a sleeping/idle Claude Code session can be resumed after a disruptive
# event (e.g. the startup-watchdog firing and stopping Blaze).
#
# Reads bot credentials from the Claude Code Telegram channel plugin so we
# don't store secrets in this repo. Token at
# ~/.claude/channels/telegram/.env, recipient chat_id taken from the first
# entry of ~/.claude/channels/telegram/access.json's `allowFrom` array.
#
# Usage:
#   scripts/dev/notify-resume.sh "<message>"
#
# Returns 0 if the message was accepted by Telegram, non-zero otherwise.
# Exits 0 silently if the channel isn't configured — never fail the calling
# watchdog because of a missing notifier.

set -uo pipefail

MESSAGE="${1:-Blaze watchdog fired; reply 继续 to resume the Claude session.}"
ENV_FILE="$HOME/.claude/channels/telegram/.env"
ACCESS_FILE="$HOME/.claude/channels/telegram/access.json"

if [[ ! -f "$ENV_FILE" || ! -f "$ACCESS_FILE" ]]; then
    echo "notify-resume: telegram channel not configured at $ENV_FILE / $ACCESS_FILE" >&2
    exit 0
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "notify-resume: TELEGRAM_BOT_TOKEN missing from $ENV_FILE" >&2
    exit 0
fi

CHAT_ID="$(/usr/bin/python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for entry in data.get("allowFrom", []):
    print(entry)
    break
' "$ACCESS_FILE" 2>/dev/null || true)"

if [[ -z "$CHAT_ID" ]]; then
    echo "notify-resume: no chat_id in $ACCESS_FILE allowFrom" >&2
    exit 0
fi

RESPONSE="$(curl -sS --max-time 8 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    --data-urlencode "disable_notification=false" 2>&1 || true)"

if printf '%s' "$RESPONSE" | grep -q '"ok":true'; then
    echo "notify-resume: delivered to chat_id=${CHAT_ID}" >&2
    exit 0
fi

echo "notify-resume: telegram delivery failed: $RESPONSE" >&2
exit 1
