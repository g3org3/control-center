#!/usr/bin/env bash
# Codex CLI usage report: plan quota (current 5h window + weekly window) taken
# straight from the rate_limits snapshots OpenAI returns with every response,
# plus a token usage / estimated-cost breakdown per model.
# Reads local Codex session transcripts from ~/.codex/sessions/**/*.jsonl —
# no network calls, no auth needed.
set -euo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

mapfile -t files < <(find "$CODEX_DIR" -name '*.jsonl' -type f 2>/dev/null | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No Codex session data found under $CODEX_DIR"
  exit 0
fi

# $/MTok pricing: {in, cached, out}. "cached" is the discounted rate for
# cached_input_tokens (a subset of input_tokens, billed cheaper than fresh
# input). Unknown/unset models price at $0 (shown as cost 0.00) rather than
# guessing — fill these in from https://openai.com/api/pricing.
PRICING_JSON='{
  "gpt-5.6-sol":   {"in":5,    "cached":0.5,   "out":30},
  "gpt-5.6-terra": {"in":2.5,  "cached":0.25,  "out":15},
  "gpt-5.6-luna":  {"in":1,    "cached":0.1,   "out":6},
  "gpt-5.5":       {"in":5,    "cached":0.5,   "out":30},
  "gpt-5.4":       {"in":2.5,  "cached":0.25,  "out":15},
  "gpt-5.4-mini":  {"in":0.75, "cached":0.075, "out":4.5}
}'

TMP="$(mktemp)"
PER_SESSION="$(mktemp)"
trap 'rm -f "$TMP" "$PER_SESSION"' EXIT

# --- every token_count event (running totals + rate_limits) across all sessions ---
grep -h '"type":"token_count"' "${files[@]}" 2>/dev/null > "$TMP" || true

if [ ! -s "$TMP" ]; then
  echo "No usage data recorded yet in Codex session logs."
  exit 0
fi

# --- freshest rate_limits snapshot (account-level; same regardless of which ---
# --- session file it came from, so just take the newest timestamp overall) ---
LATEST="$(jq -sc 'sort_by(.timestamp) | last' "$TMP")"

fmt_reset() {
  local epoch="$1"
  if [ -z "$epoch" ] || [ "$epoch" = "null" ]; then echo "n/a"; return; fi
  local now diff h m
  now="$(date +%s)"
  diff=$((epoch - now))
  if [ "$diff" -le 0 ]; then echo "already past ($(date -d "@$epoch" '+%a %H:%M %Z')) — run codex to refresh"; return; fi
  h=$((diff / 3600)); m=$(((diff % 3600) / 60))
  printf '%s (in %dh %dm)\n' "$(date -d "@$epoch" '+%a %H:%M %Z')" "$h" "$m"
}

pct() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then echo "n/a"; return; fi
  printf '%.0f%%\n' "$v"
}

win_label() {
  local mins="$1"
  if [ -z "$mins" ] || [ "$mins" = "null" ]; then echo ""; return; fi
  if [ "$mins" -ge 1440 ] && [ $((mins % 1440)) -eq 0 ]; then
    printf '%dd' $((mins / 1440))
  elif [ $((mins % 60)) -eq 0 ]; then
    printf '%dh' $((mins / 60))
  else
    printf '%dm' "$mins"
  fi
}

PLAN="$(echo "$LATEST" | jq -r '.payload.rate_limits.plan_type // "unknown"')"
LIMIT_HIT="$(echo "$LATEST" | jq -r '.payload.rate_limits.rate_limit_reached_type // empty')"
SNAPSHOT_TS="$(echo "$LATEST" | jq -r '.timestamp // empty')"

P_PCT="$(echo "$LATEST" | jq -r '.payload.rate_limits.primary.used_percent // empty')"
P_WIN="$(echo "$LATEST" | jq -r '.payload.rate_limits.primary.window_minutes // empty')"
P_RESET="$(echo "$LATEST" | jq -r '.payload.rate_limits.primary.resets_at // empty')"

S_PCT="$(echo "$LATEST" | jq -r '.payload.rate_limits.secondary.used_percent // empty')"
S_WIN="$(echo "$LATEST" | jq -r '.payload.rate_limits.secondary.window_minutes // empty')"
S_RESET="$(echo "$LATEST" | jq -r '.payload.rate_limits.secondary.resets_at // empty')"

echo "Codex CLI usage — $(date '+%Y-%m-%d %H:%M %Z')"
echo "Plan: $PLAN   (snapshot from last API call: ${SNAPSHOT_TS:-n/a})"
echo
printf '%-28s %8s   resets %s\n' "Current window ($(win_label "$P_WIN"))" "$(pct "$P_PCT")" "$(fmt_reset "$P_RESET")"
printf '%-28s %8s   resets %s\n' "Weekly ($(win_label "$S_WIN"))"         "$(pct "$S_PCT")" "$(fmt_reset "$S_RESET")"

if [ -n "$LIMIT_HIT" ] && [ "$LIMIT_HIT" != "null" ]; then
  echo
  echo "LIMIT REACHED: $LIMIT_HIT"
fi
echo

# --- per-session final totals (total_token_usage is already cumulative per --
# --- session, so the LAST token_count line in each file is that session's  --
# --- grand total — summing every line would double count) ------------------
for f in "${files[@]}"; do
  last_tc="$(grep -h '"type":"token_count"' "$f" 2>/dev/null | jq -sc 'sort_by(.timestamp) | last // empty')"
  [ -z "$last_tc" ] || [ "$last_tc" = "null" ] && continue

  model="$(grep -h '"type":"turn_context"' "$f" 2>/dev/null | jq -rc '.payload.model // empty' | tail -1)"
  [ -z "$model" ] && model="unknown"

  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"

  echo "$last_tc" | jq -c --arg model "$model" --arg file "$f" --argjson mtime "$mtime" '
    {
      file:      $file,
      mtime:     $mtime,
      model:     $model,
      input:     (.payload.info.total_token_usage.input_tokens // 0),
      cached:    (.payload.info.total_token_usage.cached_input_tokens // 0),
      output:    (.payload.info.total_token_usage.output_tokens // 0),
      reasoning: (.payload.info.total_token_usage.reasoning_output_tokens // 0),
      total:     (.payload.info.total_token_usage.total_tokens // 0)
    }'
done > "$PER_SESSION"

NOW_EPOCH="$(date +%s)"
WEEK_AGO=$((NOW_EPOCH - 7 * 24 * 3600))
LATEST_FILE="$(ls -t "${files[@]}" | head -1)"

report() {
  local title="$1" mode="$2" arg="$3"
  echo "== $title =="

  local out
  out="$(jq -rs --argjson pricing "$PRICING_JSON" --arg mode "$mode" --arg arg "$arg" '
    def price(m): $pricing[m] // {"in":0,"cached":0,"out":0};
    (map(select(
      if $mode == "file" then .file == $arg
      else (.mtime >= ($arg | tonumber)) end
    ))) as $rows |
    ($rows | group_by(.model) | map(
      {
        model: .[0].model,
        sessions: length,
        input: (map(.input) | add),
        cached: (map(.cached) | add),
        output: (map(.output) | add)
      } as $row |
      $row + { cost: ((
        (($row.input - $row.cached) * price($row.model).in) +
        ($row.cached * price($row.model).cached) +
        ($row.output * price($row.model).out)
      ) / 1000000) }
    ) | sort_by(-.cost)) as $perModel |
    ($perModel | (map(.sessions) | add // 0)) as $ts |
    ($perModel | (map(.input) | add // 0)) as $tin |
    ($perModel | (map(.cached) | add // 0)) as $tc |
    ($perModel | (map(.output) | add // 0)) as $tout |
    ($perModel | (map(.cost) | add // 0)) as $tcost |
    ([$perModel[] | [.model, .sessions, .input, .cached, .output, (.cost*100|round/100)]] +
     (if ($perModel | length) > 1 then
        [["TOTAL", $ts, $tin, $tc, $tout, ($tcost*100|round/100)]]
      else [] end)
    ) | .[] | @tsv
  ' "$PER_SESSION")"

  if [ -z "$out" ]; then
    echo "  (no usage recorded)"
    echo
    return
  fi

  {
    printf 'MODEL\tSESSIONS\tINPUT\tCACHED\tOUTPUT\tCOST_USD\n'
    printf '%s\n' "$out"
  } | awk -F'\t' 'BEGIN{OFS="\t"} {printf "%-16s %10s %12s %12s %12s %10s\n", $1,$2,$3,$4,$5,$6}'
  echo
}

report "Current session ($(basename "$LATEST_FILE"))" file "$LATEST_FILE"
report "Last 7 days — all sessions"                    mtime "$WEEK_AGO"

echo "Note: percentages/resets above come directly from OpenAI's rate-limit"
echo "response, so they're exact. Costs are estimates against standard API"
echo "pricing (edit PRICING_JSON in this script — unknown/unset models price"
echo "at \$0). If you're on a ChatGPT Plus/Pro/Team plan, actual billing is a"
echo "flat subscription fee, not per-token — the quota % above is what governs"
echo "whether you're rate-limited, not the cost estimate."
