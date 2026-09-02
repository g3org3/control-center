#!/usr/bin/env bash
# Fetch Codex (ChatGPT) session (5h) and weekly usage percentages from the
# live wham/usage API, using the OAuth token cached by the Codex CLI.
set -euo pipefail

AUTH_FILE="${CODEX_HOME:-$HOME/.codex}/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Error: $AUTH_FILE not found. Log in with 'codex' first." >&2
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.tokens.access_token' "$AUTH_FILE")
ACCOUNT_ID=$(jq -r '.tokens.account_id' "$AUTH_FILE")

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "Error: no access token in $AUTH_FILE. Run 'codex login'." >&2
  exit 1
fi

RESPONSE=$(curl -sS \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "chatgpt-account-id: $ACCOUNT_ID" \
  -H "Accept: application/json" \
  "https://chatgpt.com/backend-api/wham/usage")

if ! jq -e '.rate_limit' >/dev/null 2>&1 <<<"$RESPONSE"; then
  echo "Error: unexpected API response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

jq -r '
  .rate_limit as $rl
  | ($rl.primary_window.used_percent // 0) as $session_used
  | ($rl.secondary_window.used_percent // 0) as $weekly_used
  | "Session (5h): \(100 - $session_used)% remaining (\($session_used)% used)\nWeekly:     \(100 - $weekly_used)% remaining (\($weekly_used)% used)"
' <<<"$RESPONSE"
