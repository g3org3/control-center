#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="/home/george/code/systemd-template.service"
SYSTEMD_DIR="/etc/systemd/system"

BASE_DIR="/home/george/code"

usage() {
	echo "Usage: $0 <path> <port>"
	echo "Example: $0 myapp 8080"
	echo "Path is relative to ${BASE_DIR}"
	echo "Service name is derived from the folder name"
	exit 1
}

[[ $# -ne 2 ]] && usage

PATH_ARG="$1"
PORT="$2"

# Resolve path relative to /home/george/code
WORKDIR="${BASE_DIR}/${PATH_ARG}"

# Validate
[[ ! -d "$WORKDIR" ]] && { echo "Error: path '$WORKDIR' does not exist"; exit 1; }
[[ ! "$PORT" =~ ^[0-9]+$ ]] && { echo "Error: port must be numeric"; exit 1; }

# Derive service name from folder name
NAME="$(basename "$WORKDIR")"
USER="$(whoami)"
SERVICE_NAME="a_${NAME}"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# Check if already exists
if [[ -f "$SERVICE_FILE" ]]; then
	echo "Error: ${SERVICE_FILE} already exists"
	exit 1
fi

# Generate from template
sudo sed \
	-e "s|__NAME__|${NAME}|g" \
	-e "s|__USER__|${USER}|g" \
	-e "s|__PATH__|${WORKDIR}|g" \
	-e "s|__PORT__|${PORT}|g" \
	"$TEMPLATE" | sudo tee "$SERVICE_FILE" > /dev/null

# Reload systemd, enable and start
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"

echo "Installed and started: ${SERVICE_NAME}.service"
echo "  WorkingDirectory: ${WORKDIR}"
echo "  Port: ${PORT}"
echo ""
echo "Check status:  systemctl status ${SERVICE_NAME}"
echo "View logs:     journalctl -u ${SERVICE_NAME} -f"
echo "Stop:          sudo systemctl stop ${SERVICE_NAME}"
echo "Remove:        sudo systemctl disable --now ${SERVICE_NAME} && sudo rm ${SERVICE_FILE}"
