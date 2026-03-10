#!/usr/bin/env bash
# change-default-password.sh — Change VPX default nsroot password via SSH
#
# NITRO rejects the default password entirely (error 1047) on newer
# firmware. The SSH expect script handles the forced-change flow AND
# disables ForcePasswordChange + saves config from the same CLI session.
#
# Usage: change-default-password.sh NSIP OLD_PASSWORD NEW_PASSWORD [MAX_WAIT]
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP OLD_PASSWORD NEW_PASSWORD [MAX_WAIT_SECONDS]}"
OLD_PASSWORD="${2:?Missing OLD_PASSWORD}"
NEW_PASSWORD="${3:?Missing NEW_PASSWORD}"
MAX_WAIT="${4:-300}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Changing default nsroot password on $NSIP ==="

# Pre-flight: validate password meets VPX forced-change requirements
# (VPX gives misleading "matches default" error for policy violations)
if [[ ${#NEW_PASSWORD} -lt 8 ]]; then
    echo "ERROR: Password must be at least 8 characters (got ${#NEW_PASSWORD})"
    exit 1
fi
if ! [[ "$NEW_PASSWORD" =~ [A-Z] ]]; then
    echo "ERROR: Password must contain at least one uppercase letter"
    exit 1
fi
if ! [[ "$NEW_PASSWORD" =~ [a-z] ]]; then
    echo "ERROR: Password must contain at least one lowercase letter"
    exit 1
fi
if ! [[ "$NEW_PASSWORD" =~ [0-9] ]]; then
    echo "ERROR: Password must contain at least one digit"
    exit 1
fi
if ! [[ "$NEW_PASSWORD" =~ [^a-zA-Z0-9] ]]; then
    echo "ERROR: Password must contain at least one special character"
    exit 1
fi

# Wait for NITRO API (confirms VPX is ready)
echo "  Waiting for NITRO API (timeout: ${MAX_WAIT}s)..."
"$SCRIPT_DIR/wait-for-nitro.sh" "$NSIP" "$OLD_PASSWORD" "$MAX_WAIT"

# Change password + disable ForcePasswordChange via SSH
echo "  Changing password via SSH (forced change flow)..."
export _CHG_OLD_PASS="$OLD_PASSWORD"
export _CHG_NEW_PASS="$NEW_PASSWORD"
export _CHG_IP="$NSIP"
if ! expect "$SCRIPT_DIR/change-password-ssh.exp"; then
    echo "ERROR: SSH password change failed"
    exit 1
fi
echo "  SSH password change completed"

# Verify NITRO works with new password (retry up to 30s)
echo "  Verifying NITRO API with new password..."
VERIFIED=false
for i in $(seq 1 6); do
    VERIFY_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $NEW_PASSWORD" \
        "https://${NSIP}/nitro/v1/config/nsversion" 2>/dev/null) || VERIFY_CODE=0

    if [[ "$VERIFY_CODE" == "200" ]]; then
        echo "  Verified: NITRO accepts new password"
        VERIFIED=true
        break
    fi
    echo "  NITRO returned HTTP $VERIFY_CODE, retrying in 5s... ($i/6)"
    sleep 5
done

# Fallback: if SSH didn't change the password, try via NITRO API
if [[ "$VERIFIED" != "true" ]]; then
    echo "  SSH password change did not take effect, trying NITRO API fallback..."
    CHANGE_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $OLD_PASSWORD" \
        -d "{\"systemuser\": {\"username\": \"nsroot\", \"password\": \"$NEW_PASSWORD\"}}" \
        "https://${NSIP}/nitro/v1/config/systemuser" 2>/dev/null) || CHANGE_CODE=0

    if [[ "$CHANGE_CODE" != "200" ]]; then
        # Try HTTP fallback
        CHANGE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "X-NITRO-USER: nsroot" \
            -H "X-NITRO-PASS: $OLD_PASSWORD" \
            -d "{\"systemuser\": {\"username\": \"nsroot\", \"password\": \"$NEW_PASSWORD\"}}" \
            "http://${NSIP}/nitro/v1/config/systemuser" 2>/dev/null) || CHANGE_CODE=0
    fi

    if [[ "$CHANGE_CODE" == "200" ]]; then
        echo "  NITRO password change succeeded, verifying..."
        sleep 3
        VERIFY_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
            -H "Content-Type: application/json" \
            -H "X-NITRO-USER: nsroot" \
            -H "X-NITRO-PASS: $NEW_PASSWORD" \
            "https://${NSIP}/nitro/v1/config/nsversion" 2>/dev/null) || VERIFY_CODE=0
        if [[ "$VERIFY_CODE" == "200" ]]; then
            echo "  Verified: NITRO accepts new password (via API fallback)"
            VERIFIED=true
        fi
    else
        echo "  NITRO password change returned HTTP $CHANGE_CODE"
    fi
fi

if [[ "$VERIFIED" != "true" ]]; then
    echo "ERROR: Password change failed — neither SSH nor NITRO method worked"
    exit 1
fi

echo "=== Password changed on $NSIP ==="
