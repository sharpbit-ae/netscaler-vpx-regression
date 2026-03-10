#!/usr/bin/env bash
# cleanup-vm.sh — Shutdown, undefine, and remove VPX VM and its storage
set -uo pipefail

VM_NAME="${1:?Usage: $0 VM_NAME VM_STORAGE_DIR}"
VM_STORAGE_DIR="${2:?Missing VM_STORAGE_DIR}"

echo "=== Cleaning up VM: $VM_NAME ==="

# Check if VM exists
if ! sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "  VM $VM_NAME does not exist, skipping"
else
    # Attempt graceful shutdown
    STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "running" ]]; then
        echo "  Shutting down $VM_NAME..."
        sudo virsh shutdown "$VM_NAME" || true
        # Wait up to 30s for graceful shutdown
        for i in $(seq 1 6); do
            sleep 5
            STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
            if [[ "$STATE" != "running" ]]; then
                break
            fi
        done
    fi

    # Force destroy if still running
    STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "running" ]]; then
        echo "  Force destroying $VM_NAME..."
        sudo virsh destroy "$VM_NAME" || true
    fi

    # Undefine
    echo "  Undefining $VM_NAME..."
    sudo virsh undefine "$VM_NAME" || true
fi

# Remove storage files
echo "  Removing storage files..."
sudo rm -f "$VM_STORAGE_DIR/${VM_NAME}.qcow2"
sudo rm -f "$VM_STORAGE_DIR/${VM_NAME}-userdata.iso"

echo "=== Cleanup complete: $VM_NAME ==="
