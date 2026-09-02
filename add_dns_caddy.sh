#!/usr/bin/env bash
set -euo pipefail

CADDYFILE="/etc/caddy/Caddyfile"

usage() {
	echo "Usage: $0 <subdomain> <port>"
	echo "Example: $0 french 8009"
	echo "Creates: french.vm.jagc.app -> reverse_proxy localhost:8009 (tls internal)"
	exit 1
}

[[ $# -ne 2 ]] && usage

SUBDOMAIN="$1"
PORT="$2"
HOST="${SUBDOMAIN}.vm.jagc.app"

# Validate port is numeric
[[ ! "$PORT" =~ ^[0-9]+$ ]] && { echo "Error: port must be numeric"; exit 1; }

# Check if already exists
if grep -qF "${HOST} {" "$CADDYFILE"; then
	echo "Error: ${HOST} already exists in ${CADDYFILE}"
	exit 1
fi

# Append the site block
sudo tee -a "$CADDYFILE" > /dev/null <<EOF

${HOST} {
	tls internal
	reverse_proxy localhost:${PORT}
}
EOF

# Reload caddy (zero downtime)
sudo systemctl reload caddy

echo "Added ${HOST} -> localhost:${PORT} and reloaded Caddy."
