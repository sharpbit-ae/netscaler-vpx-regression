# =============================================================================
# Maintenance Mode, Compression, Audit Logging, AppExpert Objects
# Maps: apply-traffic-management.sh step 14
# =============================================================================

# --- Maintenance Mode ---

resource "citrixadc_nsvariable" "maintenance" {
  name  = "v_maintenance"
  type  = "ulong"
  scope = "global"
}

resource "citrixadc_nsassignment" "maintenance_off" {
  name     = "a_maintenance_off"
  variable = "$v_maintenance"
  set      = "0"

  depends_on = [citrixadc_nsvariable.maintenance]
}

resource "citrixadc_nsassignment" "maintenance_on" {
  name     = "a_maintenance_on"
  variable = "$v_maintenance"
  set      = "1"

  depends_on = [citrixadc_nsvariable.maintenance]
}

resource "citrixadc_responderaction" "maintenance" {
  name   = "rs_act_maintenance"
  type   = "respondwith"
  target = "\"HTTP/1.1 503 Service Unavailable\\r\\nRetry-After: 300\\r\\nContent-Length: 0\\r\\n\\r\\n\""
}

resource "citrixadc_responderpolicy" "maintenance" {
  name   = "rs_pol_maint1"
  rule   = "$v_maintenance.EQ(1)"
  action = citrixadc_responderaction.maintenance.name

  depends_on = [citrixadc_nsvariable.maintenance]
}

resource "citrixadc_csvserver_responderpolicy_binding" "maintenance" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_responderpolicy.maintenance.name
  priority   = 30
  bindpoint  = "REQUEST"
}

# --- Compression Policies ---

resource "citrixadc_cmppolicy" "text" {
  name      = "cmp_pol_text"
  rule      = "HTTP.RES.HEADER(\"Content-Type\").CONTAINS(\"text/\")"
  resaction = "COMPRESS"
}

resource "citrixadc_cmppolicy" "json" {
  name      = "cmp_pol_json"
  rule      = "HTTP.RES.HEADER(\"Content-Type\").CONTAINS(\"application/json\")"
  resaction = "COMPRESS"
}

resource "citrixadc_cmppolicy" "js" {
  name      = "cmp_pol_js"
  rule      = "HTTP.RES.HEADER(\"Content-Type\").CONTAINS(\"application/javascript\")"
  resaction = "COMPRESS"
}

resource "citrixadc_cmppolicy" "xml" {
  name      = "cmp_pol_xml"
  rule      = "HTTP.RES.HEADER(\"Content-Type\").CONTAINS(\"application/xml\")"
  resaction = "COMPRESS"
}

resource "citrixadc_cmppolicy" "svg" {
  name      = "cmp_pol_svg"
  rule      = "HTTP.RES.HEADER(\"Content-Type\").CONTAINS(\"image/svg+xml\")"
  resaction = "COMPRESS"
}

resource "citrixadc_csvserver_cmppolicy_binding" "text" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cmppolicy.text.name
  priority   = 100
  bindpoint  = "RESPONSE"
}

resource "citrixadc_csvserver_cmppolicy_binding" "json" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cmppolicy.json.name
  priority   = 110
  bindpoint  = "RESPONSE"
}

resource "citrixadc_csvserver_cmppolicy_binding" "js" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cmppolicy.js.name
  priority   = 120
  bindpoint  = "RESPONSE"
}

resource "citrixadc_csvserver_cmppolicy_binding" "xml" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cmppolicy.xml.name
  priority   = 130
  bindpoint  = "RESPONSE"
}

resource "citrixadc_csvserver_cmppolicy_binding" "svg" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cmppolicy.svg.name
  priority   = 140
  bindpoint  = "RESPONSE"
}

# --- Audit Logging ---

resource "citrixadc_auditmessageaction" "request" {
  name              = "audit_act_request"
  loglevel          = "INFORMATIONAL"
  stringbuilderexpr = "\"REQ: \" + CLIENT.IP.SRC + \" \" + HTTP.REQ.METHOD + \" \" + HTTP.REQ.HOSTNAME + HTTP.REQ.URL"
}

resource "citrixadc_auditmessageaction" "response" {
  name              = "audit_act_response"
  loglevel          = "INFORMATIONAL"
  stringbuilderexpr = "\"RES: \" + CLIENT.IP.SRC + \" \" + HTTP.RES.STATUS"
}

resource "citrixadc_rewriteaction" "log_req" {
  name              = "rw_act_log_req"
  type              = "noop"
  target            = "\"\""
  stringbuilderexpr = "\"\""
}

resource "citrixadc_rewritepolicy" "log_req" {
  name      = "rw_pol_log_req"
  rule      = "HTTP.REQ.IS_VALID"
  action    = citrixadc_rewriteaction.log_req.name
  logaction = citrixadc_auditmessageaction.request.name
}

resource "citrixadc_rewriteaction" "log_res" {
  name              = "rw_act_log_res"
  type              = "noop"
  target            = "\"\""
  stringbuilderexpr = "\"\""
}

resource "citrixadc_rewritepolicy" "log_res" {
  name      = "rw_pol_log_res"
  rule      = "HTTP.RES.IS_VALID"
  action    = citrixadc_rewriteaction.log_res.name
  logaction = citrixadc_auditmessageaction.response.name
}

resource "citrixadc_csvserver_rewritepolicy_binding" "log_req" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.log_req.name
  priority   = 900
  bindpoint  = "REQUEST"
}

resource "citrixadc_csvserver_rewritepolicy_binding" "log_res" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_rewritepolicy.log_res.name
  priority   = 900
  bindpoint  = "RESPONSE"
}

# --- AppExpert Objects ---

resource "citrixadc_policystringmap" "url_routes" {
  name = "sm_url_routes"
}

resource "citrixadc_policystringmap_pattern_binding" "route_api" {
  name = citrixadc_policystringmap.url_routes.name
  key  = "/api"
  value = "lb_vsrv_api"
}

resource "citrixadc_policystringmap_pattern_binding" "route_app" {
  name = citrixadc_policystringmap.url_routes.name
  key  = "/app"
  value = "lb_vsrv_web"
}

resource "citrixadc_policystringmap_pattern_binding" "route_health" {
  name = citrixadc_policystringmap.url_routes.name
  key  = "/health"
  value = "lb_vsrv_web"
}

resource "citrixadc_policypatset" "allowed_origins" {
  name = "ps_allowed_origins"
}

resource "citrixadc_policypatset_pattern_binding" "origin_app" {
  name   = citrixadc_policypatset.allowed_origins.name
  string = "https://app.lab.local"
}

resource "citrixadc_policypatset_pattern_binding" "origin_api" {
  name   = citrixadc_policypatset.allowed_origins.name
  string = "https://api.lab.local"
}

resource "citrixadc_policypatset_pattern_binding" "origin_lab" {
  name   = citrixadc_policypatset.allowed_origins.name
  string = "https://lab.local"
}

# --- Save Config ---

resource "citrixadc_nsconfig_save" "traffic" {
  all       = true
  timestamp = timestamp()

  depends_on = [
    citrixadc_csvserver.https,
    citrixadc_csvserver.http,
    citrixadc_csvserver_rewritepolicy_binding.log_req,
    citrixadc_csvserver_rewritepolicy_binding.log_res,
    citrixadc_csvserver_cmppolicy_binding.svg,
    citrixadc_policystringmap_pattern_binding.route_health,
    citrixadc_policypatset_pattern_binding.origin_lab,
  ]
}
