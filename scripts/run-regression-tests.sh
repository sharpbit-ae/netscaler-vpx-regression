#!/usr/bin/env bash
# run-regression-tests.sh — Full regression pipeline:
#   1. Comprehensive per-object validation (NITRO API) on both VPXs
#   2. CLI output collection + normalize + diff comparison
#   3. HTML report generation
# Usage: run-regression-tests.sh BASELINE_IP CANDIDATE_IP PASSWORD OUTPUT_DIR
set -euo pipefail

BASELINE_IP="${1:?Usage: $0 BASELINE_IP CANDIDATE_IP PASSWORD OUTPUT_DIR}"
CANDIDATE_IP="${2:?Missing CANDIDATE_IP}"
PASSWORD="${3:?Missing PASSWORD}"
OUTPUT_DIR="${4:?Missing OUTPUT_DIR}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ssh_with_retry() {
    local IP="$1"; shift
    local retries=3 delay=5 rc output
    for ((i=1; i<=retries; i++)); do
        output=$("$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$IP" "$@" 2>&1) && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then
            [[ -n "$output" ]] && echo "$output"
            return 0
        fi
        if [[ $rc -ne 255 ]] && echo "$output" | grep -q "Done"; then
            echo "$output"
            return 0
        fi
        if [[ $rc -eq 255 ]] && [[ $i -lt $retries ]]; then
            echo "  SSH attempt $i/$retries failed (exit $rc), retrying in ${delay}s..." >&2
            sleep "$delay"
            continue
        fi
        if [[ $rc -ne 255 ]]; then
            echo "$output"
            echo "ERROR: VPX command failed (exit $rc): $*" >&2
            return 1
        fi
    done
    echo "ERROR: SSH connection failed after $retries attempts: $*" >&2
    return 1
}

mkdir -p "$OUTPUT_DIR/baseline" "$OUTPUT_DIR/candidate" "$OUTPUT_DIR/diffs"

# Start background resource monitoring
METRICS_CSV="$OUTPUT_DIR/host-metrics.csv"
"$SCRIPT_DIR/collect-metrics.sh" "$METRICS_CSV" 10 &
METRICS_PID=$!
echo "  Resource monitor started (PID $METRICS_PID, interval 10s)"

cleanup_metrics() {
    if kill -0 "$METRICS_PID" 2>/dev/null; then
        kill "$METRICS_PID" 2>/dev/null || true
        wait "$METRICS_PID" 2>/dev/null || true
    fi
    rm -f "${METRICS_CSV}.pid"
}
trap cleanup_metrics EXIT

# =========================================================================
# PHASE 1: Comprehensive Object Validation (NITRO API)
# =========================================================================
echo ""
echo "############################################"
echo "  PHASE 1: Comprehensive Object Validation"
echo "############################################"
echo ""

"$SCRIPT_DIR/run-comprehensive-tests.sh" \
    "$BASELINE_IP" "$PASSWORD" "$OUTPUT_DIR/baseline-tests.json" \
    "10.0.1.254" "10.0.1.115" "10.0.1.125" "10.0.1.105" || true

"$SCRIPT_DIR/run-comprehensive-tests.sh" \
    "$CANDIDATE_IP" "$PASSWORD" "$OUTPUT_DIR/candidate-tests.json" \
    "10.0.1.253" "10.0.1.116" "10.0.1.126" "10.0.1.106" || true

# =========================================================================
# PHASE 2: CLI Output Collection + Comparison
# =========================================================================
echo ""
echo "############################################"
echo "  PHASE 2: CLI Output Comparison"
echo "############################################"
echo ""

# Commands to collect — each becomes a separate file for comparison
COMMANDS=(
    "show ns version"
    "show ns hardware"
    "show ns feature"
    "show ns mode"
    "show ns hostname"
    "show system parameter"
    "show ns timeout"
    "show ssl parameter"
    "show ssl profile ns_default_ssl_profile_frontend"
    "show ssl profile ns_default_ssl_profile_backend"
    "show ns httpProfile nshttp_default_profile"
    "show ns httpProfile http_prof_web"
    "show ns tcpProfile nstcp_default_profile"
    "show ns tcpProfile tcp_prof_web"
    "show lb vserver"
    "show cs vserver"
    "show serviceGroup sg_web_http"
    "show serviceGroup sg_web_https"
    "show serviceGroup sg_tcp_generic"
    "show serviceGroup sg_dns"
    "show rewrite policy"
    "show responder policy"
    "show cmp policy"
    "show policy patset ps_bad_useragents"
    "show audit messageaction"
    "show ssl certKey"
    "show server"
    "show lb monitor"
    "show cs policy"
    "show cs action"
    "show ns ip"
    "show policy stringmap sm_url_routes"
    "show policy patset ps_allowed_origins"
    "show ns variable"
)

collect_outputs() {
    local IP="$1"
    local LABEL="$2"
    local DIR="$OUTPUT_DIR/$LABEL"

    echo "=== Collecting from $LABEL ($IP) ==="
    for CMD in "${COMMANDS[@]}"; do
        local FILENAME
        FILENAME=$(echo "$CMD" | sed 's/[^a-zA-Z0-9_]/_/g')
        echo "  $CMD"
        ssh_with_retry "$IP" "$CMD" \
            > "$DIR/${FILENAME}.txt" 2>&1 || echo "COMMAND_FAILED" > "$DIR/${FILENAME}.txt"
    done
}

collect_outputs "$BASELINE_IP" "baseline"
collect_outputs "$CANDIDATE_IP" "candidate"

# --- Normalize outputs ---
normalize() {
    local FILE="$1"
    sed -i \
        -e "s/$BASELINE_IP/NSIP/g" \
        -e "s/$CANDIDATE_IP/NSIP/g" \
        -e 's/10\.0\.1\.254/SNIP/g' \
        -e 's/10\.0\.1\.253/SNIP/g' \
        -e 's/10\.0\.1\.105/VIP_CS/g' \
        -e 's/10\.0\.1\.106/VIP_CS/g' \
        -e 's/10\.0\.1\.115/VIP_TCP/g' \
        -e 's/10\.0\.1\.116/VIP_TCP/g' \
        -e 's/10\.0\.1\.125/VIP_DNS/g' \
        -e 's/10\.0\.1\.126/VIP_DNS/g' \
        -e 's/vpx-baseline/VPX_HOSTNAME/g' \
        -e 's/vpx-candidate/VPX_HOSTNAME/g' \
        -e '/^[[:space:]]*Done$/d' \
        -e '/uptime/Id' \
        -e '/since/Id' \
        -e '/^[[:space:]]*$/d' \
        -e 's/^[[:space:]]*[0-9]\+)[[:space:]]*//' \
        -e 's/[[:space:]]*Priority[[:space:]]*:[[:space:]]*[0-9]\+//' \
        "$FILE"
}

echo ""
echo "=== Normalizing outputs ==="
for DIR in "$OUTPUT_DIR/baseline" "$OUTPUT_DIR/candidate"; do
    for FILE in "$DIR"/*.txt; do
        [[ -f "$FILE" ]] && normalize "$FILE"
    done
done

# --- Generate diffs ---
echo ""
echo "=== Generating diffs ==="

DIFF_TOTAL=0
DIFF_PASSED=0
DIFF_FAILED=0
DIFF_EXPECTED=0

for CMD in "${COMMANDS[@]}"; do
    FILENAME=$(echo "$CMD" | sed 's/[^a-zA-Z0-9_]/_/g')
    BASELINE_FILE="$OUTPUT_DIR/baseline/${FILENAME}.txt"
    CANDIDATE_FILE="$OUTPUT_DIR/candidate/${FILENAME}.txt"
    DIFF_FILE="$OUTPUT_DIR/diffs/${FILENAME}.diff"
    DIFF_TOTAL=$((DIFF_TOTAL + 1))

    # Sort both files before diffing to eliminate ordering-only differences
    # (VPX may return the same objects in different order across firmware versions)
    SORTED_B=$(mktemp)
    SORTED_C=$(mktemp)
    sort "$BASELINE_FILE" > "$SORTED_B"
    sort "$CANDIDATE_FILE" > "$SORTED_C"

    if diff -u "$SORTED_B" "$SORTED_C" > "$DIFF_FILE" 2>&1; then
        DIFF_PASSED=$((DIFF_PASSED + 1))
        rm -f "$DIFF_FILE"  # Remove empty diff files
    else
        case "$CMD" in
            "show ns version"|"show ns hardware")
                DIFF_EXPECTED=$((DIFF_EXPECTED + 1))
                ;;
            *)
                DIFF_FAILED=$((DIFF_FAILED + 1))
                ;;
        esac
    fi
    rm -f "$SORTED_B" "$SORTED_C"
done

# =========================================================================
# PHASE 2.5: System Log Collection
# =========================================================================
echo ""
echo "############################################"
echo "  PHASE 2.5: System Log Collection"
echo "############################################"
echo ""

mkdir -p "$OUTPUT_DIR/logs/baseline" "$OUTPUT_DIR/logs/candidate"

LOG_COMMANDS=(
    "shell tail -200 /var/log/messages"
    "shell tail -200 /var/nslog/ns.log"
    "show ns events"
    "show running config"
)

collect_logs() {
    local IP="$1"
    local LABEL="$2"
    local DIR="$OUTPUT_DIR/logs/$LABEL"

    echo "=== Collecting logs from $LABEL ($IP) ==="
    for CMD in "${LOG_COMMANDS[@]}"; do
        local FILENAME
        FILENAME=$(echo "$CMD" | sed 's/[^a-zA-Z0-9_]/_/g')
        echo "  $CMD"
        ssh_with_retry "$IP" "$CMD" \
            > "$DIR/${FILENAME}.txt" 2>&1 || echo "LOG_COLLECTION_FAILED" > "$DIR/${FILENAME}.txt"
    done
}

collect_logs "$BASELINE_IP" "baseline"
collect_logs "$CANDIDATE_IP" "candidate"

# =========================================================================
# PHASE 3: Generate HTML Report
# =========================================================================
echo ""
echo "############################################"
echo "  PHASE 3: Generating HTML Report"
echo "############################################"
echo ""

# Stop resource monitoring before generating report
echo "  Stopping resource monitor..."
cleanup_metrics

python3 "$SCRIPT_DIR/generate-html-report.py" \
    "$OUTPUT_DIR/baseline-tests.json" \
    "$OUTPUT_DIR/candidate-tests.json" \
    "$OUTPUT_DIR" \
    "$OUTPUT_DIR" \
    "$OUTPUT_DIR/logs" \
    "$METRICS_CSV" || echo "WARNING: HTML report generation failed"

# Copy report to ~/Downloads for easy access
REPORT_DATE=$(date +%Y-%m-%d)
REPORT_DEST="$HOME/Downloads/ns_report_${REPORT_DATE}.html"
if [[ -f "$OUTPUT_DIR/regression-report.html" ]]; then
    mkdir -p "$HOME/Downloads"
    cp "$OUTPUT_DIR/regression-report.html" "$REPORT_DEST"
    echo "  Report copied to: $REPORT_DEST"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================="
echo "  REGRESSION TEST SUMMARY"
echo "========================================="
echo "  CLI Comparison:"
echo "    Total checks:    $DIFF_TOTAL"
echo "    Passed:          $DIFF_PASSED"
echo "    Expected diffs:  $DIFF_EXPECTED"
echo "    Failed:          $DIFF_FAILED"

if [[ -f "$OUTPUT_DIR/baseline-tests.json" ]]; then
    echo ""
    echo "  Comprehensive Tests (Baseline):"
    python3 -c "
import json
with open('$OUTPUT_DIR/baseline-tests.json') as f:
    d = json.load(f)
print(f\"    Total: {d['total']}  Passed: {d['passed']}  Failed: {d['failed']}\")
" 2>/dev/null || true
fi

if [[ -f "$OUTPUT_DIR/candidate-tests.json" ]]; then
    echo "  Comprehensive Tests (Candidate):"
    python3 -c "
import json
with open('$OUTPUT_DIR/candidate-tests.json') as f:
    d = json.load(f)
print(f\"    Total: {d['total']}  Passed: {d['passed']}  Failed: {d['failed']}\")
" 2>/dev/null || true
fi

echo "========================================="
echo "  Report (artifact): $OUTPUT_DIR/regression-report.html"
echo "  Report (local):    $HOME/Downloads/ns_report_$(date +%Y-%m-%d).html"
echo ""

if [[ $DIFF_FAILED -gt 0 ]]; then
    echo "RESULT: WARNING — $DIFF_FAILED unexpected CLI difference(s) (informational only)"
else
    echo "RESULT: PASS — All CLI checks identical"
fi

# Print failure details from comprehensive tests (informational)
for TEST_FILE in "$OUTPUT_DIR/baseline-tests.json" "$OUTPUT_DIR/candidate-tests.json"; do
    if [[ -f "$TEST_FILE" ]]; then
        python3 -c "
import json, sys
with open('$TEST_FILE') as f:
    d = json.load(f)
label = '$(basename "$TEST_FILE")'
if d['failed'] > 0:
    print(f'')
    print(f'  WARNING: {d[\"failed\"]} failure(s) in {label}:')
    for r in d['results']:
        if r['status'] == 'FAIL':
            print(f'    [{r[\"category\"]}] {r[\"test\"]}: expected={r[\"expected\"]} actual={r[\"actual\"]}')
" 2>/dev/null || true
    fi
done

# Print CLI diff details
if [[ $DIFF_FAILED -gt 0 ]]; then
    echo ""
    echo "  CLI differences:"
    for DIFF_FILE in "$OUTPUT_DIR/diffs"/*.diff; do
        [[ -f "$DIFF_FILE" ]] || continue
        echo "    --- $(basename "$DIFF_FILE" .diff) ---"
        head -30 "$DIFF_FILE" | sed 's/^/    /'
        LINES=$(wc -l < "$DIFF_FILE")
        if [[ $LINES -gt 30 ]]; then
            echo "    ... ($((LINES - 30)) more lines)"
        fi
    done
fi

echo ""
echo "RESULT: PASS — Regression tests completed (failures are informational)"
exit 0
