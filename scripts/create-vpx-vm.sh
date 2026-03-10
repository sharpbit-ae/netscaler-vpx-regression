#!/usr/bin/env bash
# create-vpx-vm.sh — Extract VPX tarball, create preboot ISO, define and start KVM VM
set -euo pipefail

VM_NAME="${1:?Usage: $0 VM_NAME TARBALL_PATH NSIP VM_STORAGE_DIR}"
TARBALL_PATH="${2:?Missing TARBALL_PATH}"
NSIP="${3:?Missing NSIP}"
VM_STORAGE_DIR="${4:?Missing VM_STORAGE_DIR}"

GATEWAY="10.0.1.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$(mktemp -d)"

trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Creating VPX VM: $VM_NAME ==="
echo "  Tarball:  $TARBALL_PATH"
echo "  NSIP:     $NSIP"
echo "  Storage:  $VM_STORAGE_DIR"
echo "  Gateway:  $GATEWAY"

# --- Extract tarball ---
echo "[1/6] Extracting tarball..."
tar xzf "$TARBALL_PATH" -C "$WORK_DIR"

QCOW2_FILE=$(find "$WORK_DIR" -name '*.qcow2' -type f | head -1)
if [[ -z "$QCOW2_FILE" ]]; then
    echo "ERROR: No .qcow2 file found in tarball"
    exit 1
fi
echo "  Found: $(basename "$QCOW2_FILE")"

# --- Copy QCOW2 to VM storage ---
echo "[2/6] Copying QCOW2 to VM storage..."
DISK_PATH="$VM_STORAGE_DIR/${VM_NAME}.qcow2"
sudo cp "$QCOW2_FILE" "$DISK_PATH"
sudo chown qemu:kvm "$DISK_PATH"
echo "  Disk: $DISK_PATH ($(du -h "$DISK_PATH" | cut -f1))"

# --- Create preboot userdata ISO ---
echo "[3/6] Creating preboot userdata ISO..."
USERDATA_DIR="$WORK_DIR/userdata_build"
mkdir -p "$USERDATA_DIR"

sed -e "s/__NSIP__/$NSIP/g" \
    -e "s/__GATEWAY__/$GATEWAY/g" \
    "$REPO_DIR/templates/userdata.tpl" > "$USERDATA_DIR/userdata"

ISO_PATH="$VM_STORAGE_DIR/${VM_NAME}-userdata.iso"
mkisofs -l -r -quiet -o "$WORK_DIR/userdata.iso" "$USERDATA_DIR/userdata"
sudo cp "$WORK_DIR/userdata.iso" "$ISO_PATH"
sudo chown qemu:kvm "$ISO_PATH"
echo "  ISO: $ISO_PATH"

# --- Generate libvirt domain XML ---
echo "[4/6] Generating domain XML..."
sed -e "s|__NAME__|$VM_NAME|g" \
    -e "s|__DISK__|$DISK_PATH|g" \
    -e "s|__ISO__|$ISO_PATH|g" \
    "$REPO_DIR/templates/vpx-domain.tpl" > "$WORK_DIR/${VM_NAME}.xml"

# --- Define VM ---
echo "[5/6] Defining VM in libvirt..."
sudo virsh define "$WORK_DIR/${VM_NAME}.xml"

# --- Start VM ---
echo "[6/6] Starting VM..."
sudo virsh start "$VM_NAME"

echo "=== VM $VM_NAME started successfully ==="
echo "  NSIP: $NSIP"
echo "  Waiting for boot (use wait-for-boot.sh)..."
