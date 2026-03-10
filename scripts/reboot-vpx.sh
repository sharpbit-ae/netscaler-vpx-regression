#!/usr/bin/env bash
# reboot-vpx.sh — Trigger warm reboot on VPX via SSH
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP PASSWORD}"
PASSWORD="${2:?Missing PASSWORD}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Initiating warm reboot on $NSIP ==="

# Save config first
"$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "save config" || true

# Warm reboot — the SSH connection will disconnect, which is expected
"$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "reboot -warm" || true

echo "  Reboot command sent. VPX will restart."
echo "=== Use wait-for-nitro.sh to poll for readiness ==="
