#!/usr/bin/env bash
# Fetch current and weekly plan usage from the Anthropic and OpenAI APIs.
set -euo pipefail

command -v curl >/dev/null 2>&1 || { echo "curl is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

CLAUDE_CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
CODEX_AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"

[[ -f "$CLAUDE_CREDS" ]] || { echo "No Anthropic credentials at $CLAUDE_CREDS; run 'claude auth login'." >&2; exit 1; }
[[ -f "$CODEX_AUTH" ]] || { echo "No OpenAI credentials at $CODEX_AUTH; run 'codex login'." >&2; exit 1; }

CLAUDE_TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CLAUDE_CREDS")"
OPENAI_TOKEN="$(jq -r '.tokens.access_token // empty' "$CODEX_AUTH")"
OPENAI_ACCOUNT="$(jq -r '.tokens.account_id // empty' "$CODEX_AUTH")"

[[ -n "$CLAUDE_TOKEN" ]] || { echo "Anthropic OAuth token is missing; run 'claude auth login'." >&2; exit 1; }
[[ -n "$OPENAI_TOKEN" ]] || { echo "OpenAI OAuth token is missing; run 'codex login'." >&2; exit 1; }

CLAUDE_RESPONSE="$(curl -sS --fail-with-body --max-time 15 \
  https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $CLAUDE_TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: oauth-2025-04-20")" || {
    echo "Failed to fetch Anthropic usage." >&2
    exit 1
  }

OPENAI_RESPONSE="$(curl -sS --fail-with-body --max-time 15 \
  https://chatgpt.com/backend-api/wham/usage \
  -H "Authorization: Bearer $OPENAI_TOKEN" \
  -H "chatgpt-account-id: $OPENAI_ACCOUNT" \
  -H "Accept: application/json")" || {
    echo "Failed to fetch OpenAI usage." >&2
    exit 1
  }
unset CLAUDE_TOKEN OPENAI_TOKEN

jq -e '.rate_limit' >/dev/null <<<"$OPENAI_RESPONSE" || {
  echo "OpenAI returned an unexpected usage response." >&2
  exit 1
}

jq -n \
  --argjson anthropic "$CLAUDE_RESPONSE" \
  --argjson openai "$OPENAI_RESPONSE" '
  def percent:
    if . == null then "n/a" else ((.*10 | round) / 10 | tostring) + "%" end;

  def reset_epoch:
    if . == null then null
    elif type == "number" then .
    elif test("^[0-9]+$") then tonumber
    else
      # fromdateiso8601 only accepts "...T..:..:..Z": drop fractional seconds
      # and fold a numeric UTC offset into the epoch value.
      sub("\\.[0-9]+"; "") as $s
      | (try ($s | fromdateiso8601) catch null) as $direct
      | if $direct != null then $direct
        else
          ($s | capture("^(?<dt>.+T[0-9:]+)(?<sign>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2})$")? // null) as $c
          | if $c == null then null
            else (try (($c.dt + "Z") | fromdateiso8601) catch null) as $base
            | if $base == null then null
              else $base - (if $c.sign == "+" then 1 else -1 end)
                   * (($c.oh | tonumber) * 3600 + ($c.om | tonumber) * 60)
              end
            end
        end
    end;

  def resets_in:
    reset_epoch as $reset
    | if $reset == null then "n/a"
      else (($reset - now) | if . < 0 then 0 else floor end) as $seconds
      | if $seconds < 60 then ($seconds | tostring) + "s"
        elif $seconds < 3600 then (($seconds / 60 | floor) | tostring) + "m"
        elif $seconds < 86400 then
          (($seconds / 3600 | floor) | tostring) + "h " +
          ((($seconds % 3600) / 60 | floor) | tostring) + "m"
        else
          (($seconds / 86400 | floor) | tostring) + "d " +
          ((($seconds % 86400) / 3600 | floor) | tostring) + "h"
        end
      end;

  ($anthropic.five_hour.utilization //
    ([$anthropic.limits[]? | select(.kind == "session")][0].percent)) as $anthropic_current |
  ($anthropic.five_hour.resets_at //
    ([$anthropic.limits[]? | select(.kind == "session")][0].resets_at)) as $anthropic_current_reset |
  ($anthropic.seven_day.utilization //
    ([$anthropic.limits[]? | select(.kind == "weekly_all")][0].percent)) as $anthropic_weekly |
  ($anthropic.seven_day.resets_at //
    ([$anthropic.limits[]? | select(.kind == "weekly_all")][0].resets_at)) as $anthropic_weekly_reset |
  ([$anthropic.limits[]? |
    select(.kind == "weekly_scoped" and
      (.scope.model.display_name // "" | test("fable"; "i")))][0].resets_at) as $fable_reset |

  $openai.rate_limit as $rate_limit |
  ($rate_limit.primary_window.used_percent // 0) as $openai_current |
  ($rate_limit.secondary_window.used_percent // 0) as $openai_weekly |

  [
    {
      provider: "anthropic",
      current_usage: ($anthropic_current | percent),
      weekly_usage: ($anthropic_weekly | percent),
      current_resets_in: ($anthropic_current_reset | resets_in),
      weekly_resets_in: ($anthropic_weekly_reset | resets_in),
      fable_resets_in: ($fable_reset | resets_in)
    },
    {
      provider: "openai",
      current_usage: ($openai_current | percent),
      weekly_usage: ($openai_weekly | percent),
      current_resets_in: (
        $rate_limit.primary_window.reset_at //
        (now + ($rate_limit.primary_window.reset_after_seconds // 0)) | resets_in
      ),
      weekly_resets_in: (
        $rate_limit.secondary_window.reset_at //
        (now + ($rate_limit.secondary_window.reset_after_seconds // 0)) | resets_in
      )
    }
  ]
'
