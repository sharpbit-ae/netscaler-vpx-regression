#!/usr/bin/env bash
# run-comprehensive-tests.sh — Validate every Terraform-managed object via NITRO API
# Outputs JSON test results for each VPX to be consumed by the HTML report generator.
# Usage: run-comprehensive-tests.sh NSIP PASSWORD OUTPUT_JSON [SNIP] [VIP_TCP] [VIP_DNS]
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP PASSWORD OUTPUT_JSON [SNIP] [VIP_TCP] [VIP_DNS]}"
PASSWORD="${2:?Missing PASSWORD}"
OUTPUT_JSON="${3:?Missing OUTPUT_JSON path}"
SNIP="${4:-10.0.1.254}"
VIP_TCP="${5:-10.0.1.115}"
VIP_DNS="${6:-10.0.1.125}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_TMP=$(mktemp)
trap 'rm -f "$RESULTS_TMP"' EXIT

# --- NITRO API helper ---
nitro_get() {
    local endpoint="$1"
    # Try HTTPS first (configured VPXs), fall back to HTTP (fresh VPXs)
    local response
    response=$(curl -sk -o - -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $PASSWORD" \
        "https://${NSIP}/nitro/v1/config/${endpoint}" 2>/dev/null)
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "000" ]]; then
        response=$(curl -s -o - -w "\n%{http_code}" \
            -H "Content-Type: application/json" \
            -H "X-NITRO-USER: nsroot" \
            -H "X-NITRO-PASS: $PASSWORD" \
            "http://${NSIP}/nitro/v1/config/${endpoint}" 2>/dev/null)
    fi
    echo "$response"
}

# --- Test framework ---
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# Write a test result as a TSV line to the temp file
# Fields: category, test_name, status, expected, actual, detail
record_result() {
    local category="$1" test_name="$2" status="$3" expected="$4" actual="$5" detail="${6:-}"
    TOTAL=$((TOTAL + 1))
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        FAIL) FAILED=$((FAILED + 1)) ;;
        WARN) WARNINGS=$((WARNINGS + 1)) ;;
    esac
    # Write tab-separated to temp file (replace tabs/newlines in values)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$category" "$test_name" "$status" \
        "$(echo "$expected" | tr '\t\n' '  ')" \
        "$(echo "$actual" | tr '\t\n' '  ')" \
        "$(echo "$detail" | tr '\t\n' '  ')" >> "$RESULTS_TMP"
}

# Extract a field value from NITRO JSON response
extract_field() {
    local body="$1" field="$2"
    python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    found = False
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            val = data[key]
            if isinstance(val, list) and len(val) > 0:
                print(str(val[0].get('$field', 'NOT_FOUND')))
            elif isinstance(val, dict):
                print(str(val.get('$field', 'NOT_FOUND')))
            else:
                print('NOT_FOUND')
            found = True
            break
    if not found:
        print('NOT_FOUND')
except Exception:
    print('PARSE_ERROR')
" <<< "$body"
}

# Check a NITRO resource exists and optionally verify a field
# Usage: check_resource CATEGORY RESOURCE_PATH [FIELD EXPECTED_VALUE]
check_resource() {
    local category="$1" resource_path="$2"
    local field="${3:-}" expected_value="${4:-}"

    local response http_code body
    response=$(nitro_get "$resource_path")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "${resource_path} exists" "FAIL" "HTTP 200" "HTTP $http_code" "Resource not found"
        return 0
    fi

    record_result "$category" "${resource_path} exists" "PASS" "exists" "exists"

    if [[ -n "$field" ]] && [[ -n "$expected_value" ]]; then
        local actual_value
        actual_value=$(extract_field "$body" "$field")
        if [[ "${actual_value,,}" == "${expected_value,,}" ]]; then
            record_result "$category" "${resource_path} ${field}" "PASS" "$expected_value" "$actual_value"
        else
            record_result "$category" "${resource_path} ${field}" "FAIL" "$expected_value" "$actual_value"
        fi
    fi
    return 0
}

# Check feature/mode status via SSH show commands
# VPX uses ON/OFF in output; we accept ENABLED/DISABLED as expected values
check_feature() {
    local category="$1" name="$2" expected="$3" show_output="$4"
    # Strip category prefix (feature:LB -> LB, mode:FR -> FR)
    local short_name="${name#*:}"
    # Map expected to VPX output format
    local vpx_expected="$expected"
    [[ "$expected" == "ENABLED" ]] && vpx_expected="ON"
    [[ "$expected" == "DISABLED" ]] && vpx_expected="OFF"
    # Match: acronym column followed by status column
    if echo "$show_output" | grep -qiE "[[:space:]]${short_name}[[:space:]]+${vpx_expected}"; then
        record_result "$category" "$name" "PASS" "$expected" "$expected"
    else
        record_result "$category" "$name" "FAIL" "$expected" "not matching" "Pattern: ${short_name} ${vpx_expected}"
    fi
}

# Check a binding exists in a NITRO binding list
# Usage: check_binding CATEGORY BINDING_PATH MATCH_FIELD MATCH_VALUE [VERIFY_FIELD VERIFY_VALUE]
check_binding() {
    local category="$1" binding_path="$2" match_field="$3" match_value="$4"
    local verify_field="${5:-}" verify_value="${6:-}"

    local response http_code body
    response=$(nitro_get "$binding_path")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "binding:${binding_path} ${match_field}=${match_value}" "FAIL" "HTTP 200" "HTTP $http_code"
        return 0
    fi

    local result
    result=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            items = data[key] if isinstance(data[key], list) else [data[key]]
            for item in items:
                if str(item.get('$match_field', '')).lower() == '$match_value'.lower():
                    if '$verify_field':
                        print(str(item.get('$verify_field', 'NOT_FOUND')))
                    else:
                        print('FOUND')
                    sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('PARSE_ERROR')
" <<< "$body")

    if [[ "$result" == "NOT_FOUND" ]] || [[ "$result" == "PARSE_ERROR" ]]; then
        record_result "$category" "binding:${match_field}=${match_value} in ${binding_path}" "FAIL" "bound" "$result"
        return 0
    fi

    if [[ -n "$verify_field" ]] && [[ -n "$verify_value" ]]; then
        if [[ "${result,,}" == "${verify_value,,}" ]]; then
            record_result "$category" "binding:${match_field}=${match_value} ${verify_field}" "PASS" "$verify_value" "$result"
        else
            record_result "$category" "binding:${match_field}=${match_value} ${verify_field}" "FAIL" "$verify_value" "$result"
        fi
    else
        record_result "$category" "binding:${match_field}=${match_value} in ${binding_path}" "PASS" "bound" "bound"
    fi
    return 0
}

# Check SSL certificate expiry (days remaining)
check_cert_expiry() {
    local category="$1" certkey_name="$2" min_days="${3:-30}"

    local response http_code body
    response=$(nitro_get "sslcertkey/$certkey_name")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "FAIL" "exists" "HTTP $http_code"
        return 0
    fi

    local days_remaining
    days_remaining=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            items = data[key] if isinstance(data[key], list) else [data[key]]
            print(str(items[0].get('daystoexpiration', 'UNKNOWN')))
            sys.exit(0)
    print('UNKNOWN')
except Exception:
    print('UNKNOWN')
" <<< "$body")

    if [[ "$days_remaining" == "UNKNOWN" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "WARN" ">=${min_days}d" "unknown"
        return 0
    fi

    if [[ "$days_remaining" -ge "$min_days" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "PASS" ">=${min_days}d" "${days_remaining}d"
    else
        record_result "$category" "cert:${certkey_name} expiry" "FAIL" ">=${min_days}d" "${days_remaining}d" "Certificate expiring soon!"
    fi
    return 0
}

echo "=== Comprehensive Testing: $NSIP ==="

# Collect SSH outputs once for feature/mode checks
feature_output=$("$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns feature" 2>/dev/null || echo "SSH_FAILED")
mode_output=$("$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns mode" 2>/dev/null || echo "SSH_FAILED")

# =========================================================================
# 1. SYSTEM IDENTITY & NETWORK
# =========================================================================
echo "  [1/16] System identity and network..."

check_resource "System" "nshostname"
check_resource "System" "dnsnameserver/1.1.1.1"
check_resource "System" "dnsnameserver/8.8.8.8"
check_resource "System" "ntpserver/pool.ntp.org"

# =========================================================================
# 2. SECURITY PARAMETERS
# =========================================================================
echo "  [2/16] Security parameters..."

check_resource "Security" "systemparameter" "strongpassword" "enableall"
check_resource "Security" "systemparameter" "minpasswordlen" "8"
check_resource "Security" "systemparameter" "timeout" "600"
check_resource "Security" "systemparameter" "maxclient" "10"
check_resource "Security" "systemparameter" "restrictedtimeout" "ENABLED"

check_resource "Security" "nsrpcnode/$NSIP" "secure" "ON"
check_resource "Security" "nsparam" "cookieversion" "1"

# =========================================================================
# 3. FEATURES & MODES
# =========================================================================
echo "  [3/16] Features and modes..."

for feat in LB CS SSL Rewrite Responder AppFlow CMP SSLVPN; do
    check_feature "Features" "feature:$feat" "ENABLED" "$feature_output"
done
check_feature "Features" "feature:CH" "DISABLED" "$feature_output"

for mode in FR TCPB Edge L3 ULFD; do
    check_feature "Modes" "mode:$mode" "ENABLED" "$mode_output"
done

# =========================================================================
# 4. HTTP & TCP PROFILES
# =========================================================================
echo "  [4/16] HTTP and TCP profiles..."

check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "dropinvalreqs" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "markhttp09inval" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "markconnreqinval" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "marktracereqinval" "ENABLED"

check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "rstwindowattenuate" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "spoofsyndrop" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "ecn" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "dsack" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "frto" "ENABLED"

check_resource "Profiles" "nstcpprofile/tcp_prof_web" "flavor" "CUBIC"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "ka" "ENABLED"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "ws" "ENABLED"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "sack" "ENABLED"

check_resource "Profiles" "nshttpprofile/http_prof_web" "http2" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "websocket" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "dropinvalreqs" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "conmultiplex" "ENABLED"

# =========================================================================
# 5. SSL CONFIGURATION
# =========================================================================
echo "  [5/16] SSL configuration..."

check_resource "SSL" "sslparameter" "defaultprofile" "ENABLED"

check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "ssl3" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls1" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls11" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls12" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls13" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "denysslreneg" "NONSECURE"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "hsts" "ENABLED"

check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "ssl3" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls1" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls11" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls12" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls13" "ENABLED"

# =========================================================================
# 6. CERTIFICATES
# =========================================================================
echo "  [6/16] SSL certificates..."

check_resource "Certificates" "sslcertkey/lab-ca"
check_resource "Certificates" "sslcertkey/wildcard.lab.local"
check_resource "Certificates" "sslcertkey/wildcard.lab.local" "linkcertkeyname" "lab-ca"

for cert_file in lab-ca.crt wildcard.lab.local.crt wildcard.lab.local.key; do
    response=$(nitro_get "systemfile?args=filename:${cert_file},filelocation:%2Fnsconfig%2Fssl")
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        record_result "Certificates" "file:${cert_file}" "PASS" "exists" "exists"
    else
        record_result "Certificates" "file:${cert_file}" "FAIL" "exists" "HTTP $http_code"
    fi
done

# =========================================================================
# 7. SERVERS, MONITORS, SERVICE GROUPS
# =========================================================================
echo "  [7/16] Servers, monitors, service groups..."

check_resource "Servers" "server/srv_host01" "ipaddress" "10.0.1.1"
check_resource "Servers" "server/srv_opnsense" "ipaddress" "10.0.1.2"

check_resource "Monitors" "lbmonitor/mon_http_200" "type" "HTTP"
check_resource "Monitors" "lbmonitor/mon_tcp_quick" "type" "TCP"
check_resource "Monitors" "lbmonitor/mon_https_200" "type" "HTTP-ECV"

for sg in sg_web_http sg_web_https sg_tcp_generic sg_dns; do
    check_resource "ServiceGroups" "servicegroup/$sg"
done

check_resource "ServiceGroups" "servicegroup/sg_web_http" "servicetype" "HTTP"
check_resource "ServiceGroups" "servicegroup/sg_web_https" "servicetype" "SSL"
check_resource "ServiceGroups" "servicegroup/sg_tcp_generic" "servicetype" "TCP"
check_resource "ServiceGroups" "servicegroup/sg_dns" "servicetype" "DNS"

# =========================================================================
# 8. LB & CS VSERVERS
# =========================================================================
echo "  [8/16] LB and CS vservers..."

check_resource "LBVservers" "lbvserver/lb_vsrv_web" "servicetype" "HTTP"
check_resource "LBVservers" "lbvserver/lb_vsrv_web" "lbmethod" "ROUNDROBIN"
check_resource "LBVservers" "lbvserver/lb_vsrv_web_ssl" "servicetype" "SSL"
check_resource "LBVservers" "lbvserver/lb_vsrv_api" "servicetype" "HTTP"
check_resource "LBVservers" "lbvserver/lb_vsrv_api" "lbmethod" "LEASTCONNECTION"
check_resource "LBVservers" "lbvserver/lb_vsrv_tcp" "servicetype" "TCP"
check_resource "LBVservers" "lbvserver/lb_vsrv_dns" "servicetype" "DNS"

check_resource "CSVservers" "csvserver/cs_vsrv_https" "servicetype" "SSL"
check_resource "CSVservers" "csvserver/cs_vsrv_https" "port" "443"
check_resource "CSVservers" "csvserver/cs_vsrv_http" "servicetype" "HTTP"
check_resource "CSVservers" "csvserver/cs_vsrv_http" "port" "80"

check_resource "CSPolicies" "cspolicy/cs_pol_api"
check_resource "CSPolicies" "cspolicy/cs_pol_static"
check_resource "CSPolicies" "cspolicy/cs_pol_app"
check_resource "CSPolicies" "csaction/cs_act_api" "targetlbvserver" "lb_vsrv_api"
check_resource "CSPolicies" "csaction/cs_act_web" "targetlbvserver" "lb_vsrv_web"

# =========================================================================
# 9. SECURITY POLICIES
# =========================================================================
echo "  [9/16] Security policies..."

# Rewrite actions (security headers + request headers)
for rw_act in rw_act_xframe rw_act_nosniff rw_act_xss rw_act_referrer rw_act_permissions rw_act_csp rw_act_del_server rw_act_del_powered rw_act_del_aspnet rw_act_xff rw_act_xrealip rw_act_xproto rw_act_reqid rw_act_log_req rw_act_log_res rw_act_download_options rw_act_cross_domain rw_act_cache_control rw_act_cors_origin rw_act_cors_methods rw_act_cors_headers rw_act_cors_credentials rw_act_cors_maxage; do
    check_resource "Rewrite" "rewriteaction/$rw_act"
done

# Rewrite policies
for rw_pol in rw_pol_security_headers rw_pol_nosniff rw_pol_xss rw_pol_referrer rw_pol_permissions rw_pol_csp rw_pol_del_server rw_pol_del_powered rw_pol_del_aspnet rw_pol_xff rw_pol_xrealip rw_pol_xproto rw_pol_reqid rw_pol_log_req rw_pol_log_res rw_pol_download_options rw_pol_cross_domain rw_pol_cache_control rw_pol_cors_origin rw_pol_cors_methods rw_pol_cors_headers rw_pol_cors_credentials rw_pol_cors_maxage; do
    check_resource "Rewrite" "rewritepolicy/$rw_pol"
done

# Responder actions/policies (including CORS preflight)
for rs_act in rs_act_https_redirect rs_act_block_bot rs_act_maintenance rs_act_cors_preflight; do
    check_resource "Responder" "responderaction/$rs_act"
done
for rs_pol in rs_pol_https_redirect rs_pol_block_bot rs_pol_maint1 rs_pol_cors_preflight; do
    check_resource "Responder" "responderpolicy/$rs_pol"
done

# Bot blocking
check_resource "BotBlocking" "policypatset/ps_bad_useragents"

# =========================================================================
# 10. EXTRA OBJECTS
# =========================================================================
echo "  [10/16] Compression, audit, maintenance, AppExpert..."

for cmp_pol in cmp_pol_text cmp_pol_json cmp_pol_js cmp_pol_xml cmp_pol_svg; do
    check_resource "Compression" "cmppolicy/$cmp_pol"
done

check_resource "Audit" "auditmessageaction/audit_act_request"
check_resource "Audit" "auditmessageaction/audit_act_response"

check_resource "AppExpert" "policystringmap/sm_url_routes"
check_resource "AppExpert" "policypatset/ps_allowed_origins"

check_resource "Maintenance" "nsvariable/v_maintenance"

check_resource "Timeouts" "nstimeout" "zombie" "600"
check_resource "Timeouts" "nstimeout" "halfclose" "300"
check_resource "Timeouts" "nstimeout" "nontcpzombie" "300"

# Management access
check_resource "Management" "nsip/$NSIP" "gui" "SECUREONLY"
check_resource "Management" "nsip/$NSIP" "restrictaccess" "ENABLED"

# =========================================================================
# 11. BINDING VALIDATIONS
# =========================================================================
echo "  [11/16] Service group member bindings..."

# Service group member bindings (verify correct servers and ports)
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_http" "servername" "srv_host01" "port" "80"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_http" "servername" "srv_opnsense" "port" "80"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_https" "servername" "srv_host01" "port" "443"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_https" "servername" "srv_opnsense" "port" "443"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_tcp_generic" "servername" "srv_host01" "port" "8080"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_tcp_generic" "servername" "srv_opnsense" "port" "8080"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_dns" "servername" "srv_host01" "port" "53"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_dns" "servername" "srv_opnsense" "port" "53"

# Service group monitor bindings
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_web_http" "monitor_name" "mon_http_200"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_web_https" "monitor_name" "mon_https_200"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_tcp_generic" "monitor_name" "mon_tcp_quick"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_dns" "monitor_name" "dns"

# =========================================================================
# 12. LB VSERVER BINDINGS
# =========================================================================
echo "  [12/16] LB vserver bindings..."

check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_web" "servicegroupname" "sg_web_http"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_web_ssl" "servicegroupname" "sg_web_https"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_api" "servicegroupname" "sg_web_http"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_tcp" "servicegroupname" "sg_tcp_generic"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_dns" "servicegroupname" "sg_dns"

# LB vserver persistence & method deep validation
check_resource "LBConfig" "lbvserver/lb_vsrv_web" "persistencetype" "COOKIEINSERT"
check_resource "LBConfig" "lbvserver/lb_vsrv_web" "cookiename" "NSLB"
check_resource "LBConfig" "lbvserver/lb_vsrv_web_ssl" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_api" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_tcp" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_tcp" "ipv46" "$VIP_TCP"
check_resource "LBConfig" "lbvserver/lb_vsrv_dns" "ipv46" "$VIP_DNS"

# =========================================================================
# 13. CS VSERVER BINDINGS
# =========================================================================
echo "  [13/16] CS vserver policy & SSL bindings..."

# CS policy bindings with priority verification
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_api" "priority" "100"
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_static" "priority" "110"
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_app" "priority" "120"

# SSL cert binding to CS vserver
check_binding "CSBindings" "sslvserver_sslcertkey_binding/cs_vsrv_https" "certkeyname" "wildcard.lab.local"

# Responder policy bindings on CS vservers
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_block_bot"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_maint1"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_cors_preflight"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_http" "policyname" "rs_pol_https_redirect"

# Rewrite policy bindings on HTTPS CS vserver (all response + request headers)
for rw_pol in rw_pol_security_headers rw_pol_nosniff rw_pol_xss rw_pol_referrer rw_pol_permissions rw_pol_csp rw_pol_del_server rw_pol_del_powered rw_pol_del_aspnet rw_pol_xff rw_pol_xrealip rw_pol_xproto rw_pol_reqid rw_pol_log_req rw_pol_log_res rw_pol_download_options rw_pol_cross_domain rw_pol_cache_control rw_pol_cors_origin rw_pol_cors_methods rw_pol_cors_headers rw_pol_cors_credentials rw_pol_cors_maxage; do
    check_binding "RWBindings" "csvserver_rewritepolicy_binding/cs_vsrv_https" "policyname" "$rw_pol"
done

# Compression policy bindings on HTTPS CS vserver
for cmp_pol in cmp_pol_text cmp_pol_json cmp_pol_js cmp_pol_xml cmp_pol_svg; do
    check_binding "CMPBindings" "csvserver_cmppolicy_binding/cs_vsrv_https" "policyname" "$cmp_pol"
done

# =========================================================================
# 14. DEEP VALUE VALIDATIONS
# =========================================================================
echo "  [14/16] Deep value validations..."

# TCP profile deep checks
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "nagle" "DISABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "maxburst" "10"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "initialcwnd" "16"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "oooqsize" "300"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "minrto" "400"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "ecn" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "timestamp" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "dsack" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "frto" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kaconnidletime" "300"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kamaxprobes" "5"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kaprobeinterval" "30"

# HTTP profile deep checks
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "http2maxconcurrentstreams" "128"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "http2maxheaderlistsize" "32768"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "maxreusepool" "0"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "dropextradata" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markhttp09inval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markconnreqinval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "marktracereqinval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markrfc7230noncompliantinval" "ENABLED"

# Monitor deep checks
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "interval" "10"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "resptimeout" "5"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "retries" "3"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "downtime" "15"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "lrtm" "ENABLED"
check_resource "MonitorDeep" "lbmonitor/mon_tcp_quick" "interval" "5"
check_resource "MonitorDeep" "lbmonitor/mon_tcp_quick" "resptimeout" "3"

# SSL profile deep checks
check_resource "SSLDeep" "sslprofile/ns_default_ssl_profile_frontend" "maxage" "31536000"

# =========================================================================
# 15. CERTIFICATE EXPIRY & CHAIN VALIDATION
# =========================================================================
echo "  [15/16] Certificate expiry and chain..."

check_cert_expiry "CertExpiry" "wildcard.lab.local" 30
check_cert_expiry "CertExpiry" "lab-ca" 30
check_resource "CertChain" "sslcertkey/wildcard.lab.local" "linkcertkeyname" "lab-ca"

# =========================================================================
# 16. SNIP & VIP NETWORK VERIFICATION
# =========================================================================
echo "  [16/16] Network IPs and patset patterns..."

# Verify SNIP exists
check_resource "Network" "nsip/$SNIP" "type" "SNIP"
check_resource "Network" "nsip/$SNIP" "mgmtaccess" "ENABLED"

# Verify bot blocking patset patterns (NITRO uses capital "String" field)
for ua_pattern in sqlmap nikto nmap nuclei masscan dirbuster gobuster python-requests; do
    check_binding "BotPatterns" "policypatset_pattern_binding/ps_bad_useragents" "String" "$ua_pattern"
done

# Verify allowed origins patset patterns
for origin in "https://app.lab.local" "https://api.lab.local" "https://lab.local"; do
    check_binding "OriginPatterns" "policypatset_pattern_binding/ps_allowed_origins" "String" "$origin"
done

# =========================================================================
# Write Results
# =========================================================================
echo ""
echo "========================================="
echo "  COMPREHENSIVE TEST SUMMARY ($NSIP)"
echo "========================================="
echo "  Total:    $TOTAL"
echo "  Passed:   $PASSED"
echo "  Failed:   $FAILED"
echo "  Warnings: $WARNINGS"
echo "========================================="

# Convert TSV results to JSON
python3 - "$RESULTS_TMP" "$OUTPUT_JSON" "$NSIP" "$TOTAL" "$PASSED" "$FAILED" "$WARNINGS" <<'PYEOF'
import json, sys

results_file = sys.argv[1]
output_file = sys.argv[2]
nsip = sys.argv[3]
total = int(sys.argv[4])
passed = int(sys.argv[5])
failed = int(sys.argv[6])
warnings = int(sys.argv[7])

results = []
with open(results_file) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 5:
            results.append({
                'category': parts[0],
                'test': parts[1],
                'status': parts[2],
                'expected': parts[3],
                'actual': parts[4],
                'detail': parts[5] if len(parts) > 5 else ''
            })

output = {
    'nsip': nsip,
    'total': total,
    'passed': passed,
    'failed': failed,
    'warnings': warnings,
    'results': results
}

with open(output_file, 'w') as f:
    json.dump(output, f, indent=2)

print(f'Results written to {output_file}')
PYEOF
