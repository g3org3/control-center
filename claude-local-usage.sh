#!/usr/bin/env bash
# Claude Code usage report: current session, weekly (all models), weekly (Fable only).
# Reads local Claude Code session transcripts from ~/.claude/projects/*/*.jsonl.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed." >&2; exit 1; }

# $/MTok pricing: {input, output}. Cache writes are billed at 1.25x input (5m TTL)
# or 2x input (1h TTL); cache reads at 0.1x input. Unknown models fall back to $0
# (shown as "n/a" cost) rather than guessing.
PRICING_JSON='{
  "claude-fable-5":            {"in":10, "out":50},
  "claude-mythos-5":           {"in":10, "out":50},
  "claude-mythos-preview":     {"in":10, "out":50},
  "claude-opus-4-8":           {"in":5,  "out":25},
  "claude-opus-4-7":           {"in":5,  "out":25},
  "claude-opus-4-6":           {"in":5,  "out":25},
  "claude-opus-4-5":           {"in":5,  "out":25},
  "claude-opus-4-1":           {"in":5,  "out":25},
  "claude-opus-4-0":           {"in":5,  "out":25},
  "claude-sonnet-5":           {"in":3,  "out":15},
  "claude-sonnet-4-6":         {"in":3,  "out":15},
  "claude-sonnet-4-5":         {"in":3,  "out":15},
  "claude-sonnet-4-0":         {"in":3,  "out":15},
  "claude-haiku-4-5":          {"in":1,  "out":5},
  "claude-haiku-4-5-20251001": {"in":1,  "out":5}
}'

# --- gather every assistant usage record across all local sessions -----------

mapfile -t files < <(find "$CLAUDE_DIR" -name "*.jsonl" -type f 2>/dev/null)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No Claude Code session data found under $CLAUDE_DIR"
  exit 0
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

jq -c '
  select(.type == "assistant" and .message.usage != null) |
  .message.usage as $u |
  {
    ts:         .timestamp,
    session:    .sessionId,
    model:      .message.model,
    input:      ($u.input_tokens // 0),
    output:     ($u.output_tokens // 0),
    cache_read: ($u.cache_read_input_tokens // 0),
    cache_5m:   ($u.cache_creation.ephemeral_5m_input_tokens // $u.cache_creation_input_tokens // 0),
    cache_1h:   ($u.cache_creation.ephemeral_1h_input_tokens // 0)
  }
' "${files[@]}" > "$TMP" 2>/dev/null || true

# --- current session id (falls back to the most recently modified session) ---

SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  latest_file="$(ls -t "${files[@]}" 2>/dev/null | head -1)"
  SESSION_ID="$(basename "$latest_file" .jsonl)"
fi

SINCE="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- aggregation + table rendering -------------------------------------------

report() {
  local title="$1" jqfilter="$2"
  echo "== $title =="

  local out
  out="$(jq -rs --argjson pricing "$PRICING_JSON" "
    def price(m): \$pricing[m] // {\"in\":0,\"out\":0};
    (map(select($jqfilter))) as \$rows |
    (\$rows | group_by(.model) | map(
      {
        model: .[0].model,
        requests: length,
        input: (map(.input) | add),
        output: (map(.output) | add),
        cache_write: (map(.cache_5m + .cache_1h) | add),
        cache_read: (map(.cache_read) | add)
      } as \$row |
      \$row + { cost: ((
        (\$row.input   * price(\$row.model).in) +
        (\$row.output  * price(\$row.model).out) +
        ((\$row.cache_write) * price(\$row.model).in * 1.25) +
        (\$row.cache_read * price(\$row.model).in * 0.1)
      ) / 1000000) }
    ) | sort_by(-.cost)) as \$perModel |
    (\$perModel | (map(.requests) | add // 0)) as \$treq |
    (\$perModel | (map(.input) | add // 0)) as \$tin |
    (\$perModel | (map(.output) | add // 0)) as \$tout |
    (\$perModel | (map(.cache_write) | add // 0)) as \$tcw |
    (\$perModel | (map(.cache_read) | add // 0)) as \$tcr |
    (\$perModel | (map(.cost) | add // 0)) as \$tcost |
    ([\$perModel[] | [.model, .requests, .input, .output, .cache_write, .cache_read, (.cost*100|round/100)]] +
     (if (\$perModel | length) > 1 then
        [[\"TOTAL\", \$treq, \$tin, \$tout, \$tcw, \$tcr, (\$tcost*100|round/100)]]
      else [] end)
    ) | .[] | @tsv
  " "$TMP")"

  if [ -z "$out" ]; then
    echo "  (no usage recorded)"
    echo
    return
  fi

  {
    printf 'MODEL\tREQUESTS\tINPUT\tOUTPUT\tCACHE_WRITE\tCACHE_READ\tCOST_USD\n'
    printf '%s\n' "$out"
  } | awk -F'\t' 'BEGIN{OFS="\t"} {printf "%-28s %10s %12s %12s %12s %12s %10s\n", $1,$2,$3,$4,$5,$6,$7}'
  echo
}

echo "Claude Code usage report — generated $(date '+%Y-%m-%d %H:%M %Z')"
echo

report "Current session ($SESSION_ID)" ".session == \"$SESSION_ID\""
report "Last 7 days — all models ($SINCE to now)" ".ts >= \"$SINCE\" and .ts <= \"$NOW\""
report "Last 7 days — Fable only" ".ts >= \"$SINCE\" and .ts <= \"$NOW\" and (.model | test(\"fable\"))"

echo "Note: costs are estimates (standard API pricing, 5-min cache-write TTL assumed);"
echo "actual Claude Code plan billing may differ. Unknown models price at \$0."
