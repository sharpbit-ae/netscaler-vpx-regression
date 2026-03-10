#!/usr/bin/env bash
# configure-vpx.sh — Terraform configuration only (assumes VPX is already running)
#
# Steps:
#   1. Terraform init
#   2. Terraform Phase A: system hardening (module.system only)
#   3. Warm reboot (required for SSL default profile)
#   4. Wait for NITRO API post-reboot
#   5. Terraform Phase B: full configuration (all modules)
#   6. Verify deployment
#
# Usage:
#   configure-vpx.sh --name NAME --ip IP --password PWD \
#                    --rpc-password PWD --cert-dir DIR --tfvars FILE \
#                    [--state FILE] [--boot-timeout SECS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# --- Defaults ---
BOOT_TIMEOUT="180"
TF_STATE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           VM_NAME="$2"; shift 2 ;;
        --ip)             NSIP="$2"; shift 2 ;;
        --password)       PASSWORD="$2"; shift 2 ;;
        --rpc-password)   RPC_PASSWORD="$2"; shift 2 ;;
        --cert-dir)       CERT_DIR="$2"; shift 2 ;;
        --tfvars)         TFVARS="$2"; shift 2 ;;
        --state)          TF_STATE="$2"; shift 2 ;;
        --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1"
            exit 1
            ;;
    esac
done

for VAR in VM_NAME NSIP PASSWORD RPC_PASSWORD CERT_DIR TFVARS; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: --$(echo "$VAR" | tr '_' '-' | tr '[:upper:]' '[:lower:]') is required"
        exit 1
    fi
done

if [[ -z "$TF_STATE" ]]; then
    TF_STATE="$(basename "${TFVARS%.tfvars}").tfstate"
fi

# Terraform env vars
export TF_VAR_password="$PASSWORD"
export TF_VAR_rpc_password="$RPC_PASSWORD"

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

cleanup_ssh() {
    pkill -f "ssh.*nsroot@${NSIP}" 2>/dev/null || true
}
trap cleanup_ssh EXIT

SECONDS=0
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Configuring VPX: $VM_NAME"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  NSIP:          $NSIP"
echo "║  TF vars:       $TFVARS"
echo "║  TF state:      $TF_STATE"
echo "║  Cert dir:      $CERT_DIR"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ================================================================
# Step 1: Terraform init
# ================================================================
echo "━━━ Step 1/5: Terraform init ━━━"
terraform -chdir="$REPO_DIR/terraform" init -input=false

# ================================================================
# Step 2: Terraform Phase A — system hardening
# ================================================================
echo ""
echo "━━━ Step 2/5: Terraform Phase A (system hardening) ━━━"
terraform -chdir="$REPO_DIR/terraform" apply \
    -target=module.system \
    -var-file="$TFVARS" \
    -state="$TF_STATE" \
    -auto-approve \
    -input=false \
    -parallelism=2

# ================================================================
# Step 3: Warm reboot (SSL default profile requires reboot)
# ================================================================
echo ""
echo "━━━ Step 3/5: Warm reboot (SSL default profile) ━━━"
"$SCRIPT_DIR/reboot-vpx.sh" "$NSIP" "$PASSWORD"

# ================================================================
# Step 4: Wait for NITRO API (post-reboot)
# ================================================================
echo ""
echo "━━━ Step 4/5: Wait for NITRO API (post-reboot) ━━━"
"$SCRIPT_DIR/wait-for-nitro.sh" "$NSIP" "$PASSWORD" "$BOOT_TIMEOUT"

# ================================================================
# Step 5: Terraform Phase B — full configuration
# ================================================================
echo ""
echo "━━━ Step 5/5: Terraform Phase B (full configuration) ━━━"
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

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  VPX $VM_NAME configured successfully (${SECONDS}s)"
echo "║  NSIP: $NSIP | State: $TF_STATE"
echo "╚══════════════════════════════════════════════════════════════╝"
