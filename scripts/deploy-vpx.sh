#!/usr/bin/env bash
# deploy-vpx.sh — Full VPX deployment: KVM VM provisioning + Terraform configuration
#
# Orchestrates the complete deployment of a VPX instance:
#   1. Provision KVM VM from firmware tarball (via create-vpx-vm.sh)
#   2. Wait for boot (SSH port)
#   3. Change default nsroot password (SSH forced-change + disable ForcePasswordChange)
#   4. Terraform init
#   5. Terraform Phase A: system hardening (module.system only)
#   6. Warm reboot (required for SSL default profile)
#   7. Wait for NITRO API post-reboot
#   8. Terraform Phase B: full configuration (all modules)
#
# Usage:
#   deploy-vpx.sh --name NAME --tarball PATH --ip IP --password PWD \
#                  --rpc-password PWD --cert-dir DIR --tfvars FILE \
#                  [--state FILE] [--storage-dir DIR] [--boot-timeout SECS] \
#                  [--deploy-timeout SECS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Defaults ---
VM_STORAGE_DIR="/home/vm-data"
BOOT_TIMEOUT="180"
DEPLOY_TIMEOUT="1200"
TF_STATE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           VM_NAME="$2"; shift 2 ;;
        --tarball)        TARBALL="$2"; shift 2 ;;
        --ip)             NSIP="$2"; shift 2 ;;
        --password)       PASSWORD="$2"; shift 2 ;;
        --rpc-password)   RPC_PASSWORD="$2"; shift 2 ;;
        --cert-dir)       CERT_DIR="$2"; shift 2 ;;
        --tfvars)         TFVARS="$2"; shift 2 ;;
        --state)          TF_STATE="$2"; shift 2 ;;
        --storage-dir)    VM_STORAGE_DIR="$2"; shift 2 ;;
        --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2 ;;
        --deploy-timeout) DEPLOY_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

# --- Validate required arguments ---
for VAR in VM_NAME TARBALL NSIP PASSWORD RPC_PASSWORD CERT_DIR TFVARS; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: --$(echo "$VAR" | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
        exit 1
    fi
done

# Default state file to <tfvars-basename>.tfstate
if [[ -z "$TF_STATE" ]]; then
    TF_STATE="$(basename "${TFVARS%.tfvars}").tfstate"
fi

# Common Terraform env vars
export TF_VAR_password="$PASSWORD"
export TF_VAR_rpc_password="$RPC_PASSWORD"

# Read certificate contents from cert dir (inline as TF vars)
for CERT_FILE in lab-ca.crt wildcard.lab.local.crt wildcard.lab.local.key; do
    if [[ ! -f "$CERT_DIR/$CERT_FILE" ]]; then
        echo "ERROR: Certificate file not found: $CERT_DIR/$CERT_FILE"
        exit 1
    fi
done
export TF_VAR_lab_ca_crt
TF_VAR_lab_ca_crt="$(cat "$CERT_DIR/lab-ca.crt")"
export TF_VAR_wildcard_crt
TF_VAR_wildcard_crt="$(cat "$CERT_DIR/wildcard.lab.local.crt")"
export TF_VAR_wildcard_key
TF_VAR_wildcard_key="$(cat "$CERT_DIR/wildcard.lab.local.key")"

# Deploy timeout — kill entire script if it takes too long
DEPLOY_START=$SECONDS
check_timeout() {
    if (( SECONDS - DEPLOY_START > DEPLOY_TIMEOUT )); then
        echo "ERROR: Deploy timeout exceeded (${DEPLOY_TIMEOUT}s)"
        exit 124
    fi
}

# Kill lingering SSH processes on exit to prevent Azure DevOps orphan cleanup hang
cleanup_ssh() {
    pkill -f "ssh.*nsroot@${NSIP}" 2>/dev/null || true
}
trap cleanup_ssh EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Deploying VPX: $VM_NAME"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Tarball:       $(basename "$TARBALL")"
echo "║  NSIP:          $NSIP"
echo "║  Storage:       $VM_STORAGE_DIR"
echo "║  TF vars:       $TFVARS"
echo "║  TF state:      $TF_STATE"
echo "║  Cert dir:      $CERT_DIR"
echo "║  Boot timeout:  ${BOOT_TIMEOUT}s"
echo "║  Deploy timeout: ${DEPLOY_TIMEOUT}s"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ================================================================
# Step 1: Provision KVM VM
# ================================================================
echo "━━━ Step 1/8: Provision KVM VM ━━━"
"$SCRIPT_DIR/create-vpx-vm.sh" "$VM_NAME" "$TARBALL" "$NSIP" "$VM_STORAGE_DIR"
check_timeout

# ================================================================
# Step 2: Wait for boot
# ================================================================
echo ""
echo "━━━ Step 2/8: Wait for boot ━━━"
"$SCRIPT_DIR/wait-for-boot.sh" "$NSIP" "$BOOT_TIMEOUT"
check_timeout

# ================================================================
# Step 3: Change default password (SSH + disable ForcePasswordChange)
# ================================================================
echo ""
echo "━━━ Step 3/8: Change default nsroot password ━━━"
"$SCRIPT_DIR/change-default-password.sh" "$NSIP" nsroot "$PASSWORD" "$BOOT_TIMEOUT"
check_timeout

# ================================================================
# Step 4: Terraform init
# ================================================================
echo ""
echo "━━━ Step 4/8: Terraform init ━━━"
terraform -chdir="$REPO_DIR/terraform" init -input=false
check_timeout

# ================================================================
# Step 5: Terraform Phase A — system hardening
# ================================================================
echo ""
echo "━━━ Step 5/8: Terraform Phase A (system hardening) ━━━"
terraform -chdir="$REPO_DIR/terraform" apply \
    -target=module.system \
    -var-file="$TFVARS" \
    -state="$TF_STATE" \
    -auto-approve \
    -input=false \
    -parallelism=2
check_timeout

# ================================================================
# Step 6: Warm reboot (SSL default profile requires reboot)
# ================================================================
echo ""
echo "━━━ Step 6/8: Warm reboot (SSL default profile) ━━━"
"$SCRIPT_DIR/reboot-vpx.sh" "$NSIP" "$PASSWORD"
check_timeout

# ================================================================
# Step 7: Wait for NITRO API (post-reboot)
# ================================================================
echo ""
echo "━━━ Step 7/8: Wait for NITRO API (post-reboot) ━━━"
"$SCRIPT_DIR/wait-for-nitro.sh" "$NSIP" "$PASSWORD" "$BOOT_TIMEOUT"
check_timeout

# ================================================================
# Step 8: Terraform Phase B — full configuration
# ================================================================
echo ""
echo "━━━ Step 8/8: Terraform Phase B (full configuration) ━━━"
terraform -chdir="$REPO_DIR/terraform" apply \
    -var-file="$TFVARS" \
    -state="$TF_STATE" \
    -auto-approve \
    -input=false

# ================================================================
# Verify deployment
# ================================================================
echo ""
echo "━━━ Verification ━━━"
echo "--- Terraform Outputs ---"
terraform -chdir="$REPO_DIR/terraform" output -state="$TF_STATE" || true
echo ""
echo "--- NS Version ---"
"$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns version"
echo "--- NS IPs ---"
"$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns ip"
echo "--- CS VServers ---"
"$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show cs vserver"

ELAPSED=$((SECONDS - DEPLOY_START))
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  VPX $VM_NAME deployed successfully (${ELAPSED}s)"
echo "║  NSIP: $NSIP | State: $TF_STATE"
echo "╚══════════════════════════════════════════════════════════════╝"
