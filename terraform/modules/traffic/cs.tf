# =============================================================================
# Content Switching — VServers, Actions, Policies
# Maps: apply-traffic-management.sh steps 8
# =============================================================================

# --- CS VServers ---

resource "citrixadc_csvserver" "https" {
  name            = "cs_vsrv_https"
  servicetype     = "SSL"
  ipv46           = var.vip_cs
  port            = 443
  clttimeout      = 180
  httpprofilename = citrixadc_nshttpprofile.web.name
  tcpprofilename  = citrixadc_nstcpprofile.web.name
  sslprofile      = "ns_default_ssl_profile_frontend"
}

resource "citrixadc_sslvserver_sslcertkey_binding" "https" {
  vservername = citrixadc_csvserver.https.name
  certkeyname = "wildcard.lab.local"
}

resource "citrixadc_csvserver" "http" {
  name            = "cs_vsrv_http"
  servicetype     = "HTTP"
  ipv46           = var.vip_cs
  port            = 80
  clttimeout      = 60
  httpprofilename = citrixadc_nshttpprofile.web.name
  tcpprofilename  = citrixadc_nstcpprofile.web.name
}

# --- CS Actions ---

resource "citrixadc_csaction" "api" {
  name            = "cs_act_api"
  targetlbvserver = citrixadc_lbvserver.api.name
}

resource "citrixadc_csaction" "web" {
  name            = "cs_act_web"
  targetlbvserver = citrixadc_lbvserver.web.name
}

# --- CS Policies ---

resource "citrixadc_cspolicy" "api" {
  policyname = "cs_pol_api"
  rule       = "HTTP.REQ.HOSTNAME.EQ(\"api.lab.local\")"
  action     = citrixadc_csaction.api.name
}

resource "citrixadc_cspolicy" "static" {
  policyname = "cs_pol_static"
  rule       = "HTTP.REQ.HOSTNAME.EQ(\"static.lab.local\")"
  action     = citrixadc_csaction.web.name
}

resource "citrixadc_cspolicy" "app" {
  policyname = "cs_pol_app"
  rule       = "HTTP.REQ.HOSTNAME.EQ(\"app.lab.local\")"
  action     = citrixadc_csaction.web.name
}

# --- CS Policy Bindings to HTTPS vserver ---

resource "citrixadc_csvserver_cspolicy_binding" "api" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cspolicy.api.policyname
  priority   = 100
}

resource "citrixadc_csvserver_cspolicy_binding" "static" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cspolicy.static.policyname
  priority   = 110
}

resource "citrixadc_csvserver_cspolicy_binding" "app" {
  name       = citrixadc_csvserver.https.name
  policyname = citrixadc_cspolicy.app.policyname
  priority   = 120
}

# Default LB vserver is set via lbvserver attribute on the csvserver resource
