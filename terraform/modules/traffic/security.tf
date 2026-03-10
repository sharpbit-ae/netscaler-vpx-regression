# =============================================================================
# Security Policies — Rewrite, Responder, Rate Limiting, Bot Blocking
# Maps: apply-traffic-management.sh steps 9-13
# =============================================================================

# --- Step 9: HTTP → HTTPS Redirect ---

resource "citrixadc_responderaction" "https_redirect" {
  name               = "rs_act_https_redirect"
  type               = "redirect"
  target             = "\"https://\" + HTTP.REQ.HOSTNAME + HTTP.REQ.URL"
  responsestatuscode = 301
}

resource "citrixadc_responderpolicy" "https_redirect" {
  name   = "rs_pol_https_redirect"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_responderaction.https_redirect.name
}

resource "citrixadc_csvserver_responderpolicy_binding" "http_redirect" {
  name       = citrixadc_csvserver.http.name
  policyname = citrixadc_responderpolicy.https_redirect.name
  priority   = 100
  bindpoint  = "REQUEST"
}

# --- Step 10: Security Headers (Response) ---
# Rule uses "true" instead of "HTTP.RES.IS_VALID" so headers are inserted
# even when NetScaler generates its own error responses (e.g. 503 backend DOWN).

resource "citrixadc_rewriteaction" "xframe" {
  name   = "rw_act_xframe"
  type   = "insert_http_header"
  target = "X-Frame-Options"
  stringbuilderexpr = "\"DENY\""
}

resource "citrixadc_rewritepolicy" "xframe" {
  name   = "rw_pol_security_headers"
  rule   = "true"
  action = citrixadc_rewriteaction.xframe.name
}

resource "citrixadc_rewriteaction" "nosniff" {
  name   = "rw_act_nosniff"
  type   = "insert_http_header"
  target = "X-Content-Type-Options"
  stringbuilderexpr = "\"nosniff\""
}

resource "citrixadc_rewritepolicy" "nosniff" {
  name   = "rw_pol_nosniff"
  rule   = "true"
  action = citrixadc_rewriteaction.nosniff.name
}

resource "citrixadc_rewriteaction" "xss" {
  name   = "rw_act_xss"
  type   = "insert_http_header"
  target = "X-XSS-Protection"
  stringbuilderexpr = "\"1; mode=block\""
}

resource "citrixadc_rewritepolicy" "xss" {
  name   = "rw_pol_xss"
  rule   = "true"
  action = citrixadc_rewriteaction.xss.name
}

resource "citrixadc_rewriteaction" "referrer" {
  name   = "rw_act_referrer"
  type   = "insert_http_header"
  target = "Referrer-Policy"
  stringbuilderexpr = "\"strict-origin-when-cross-origin\""
}

resource "citrixadc_rewritepolicy" "referrer" {
  name   = "rw_pol_referrer"
  rule   = "true"
  action = citrixadc_rewriteaction.referrer.name
}

resource "citrixadc_rewriteaction" "permissions" {
  name   = "rw_act_permissions"
  type   = "insert_http_header"
  target = "Permissions-Policy"
  stringbuilderexpr = "\"geolocation=(), camera=(), microphone=()\""
}

resource "citrixadc_rewritepolicy" "permissions" {
  name   = "rw_pol_permissions"
  rule   = "true"
  action = citrixadc_rewriteaction.permissions.name
}

resource "citrixadc_rewriteaction" "csp" {
  name   = "rw_act_csp"
  type   = "insert_http_header"
  target = "Content-Security-Policy"
  stringbuilderexpr = "\"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\""
}

resource "citrixadc_rewritepolicy" "csp" {
  name   = "rw_pol_csp"
  rule   = "true"
  action = citrixadc_rewriteaction.csp.name
}

resource "citrixadc_rewriteaction" "hsts" {
  name   = "rw_act_hsts"
  type   = "insert_http_header"
  target = "Strict-Transport-Security"
  stringbuilderexpr = "\"max-age=31536000; includeSubDomains; preload\""
}

resource "citrixadc_rewritepolicy" "hsts" {
  name   = "rw_pol_hsts"
  rule   = "true"
  action = citrixadc_rewriteaction.hsts.name
}

resource "citrixadc_rewriteaction" "del_server" {
  name   = "rw_act_del_server"
  type   = "delete_http_header"
  target = "Server"
}

resource "citrixadc_rewritepolicy" "del_server" {
  name   = "rw_pol_del_server"
  rule   = "true"
  action = citrixadc_rewriteaction.del_server.name
}

resource "citrixadc_rewriteaction" "del_powered" {
  name   = "rw_act_del_powered"
  type   = "delete_http_header"
  target = "X-Powered-By"
}

resource "citrixadc_rewritepolicy" "del_powered" {
  name   = "rw_pol_del_powered"
  rule   = "true"
  action = citrixadc_rewriteaction.del_powered.name
}

resource "citrixadc_rewriteaction" "del_aspnet" {
  name   = "rw_act_del_aspnet"
  type   = "delete_http_header"
  target = "X-AspNet-Version"
}

resource "citrixadc_rewritepolicy" "del_aspnet" {
  name   = "rw_pol_del_aspnet"
  rule   = "true"
  action = citrixadc_rewriteaction.del_aspnet.name
}

# --- Bind response rewrite policies to HTTPS CS vserver ---
# gotopriorityexpression = "NEXT" ensures ALL policies evaluate in sequence.
# Without it, evaluation stops after the first match (default: END).

resource "citrixadc_csvserver_rewritepolicy_binding" "xframe" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.xframe.name
  priority               = 100
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "nosniff" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.nosniff.name
  priority               = 110
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "xss" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.xss.name
  priority               = 120
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "referrer" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.referrer.name
  priority               = 130
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "permissions" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.permissions.name
  priority               = 140
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "csp" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.csp.name
  priority               = 150
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "hsts" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.hsts.name
  priority               = 155
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "del_server" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.del_server.name
  priority               = 200
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "del_powered" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.del_powered.name
  priority               = 210
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "del_aspnet" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.del_aspnet.name
  priority               = 220
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "END"
}

# --- Step 11: Request Headers (XFF, X-Real-IP, etc.) ---

resource "citrixadc_rewriteaction" "xff" {
  name              = "rw_act_xff"
  type              = "insert_http_header"
  target            = "X-Forwarded-For"
  stringbuilderexpr = "CLIENT.IP.SRC"
}

resource "citrixadc_rewritepolicy" "xff" {
  name   = "rw_pol_xff"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_rewriteaction.xff.name
}

resource "citrixadc_rewriteaction" "xrealip" {
  name              = "rw_act_xrealip"
  type              = "insert_http_header"
  target            = "X-Real-IP"
  stringbuilderexpr = "CLIENT.IP.SRC"
}

resource "citrixadc_rewritepolicy" "xrealip" {
  name   = "rw_pol_xrealip"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_rewriteaction.xrealip.name
}

resource "citrixadc_rewriteaction" "xproto" {
  name              = "rw_act_xproto"
  type              = "insert_http_header"
  target            = "X-Forwarded-Proto"
  stringbuilderexpr = "\"https\""
}

resource "citrixadc_rewritepolicy" "xproto" {
  name   = "rw_pol_xproto"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_rewriteaction.xproto.name
}

resource "citrixadc_rewriteaction" "reqid" {
  name              = "rw_act_reqid"
  type              = "insert_http_header"
  target            = "X-Request-ID"
  stringbuilderexpr = "CLIENT.TCP.SRCPORT.TYPECAST_TEXT_T + \"-\" + SYS.TIME"
}

resource "citrixadc_rewritepolicy" "reqid" {
  name   = "rw_pol_reqid"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_rewriteaction.reqid.name
}

# --- Bind request rewrite policies to HTTPS CS vserver ---

resource "citrixadc_csvserver_rewritepolicy_binding" "xff" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.xff.name
  priority   = 100
  bindpoint  = "REQUEST"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "xrealip" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.xrealip.name
  priority   = 110
  bindpoint  = "REQUEST"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "xproto" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.xproto.name
  priority   = 120
  bindpoint  = "REQUEST"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "reqid" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.reqid.name
  priority   = 130
  bindpoint  = "REQUEST"
}

# --- Step 11b: Additional Security Headers ---

resource "citrixadc_rewriteaction" "download_options" {
  name              = "rw_act_download_options"
  type              = "insert_http_header"
  target            = "X-Download-Options"
  stringbuilderexpr = "\"noopen\""
}

resource "citrixadc_rewritepolicy" "download_options" {
  name   = "rw_pol_download_options"
  rule   = "true"
  action = citrixadc_rewriteaction.download_options.name
}

resource "citrixadc_rewriteaction" "cross_domain" {
  name              = "rw_act_cross_domain"
  type              = "insert_http_header"
  target            = "X-Permitted-Cross-Domain-Policies"
  stringbuilderexpr = "\"none\""
}

resource "citrixadc_rewritepolicy" "cross_domain" {
  name   = "rw_pol_cross_domain"
  rule   = "true"
  action = citrixadc_rewriteaction.cross_domain.name
}

resource "citrixadc_rewriteaction" "cache_control" {
  name              = "rw_act_cache_control"
  type              = "insert_http_header"
  target            = "Cache-Control"
  stringbuilderexpr = "\"no-store, no-cache, must-revalidate, private\""
}

resource "citrixadc_rewritepolicy" "cache_control" {
  name   = "rw_pol_cache_control"
  rule   = "HTTP.REQ.URL.CONTAINS(\"/api/\") || HTTP.REQ.URL.CONTAINS(\"/login\") || HTTP.REQ.URL.CONTAINS(\"/auth\")"
  action = citrixadc_rewriteaction.cache_control.name
}

# --- CORS Headers (conditional on Origin header presence) ---

resource "citrixadc_rewriteaction" "cors_origin" {
  name              = "rw_act_cors_origin"
  type              = "insert_http_header"
  target            = "Access-Control-Allow-Origin"
  stringbuilderexpr = "HTTP.REQ.HEADER(\"Origin\")"
}

resource "citrixadc_rewriteaction" "cors_methods" {
  name              = "rw_act_cors_methods"
  type              = "insert_http_header"
  target            = "Access-Control-Allow-Methods"
  stringbuilderexpr = "\"GET, POST, PUT, DELETE, OPTIONS\""
}

resource "citrixadc_rewriteaction" "cors_headers" {
  name              = "rw_act_cors_headers"
  type              = "insert_http_header"
  target            = "Access-Control-Allow-Headers"
  stringbuilderexpr = "\"Content-Type, Authorization, X-Requested-With\""
}

resource "citrixadc_rewriteaction" "cors_credentials" {
  name              = "rw_act_cors_credentials"
  type              = "insert_http_header"
  target            = "Access-Control-Allow-Credentials"
  stringbuilderexpr = "\"true\""
}

resource "citrixadc_rewriteaction" "cors_maxage" {
  name              = "rw_act_cors_maxage"
  type              = "insert_http_header"
  target            = "Access-Control-Max-Age"
  stringbuilderexpr = "\"86400\""
}

resource "citrixadc_rewritepolicy" "cors_origin" {
  name   = "rw_pol_cors_origin"
  rule   = "HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0) && HTTP.REQ.HEADER(\"Origin\").CONTAINS_ANY(\"ps_allowed_origins\")"
  action = citrixadc_rewriteaction.cors_origin.name
}

resource "citrixadc_rewritepolicy" "cors_methods" {
  name   = "rw_pol_cors_methods"
  rule   = "HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0) && HTTP.REQ.HEADER(\"Origin\").CONTAINS_ANY(\"ps_allowed_origins\")"
  action = citrixadc_rewriteaction.cors_methods.name
}

resource "citrixadc_rewritepolicy" "cors_headers" {
  name   = "rw_pol_cors_headers"
  rule   = "HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0) && HTTP.REQ.HEADER(\"Origin\").CONTAINS_ANY(\"ps_allowed_origins\")"
  action = citrixadc_rewriteaction.cors_headers.name
}

resource "citrixadc_rewritepolicy" "cors_credentials" {
  name   = "rw_pol_cors_credentials"
  rule   = "HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0) && HTTP.REQ.HEADER(\"Origin\").CONTAINS_ANY(\"ps_allowed_origins\")"
  action = citrixadc_rewriteaction.cors_credentials.name
}

resource "citrixadc_rewritepolicy" "cors_maxage" {
  name   = "rw_pol_cors_maxage"
  rule   = "HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0) && HTTP.REQ.HEADER(\"Origin\").CONTAINS_ANY(\"ps_allowed_origins\")"
  action = citrixadc_rewriteaction.cors_maxage.name
}

# Bind new response headers
resource "citrixadc_csvserver_rewritepolicy_binding" "download_options" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.download_options.name
  priority               = 160
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cross_domain" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cross_domain.name
  priority               = 170
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cache_control" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cache_control.name
  priority               = 180
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cors_origin" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cors_origin.name
  priority               = 250
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cors_methods" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cors_methods.name
  priority               = 260
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cors_headers" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cors_headers.name
  priority               = 270
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cors_credentials" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cors_credentials.name
  priority               = 280
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "NEXT"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "cors_maxage" {
  name                   = citrixadc_csvserver.https.name
  policyname             = citrixadc_rewritepolicy.cors_maxage.name
  priority               = 290
  bindpoint              = "RESPONSE"
  gotopriorityexpression = "END"
}

# --- CORS Preflight (OPTIONS) fast-path ---

resource "citrixadc_responderaction" "cors_preflight" {
  name   = "rs_act_cors_preflight"
  type   = "respondwith"
  target = "\"HTTP/1.1 204 No Content\\r\\nAccess-Control-Allow-Origin: *\\r\\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\\r\\nAccess-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With\\r\\nAccess-Control-Max-Age: 86400\\r\\nContent-Length: 0\\r\\n\\r\\n\""
}

resource "citrixadc_responderpolicy" "cors_preflight" {
  name   = "rs_pol_cors_preflight"
  rule   = "HTTP.REQ.METHOD.EQ(OPTIONS) && HTTP.REQ.HEADER(\"Origin\").LENGTH.GT(0)"
  action = citrixadc_responderaction.cors_preflight.name
}

resource "citrixadc_csvserver_responderpolicy_binding" "cors_preflight" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_responderpolicy.cors_preflight.name
  priority   = 25
  bindpoint  = "REQUEST"
}

# --- Step 11c: Hardened fallback when backends are DOWN ---
# NetScaler's internal 503 bypasses the rewrite engine, so security headers
# never get applied. This responder catches all requests and returns a
# hardened 503 with all security headers embedded when maintenance mode is off
# but no backend could serve the request. Bound at priority 50 (after bot=40,
# before maintenance=30).

resource "citrixadc_responderaction" "hardened_503" {
  name   = "rs_act_hardened_503"
  type   = "respondwith"
  target = "\"HTTP/1.1 503 Service Unavailable\\r\\nX-Frame-Options: DENY\\r\\nX-Content-Type-Options: nosniff\\r\\nX-XSS-Protection: 1; mode=block\\r\\nReferrer-Policy: strict-origin-when-cross-origin\\r\\nPermissions-Policy: geolocation=(), camera=(), microphone=()\\r\\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\\r\\nStrict-Transport-Security: max-age=31536000; includeSubDomains; preload\\r\\nCache-Control: no-store, no-cache\\r\\nContent-Type: text/html\\r\\nContent-Length: 63\\r\\n\\r\\n<html><body><h1>503 Service Unavailable</h1></body></html>\""
}

resource "citrixadc_responderpolicy" "hardened_503" {
  name   = "rs_pol_hardened_503"
  rule   = "SYS.VSERVER(\"${citrixadc_lbvserver.web.name}\").ACTIVESERVICES.EQ(0) && SYS.VSERVER(\"${citrixadc_lbvserver.web_ssl.name}\").ACTIVESERVICES.EQ(0) && SYS.VSERVER(\"${citrixadc_lbvserver.api.name}\").ACTIVESERVICES.EQ(0)"
  action = citrixadc_responderaction.hardened_503.name
}

resource "citrixadc_csvserver_responderpolicy_binding" "hardened_503" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_responderpolicy.hardened_503.name
  priority   = 50
  bindpoint  = "REQUEST"
}

# --- Step 12: Bot Blocking ---

resource "citrixadc_policypatset" "bad_useragents" {
  name = "ps_bad_useragents"
}

resource "citrixadc_policypatset_pattern_binding" "ua_sqlmap" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "sqlmap"
  index   = 1
}

resource "citrixadc_policypatset_pattern_binding" "ua_nikto" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nikto"
  index   = 2
}

resource "citrixadc_policypatset_pattern_binding" "ua_masscan" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "masscan"
  index   = 3
}

resource "citrixadc_policypatset_pattern_binding" "ua_nmap" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nmap"
  index   = 4
}

resource "citrixadc_policypatset_pattern_binding" "ua_dirbuster" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "dirbuster"
  index   = 5
}

resource "citrixadc_policypatset_pattern_binding" "ua_gobuster" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "gobuster"
  index   = 6
}

resource "citrixadc_policypatset_pattern_binding" "ua_wpscan" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "wpscan"
  index   = 7
}

resource "citrixadc_policypatset_pattern_binding" "ua_nuclei" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nuclei"
  index   = 8
}

resource "citrixadc_policypatset_pattern_binding" "ua_zmeu" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "ZmEu"
  index   = 9
}

resource "citrixadc_policypatset_pattern_binding" "ua_python" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "python-requests"
  index   = 10
}

resource "citrixadc_responderaction" "block_bot" {
  name   = "rs_act_block_bot"
  type   = "respondwith"
  target = "\"HTTP/1.1 403 Forbidden\\r\\nX-Frame-Options: DENY\\r\\nX-Content-Type-Options: nosniff\\r\\nX-XSS-Protection: 1; mode=block\\r\\nReferrer-Policy: strict-origin-when-cross-origin\\r\\nPermissions-Policy: geolocation=(), camera=(), microphone=()\\r\\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'\\r\\nStrict-Transport-Security: max-age=31536000; includeSubDomains; preload\\r\\nCache-Control: no-store, no-cache\\r\\nContent-Length: 0\\r\\n\\r\\n\""
}

resource "citrixadc_responderpolicy" "block_bot" {
  name   = "rs_pol_block_bot"
  rule   = "HTTP.REQ.HEADER(\"User-Agent\").TO_LOWER.CONTAINS_ANY(\"ps_bad_useragents\")"
  action = citrixadc_responderaction.block_bot.name
}

resource "citrixadc_csvserver_responderpolicy_binding" "block_bot" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_responderpolicy.block_bot.name
  priority   = 40
  bindpoint  = "REQUEST"
}
