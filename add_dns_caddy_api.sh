#!/usr/bin/env bash
set -euo pipefail

# Add a subdomain -> localhost:PORT route via the Caddy Admin API.
# NOTE: runtime-only. If Caddy is started from a Caddyfile, this is lost on restart.
# Run Caddy with an empty/initial config and manage it through the API to go fully API-driven.

ADMIN="${CADDY_ADMIN:-localhost:2019}"

usage() {
	echo "Usage: $0 <subdomain> <port>"
	echo "Example: $0 french 8009"
	echo "Creates: french.vm.jagc.app -> reverse_proxy localhost:8009"
	exit 1
}

[[ $# -ne 2 ]] && usage

SUBDOMAIN="$1"
PORT="$2"
HOST="${SUBDOMAIN}.vm.jagc.app"

[[ ! "$PORT" =~ ^[0-9]+$ ]] && { echo "Error: port must be numeric"; exit 1; }

command -v jq >/dev/null || { echo "Error: jq is required"; exit 1; }

# Fetch the current running config (empty {} if nothing loaded yet)
CONFIG=$(curl -sf "$ADMIN/config/" || echo '{}')

# Refuse if the host already has a route anywhere
if echo "$CONFIG" | jq -e --arg h "$HOST" \
	'.apps.http.servers[]?.routes[]? | select(.match[]?.host[]? == $h)' >/dev/null; then
	echo "Error: ${HOST} already exists in the running config"
	exit 1
fi

# Build the new route
ROUTE=$(jq -n --arg host "$HOST" --arg dial "localhost:${PORT}" '{
	match: [{host: [$host]}],
	handle: [{
		handler: "subroute",
		routes: [{
			handle: [{handler: "reverse_proxy", upstreams: [{dial: $dial}]}]
		}]
	}],
	terminal: true
}')

# Merge: ensure apps.http exists, ensure tls internal issuance, append route to first server
NEW_CONFIG=$(echo "$CONFIG" | jq --argjson route "$ROUTE" '
	.apps //= {} |
	.apps.http //= {} |
	.apps.tls //= {issuance: [{module: "internal"}]} |
	.apps.http.servers //= {srv0: {listen: [":443"], routes: []}} |
	.apps.http.servers |
	.[(keys[0])].routes += [$route]
')

# Atomically load the whole config (zero-downtime)
curl -sf -X POST "$ADMIN/load" \
	-H "Content-Type: application/json" \
	--data-binary "$NEW_CONFIG" >/dev/null

echo "Added ${HOST} -> localhost:${PORT} via admin API."
echo "Warning: runtime config only — not persisted across a Caddy restart."
