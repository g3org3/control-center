#!/usr/bin/env bash
set -euo pipefail

echo "Services created by create-and-install-systemd.sh:"
echo ""

for svc in /etc/systemd/system/a_*.service; do
	[[ -f "$svc" ]] || continue
	name="$(basename "$svc" .service)"
	status="$(systemctl is-active "$name" 2>/dev/null || echo "unknown")"
	port="$(grep -oP 'http\.server \K[0-9]+' "$svc" 2>/dev/null || echo "?")"
	workdir="$(grep -oP 'WorkingDirectory=\K.*' "$svc" 2>/dev/null || echo "?")"
	printf "%-20s %-10s %-8s %s\n" "$name" "$status" "$port" "$workdir"
done
