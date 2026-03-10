#!/usr/bin/env bash
# wait-for-boot.sh — Poll SSH port until VPX is reachable, with timeout
# Uses TCP port check (not login) because fresh VPXs trigger a forced
# password change prompt that ssh-vpx.sh cannot handle.
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP [MAX_WAIT_SECONDS]}"
MAX_WAIT="${2:-180}"

ELAPSED=0
INTERVAL=10

echo "=== Waiting for VPX at $NSIP (timeout: ${MAX_WAIT}s) ==="

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if timeout 5 bash -c "echo > /dev/tcp/$NSIP/22" 2>/dev/null; then
        echo "  SSH port open after ${ELAPSED}s"
        # VPX auth system needs time to initialize after SSH port opens
        echo "  Waiting 30s for auth system to initialize..."
        sleep 30
        echo "=== VPX $NSIP is ready ==="
        exit 0
    fi
    echo "  Waiting... (${ELAPSED}s / ${MAX_WAIT}s)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "ERROR: VPX at $NSIP did not respond within ${MAX_WAIT}s"
exit 1
