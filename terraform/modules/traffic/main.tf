# =============================================================================
# Traffic Management Module
# Maps: apply-traffic-management.sh (steps 1-14)
# =============================================================================

# --- Step 1: SNIP ---

resource "citrixadc_nsip" "snip" {
  ipaddress  = var.snip
  netmask    = "255.255.255.0"
  type       = "SNIP"
  mgmtaccess = "ENABLED"
}

# --- Step 3: Custom Profiles ---

resource "citrixadc_nstcpprofile" "web" {
  name               = "tcp_prof_web"
  ws                 = "ENABLED"
  wsval              = 8
  sack               = "ENABLED"
  nagle              = "DISABLED"
  maxburst           = 10
  initialcwnd        = 16
  oooqsize           = 300
  minrto             = 400
  flavor             = "CUBIC"
  rstwindowattenuate = "ENABLED"
  spoofsyndrop       = "ENABLED"
  ecn                = "ENABLED"
  timestamp          = "ENABLED"
  dsack              = "ENABLED"
  frto               = "ENABLED"
  ka                 = "ENABLED"
  kaprobeinterval    = 30
  kaconnidletime     = 300
  kamaxprobes        = 5
}

resource "citrixadc_nshttpprofile" "web" {
  name                         = "http_prof_web"
  dropinvalreqs                = "ENABLED"
  markhttp09inval              = "ENABLED"
  markconnreqinval             = "ENABLED"
  marktracereqinval            = "ENABLED"
  markrfc7230noncompliantinval = "ENABLED"
  conmultiplex                 = "ENABLED"
  maxreusepool                 = 0
  dropextradata                = "ENABLED"
  websocket                    = "ENABLED"
  http2                        = "ENABLED"
  http2maxconcurrentstreams    = 128
  http2maxheaderlistsize       = 32768
}

# --- Step 4: Server Objects ---

resource "citrixadc_server" "host01" {
  name      = "srv_host01"
  ipaddress = "10.0.1.1"
  comment   = "KVM host"
}

resource "citrixadc_server" "opnsense" {
  name      = "srv_opnsense"
  ipaddress = "10.0.1.2"
  comment   = "OPNsense firewall"
}

# --- Step 5: Health Monitors ---

resource "citrixadc_lbmonitor" "http_200" {
  monitorname = "mon_http_200"
  type        = "HTTP"
  respcode    = ["200"]
  httprequest = "HEAD /"
  lrtm        = "ENABLED"
  interval    = 10
  resptimeout = 5
  downtime    = 15
  retries     = 3
}

resource "citrixadc_lbmonitor" "tcp_quick" {
  monitorname = "mon_tcp_quick"
  type        = "TCP"
  interval    = 5
  resptimeout = 3
  downtime    = 10
  retries     = 3
}

resource "citrixadc_lbmonitor" "https_200" {
  monitorname = "mon_https_200"
  type        = "HTTP-ECV"
  send        = "HEAD / HTTP/1.1\r\nHost: health.lab.local\r\nConnection: close\r\n\r\n"
  recv        = "200 OK"
  secure      = "YES"
  interval    = 10
  resptimeout = 5
  downtime    = 15
}

# --- Step 6: Service Groups ---

resource "citrixadc_servicegroup" "web_http" {
  servicegroupname = "sg_web_http"
  servicetype      = "HTTP"
  usip             = "NO"
  cka              = "YES"
  tcpb             = "YES"
  cmp              = "YES"
  tcpprofilename   = citrixadc_nstcpprofile.web.name
  httpprofilename  = citrixadc_nshttpprofile.web.name
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "web_http_host01" {
  servicegroupname = citrixadc_servicegroup.web_http.servicegroupname
  servername       = citrixadc_server.host01.name
  port             = 80
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "web_http_opnsense" {
  servicegroupname = citrixadc_servicegroup.web_http.servicegroupname
  servername       = citrixadc_server.opnsense.name
  port             = 80
}

resource "citrixadc_servicegroup_lbmonitor_binding" "web_http_mon" {
  servicegroupname = citrixadc_servicegroup.web_http.servicegroupname
  monitorname     = citrixadc_lbmonitor.http_200.monitorname
}

resource "citrixadc_servicegroup" "web_https" {
  servicegroupname = "sg_web_https"
  servicetype      = "SSL"
  usip             = "NO"
  cka              = "YES"
  tcpb             = "YES"
  tcpprofilename   = citrixadc_nstcpprofile.web.name
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "web_https_host01" {
  servicegroupname = citrixadc_servicegroup.web_https.servicegroupname
  servername       = citrixadc_server.host01.name
  port             = 443
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "web_https_opnsense" {
  servicegroupname = citrixadc_servicegroup.web_https.servicegroupname
  servername       = citrixadc_server.opnsense.name
  port             = 443
}

resource "citrixadc_servicegroup_lbmonitor_binding" "web_https_mon" {
  servicegroupname = citrixadc_servicegroup.web_https.servicegroupname
  monitorname     = citrixadc_lbmonitor.https_200.monitorname
}

resource "citrixadc_servicegroup" "tcp_generic" {
  servicegroupname = "sg_tcp_generic"
  servicetype      = "TCP"
  usip             = "NO"
  cka              = "YES"
  tcpb             = "YES"
  tcpprofilename   = citrixadc_nstcpprofile.web.name
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "tcp_host01" {
  servicegroupname = citrixadc_servicegroup.tcp_generic.servicegroupname
  servername       = citrixadc_server.host01.name
  port             = 8080
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "tcp_opnsense" {
  servicegroupname = citrixadc_servicegroup.tcp_generic.servicegroupname
  servername       = citrixadc_server.opnsense.name
  port             = 8080
}

resource "citrixadc_servicegroup_lbmonitor_binding" "tcp_mon" {
  servicegroupname = citrixadc_servicegroup.tcp_generic.servicegroupname
  monitorname     = citrixadc_lbmonitor.tcp_quick.monitorname
}

resource "citrixadc_servicegroup" "dns" {
  servicegroupname = "sg_dns"
  servicetype      = "DNS"
  usip             = "NO"
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "dns_host01" {
  servicegroupname = citrixadc_servicegroup.dns.servicegroupname
  servername       = citrixadc_server.host01.name
  port             = 53
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "dns_opnsense" {
  servicegroupname = citrixadc_servicegroup.dns.servicegroupname
  servername       = citrixadc_server.opnsense.name
  port             = 53
}

resource "citrixadc_servicegroup_lbmonitor_binding" "dns_mon" {
  servicegroupname = citrixadc_servicegroup.dns.servicegroupname
  monitorname     = "dns"
}

# --- Step 7: LB VServers ---

resource "citrixadc_lbvserver" "web" {
  name            = "lb_vsrv_web"
  servicetype     = "HTTP"
  lbmethod        = "ROUNDROBIN"
  persistencetype = "COOKIEINSERT"
  cookiename      = "NSLB"
  tcpprofilename  = citrixadc_nstcpprofile.web.name
  httpprofilename = citrixadc_nshttpprofile.web.name
}

resource "citrixadc_lbvserver_servicegroup_binding" "web" {
  name             = citrixadc_lbvserver.web.name
  servicegroupname = citrixadc_servicegroup.web_http.servicegroupname
}

resource "citrixadc_lbvserver" "web_ssl" {
  name            = "lb_vsrv_web_ssl"
  servicetype     = "SSL"
  lbmethod        = "ROUNDROBIN"
  persistencetype = "SOURCEIP"
  tcpprofilename  = citrixadc_nstcpprofile.web.name
}

resource "citrixadc_lbvserver_servicegroup_binding" "web_ssl" {
  name             = citrixadc_lbvserver.web_ssl.name
  servicegroupname = citrixadc_servicegroup.web_https.servicegroupname
}

resource "citrixadc_lbvserver" "api" {
  name            = "lb_vsrv_api"
  servicetype     = "HTTP"
  lbmethod        = "LEASTCONNECTION"
  persistencetype = "SOURCEIP"
  tcpprofilename  = citrixadc_nstcpprofile.web.name
  httpprofilename = citrixadc_nshttpprofile.web.name
}

resource "citrixadc_lbvserver_servicegroup_binding" "api" {
  name             = citrixadc_lbvserver.api.name
  servicegroupname = citrixadc_servicegroup.web_http.servicegroupname
}

resource "citrixadc_lbvserver" "tcp" {
  name            = "lb_vsrv_tcp"
  servicetype     = "TCP"
  ipv46           = var.vip_tcp
  port            = 8080
  lbmethod        = "LEASTCONNECTION"
  persistencetype = "SOURCEIP"
  tcpprofilename  = citrixadc_nstcpprofile.web.name
}

resource "citrixadc_lbvserver_servicegroup_binding" "tcp" {
  name             = citrixadc_lbvserver.tcp.name
  servicegroupname = citrixadc_servicegroup.tcp_generic.servicegroupname
}

resource "citrixadc_lbvserver" "dns" {
  name        = "lb_vsrv_dns"
  servicetype = "DNS"
  ipv46       = var.vip_dns
  port        = 53
  lbmethod    = "ROUNDROBIN"
}

resource "citrixadc_lbvserver_servicegroup_binding" "dns" {
  name             = citrixadc_lbvserver.dns.name
  servicegroupname = citrixadc_servicegroup.dns.servicegroupname
}
