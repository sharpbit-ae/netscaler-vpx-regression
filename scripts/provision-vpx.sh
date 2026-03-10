#!/usr/bin/env bash
# provision-vpx.sh — KVM VM provisioning only (no Terraform)
#
# Steps:
#   1. Provision KVM VM from firmware tarball (via create-vpx-vm.sh)
#   2. Wait for boot (SSH port)
#   3. Change default nsroot password
#
# Usage:
#   provision-vpx.sh --name NAME --tarball PATH --ip IP --password PWD \
#                    [--storage-dir DIR] [--boot-timeout SECS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Defaults ---
VM_STORAGE_DIR="/home/vm-data"
BOOT_TIMEOUT="180"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         VM_NAME="$2"; shift 2 ;;
        --tarball)      TARBALL="$2"; shift 2 ;;
        --ip)           NSIP="$2"; shift 2 ;;
        --password)     PASSWORD="$2"; shift 2 ;;
        --storage-dir)  VM_STORAGE_DIR="$2"; shift 2 ;;
        --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

for VAR in VM_NAME TARBALL NSIP PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: --$(echo "$VAR" | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
        exit 1
    fi
done

cleanup_ssh() {
    pkill -f "ssh.*nsroot@${NSIP}" 2>/dev/null || true
}
trap cleanup_ssh EXIT

SECONDS=0
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Provisioning VPX VM: $VM_NAME"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Tarball:       $(basename "$TARBALL")"
echo "║  NSIP:          $NSIP"
echo "║  Storage:       $VM_STORAGE_DIR"
echo "║  Boot timeout:  ${BOOT_TIMEOUT}s"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ================================================================
# Step 1: Provision KVM VM
# ================================================================
echo "━━━ Step 1/3: Provision KVM VM ━━━"
"$SCRIPT_DIR/create-vpx-vm.sh" "$VM_NAME" "$TARBALL" "$NSIP" "$VM_STORAGE_DIR"

# ================================================================
# Step 2: Wait for boot
# ================================================================
echo ""
echo "━━━ Step 2/3: Wait for boot ━━━"
"$SCRIPT_DIR/wait-for-boot.sh" "$NSIP" "$BOOT_TIMEOUT"

# ================================================================
# Step 3: Change default password
# ================================================================
echo ""
echo "━━━ Step 3/3: Change default nsroot password ━━━"
"$SCRIPT_DIR/change-default-password.sh" "$NSIP" nsroot "$PASSWORD" "$BOOT_TIMEOUT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  VPX $VM_NAME provisioned successfully (${SECONDS}s)"
echo "║  NSIP: $NSIP"
echo "╚══════════════════════════════════════════════════════════════╝"
