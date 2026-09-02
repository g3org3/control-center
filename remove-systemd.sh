#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="/etc/systemd/system"

usage() {
	echo "Usage: $0 <name>"
	echo "Example: $0 myapp"
	echo "Stops, disables, and removes a systemd service"
	exit 1
}

[[ $# -ne 1 ]] && usage

NAME="$1"
SERVICE_NAME="a_${NAME}"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

if [[ ! -f "$SERVICE_FILE" ]]; then
	echo "Error: ${SERVICE_FILE} does not exist"
	exit 1
fi

# Stop and disable
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true

# Remove service file
sudo rm -f "$SERVICE_FILE"

# Reload systemd
sudo systemctl daemon-reload

echo "Removed: ${NAME}.service"
