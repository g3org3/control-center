#!/usr/bin/env bash
# Concise view of Claude plan usage (% of quota), straight from Anthropic's
# account API: current 5-hour session window, weekly usage across all models,
# and weekly usage for Fable specifically.
set -euo pipefail

CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

if [ ! -f "$CREDS" ]; then
  echo "No credentials found at $CREDS — run 'claude auth login' first." >&2
  exit 1
fi

TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS")"
EXPIRES_MS="$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS")"

if [ -z "$TOKEN" ]; then
  echo "No OAuth access token found in $CREDS — run 'claude auth login'." >&2
  exit 1
fi

NOW_MS=$(($(date +%s%N) / 1000000))
if [ "$EXPIRES_MS" -gt 0 ] && [ "$NOW_MS" -ge "$EXPIRES_MS" ]; then
  echo "Access token looks expired — run any 'claude' command once to refresh it, then retry." >&2
fi

RESP="$(curl -s -w '\n%{http_code}' --max-time 10 \
  https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: oauth-2025-04-20")"
unset TOKEN

STATUS="$(echo "$RESP" | tail -1)"
BODY="$(echo "$RESP" | sed '$d')"

if [ "$STATUS" != "200" ]; then
  echo "Usage fetch failed (HTTP $STATUS):" >&2
  echo "$BODY" >&2
  exit 1
fi

fmt_reset() {
  # $1 = ISO8601 timestamp or "null"
  local ts="$1"
  [ -z "$ts" ] || [ "$ts" = "null" ] && { echo "n/a"; return; }
  local epoch now diff h m
  epoch="$(date -d "$ts" +%s 2>/dev/null)" || { echo "n/a"; return; }
  now="$(date +%s)"
  diff=$((epoch - now))
  if [ "$diff" -le 0 ]; then
    echo "resetting now"
    return
  fi
  h=$((diff / 3600))
  m=$(((diff % 3600) / 60))
  printf '%s (in %dh %dm)\n' "$(date -d "$ts" '+%a %H:%M %Z')" "$h" "$m"
}

pct() {
  # $1 = number or "null" -> formatted percentage
  local v="$1"
  [ -z "$v" ] || [ "$v" = "null" ] && { echo "n/a"; return; }
  printf '%.0f%%\n' "$v"
}

SESSION_PCT="$(echo "$BODY" | jq -r '.five_hour.utilization // (.limits[]? | select(.kind=="session") | .percent)' | head -1)"
SESSION_RESET="$(echo "$BODY" | jq -r '.five_hour.resets_at // (.limits[]? | select(.kind=="session") | .resets_at)' | head -1)"

WEEK_ALL_PCT="$(echo "$BODY" | jq -r '.seven_day.utilization // (.limits[]? | select(.kind=="weekly_all") | .percent)' | head -1)"
WEEK_ALL_RESET="$(echo "$BODY" | jq -r '.seven_day.resets_at // (.limits[]? | select(.kind=="weekly_all") | .resets_at)' | head -1)"

WEEK_FABLE_PCT="$(echo "$BODY" | jq -r '[.limits[]? | select(.kind=="weekly_scoped" and (.scope.model.display_name // "" | test("fable"; "i")))][0].percent // empty')"
WEEK_FABLE_RESET="$(echo "$BODY" | jq -r '[.limits[]? | select(.kind=="weekly_scoped" and (.scope.model.display_name // "" | test("fable"; "i")))][0].resets_at // empty')"

echo "Claude plan usage — $(date '+%Y-%m-%d %H:%M %Z')"
echo
printf '%-28s %8s   resets %s\n' "Current session (5h)"        "$(pct "$SESSION_PCT")"   "$(fmt_reset "$SESSION_RESET")"
printf '%-28s %8s   resets %s\n' "Weekly - all models (7d)"    "$(pct "$WEEK_ALL_PCT")"  "$(fmt_reset "$WEEK_ALL_RESET")"
printf '%-28s %8s   resets %s\n' "Weekly - Fable (7d)"         "$(pct "${WEEK_FABLE_PCT:-null}")" "$(fmt_reset "${WEEK_FABLE_RESET:-null}")"

if [ -z "${WEEK_FABLE_PCT:-}" ]; then
  echo
  echo "(No Fable-specific weekly bucket reported — either you haven't used Fable this week, or it's not broken out separately on your plan.)"
fi
