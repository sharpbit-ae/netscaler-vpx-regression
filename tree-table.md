# NetScaler VPX — Full Configuration & Test Coverage Tree

**190 Terraform resources** → **~375 NITRO API assertions per VPX** → **35 CLI diff comparisons** → **4 system log collections**

Each `check_resource` with a field produces **2 assertions** (exists + field value match).
Each `check_resource` without a field produces **1 assertion** (exists only).
Each `check_binding` produces **1–2 assertions** (found + optional field).
Each `check_feature` produces **1 assertion** (SSH output match).
Each `check_cert_expiry` produces **1 assertion** (days remaining).

---

```
VPX FIRMWARE REGRESSION PIPELINE
├── STAGE 1: SETUP
│   ├── Prerequisite Validation
│   │   ├── virsh ................................. KVM hypervisor management
│   │   ├── mkisofs ............................... ISO creation for preboot config
│   │   ├── expect ................................ SSH keyboard-interactive automation
│   │   ├── qemu-img .............................. QCOW2 disk operations
│   │   ├── terraform ............................. Infrastructure-as-code engine
│   │   └── curl .................................. NITRO API HTTP client
│   │
│   ├── Leftover VM Cleanup
│   │   ├── cleanup-vm.sh "vpx-baseline"
│   │   │   ├── virsh shutdown (graceful, 30s timeout)
│   │   │   ├── virsh destroy (force if still running)
│   │   │   ├── virsh undefine
│   │   │   └── rm vpx-baseline.qcow2, vpx-baseline-userdata.iso
│   │   └── cleanup-vm.sh "vpx-candidate"
│   │       └── (same sequence)
│   │
│   └── Certificate Decoding (from pipeline secrets)
│       ├── LAB_CA_CRT ──base64 -d──→ /tmp/vpx-pipeline-certs/lab-ca.crt
│       ├── WILDCARD_CRT ──base64 -d──→ /tmp/vpx-pipeline-certs/wildcard.lab.local.crt
│       └── WILDCARD_KEY ──base64 -d──→ /tmp/vpx-pipeline-certs/wildcard.lab.local.key
│
├── STAGE 2: DEPLOY (baseline + candidate in parallel)
│   │
│   ├── Step 1/8: Provision KVM VM (create-vpx-vm.sh)
│   │   ├── [1/6] Extract firmware tarball → find .qcow2
│   │   ├── [2/6] Copy QCOW2 → /home/vm-data/{name}.qcow2
│   │   ├── [3/6] Create preboot ISO from templates/userdata.tpl
│   │   │   └── NS-PRE-BOOT-CONFIG XML
│   │   │       ├── SKIP-DEFAULT-BOOTSTRAP = YES
│   │   │       ├── NEW-BOOTSTRAP-SEQUENCE = YES
│   │   │       ├── INTERFACE-NUM = eth0
│   │   │       ├── IP = {NSIP} (10.0.1.5 or 10.0.1.6)
│   │   │       ├── SUBNET-MASK = 255.255.255.0
│   │   │       └── default route → 10.0.1.1 (gateway)
│   │   ├── [4/6] Generate domain XML from templates/vpx-domain.tpl
│   │   │   ├── memory = 2GB
│   │   │   ├── vcpu = 2
│   │   │   ├── cpu mode = host-passthrough
│   │   │   ├── disk: vda (virtio) → {name}.qcow2
│   │   │   ├── cdrom: hdc (ide) → {name}-userdata.iso
│   │   │   └── interface: opn_wan network (virtio)
│   │   ├── [5/6] virsh define {name}.xml
│   │   └── [6/6] virsh start {name}
│   │
│   ├── Step 2/8: Wait for SSH boot (wait-for-boot.sh, 180s timeout)
│   │
│   ├── Step 3/8: Change default password (change-default-password.sh)
│   │   ├── Validate password policy (≥8 chars, upper, lower, digit, special)
│   │   ├── Wait for NITRO API with default password
│   │   ├── SSH forced-change via expect (change-password-ssh.exp)
│   │   │   ├── Handle keyboard-interactive auth
│   │   │   ├── Enter old password (nsroot)
│   │   │   ├── Enter new password (twice)
│   │   │   ├── Disable ForcePasswordChange from CLI
│   │   │   └── Save config
│   │   ├── Verify NITRO accepts new password (retry 6x, 5s intervals)
│   │   └── Fallback: NITRO API PUT /systemuser (if SSH method fails)
│   │
│   ├── Step 4/8: terraform init
│   │
│   ├── Step 5/8: Terraform Phase A — module.system only (-target)
│   │   └── (see TERRAFORM RESOURCES: module.system below)
│   │
│   ├── Step 6/8: Warm reboot (reboot-vpx.sh)
│   │   └── Required because sslparameter.defaultprofile = ENABLED
│   │
│   ├── Step 7/8: Wait for NITRO API post-reboot (wait-for-nitro.sh)
│   │
│   └── Step 8/8: Terraform Phase B — all modules (full apply)
│       └── (see TERRAFORM RESOURCES: module.ssl, certificates, traffic below)
│
├── STAGE 3: REGRESSION TESTING
│   │
│   ├── Background Metrics (collect-metrics.sh, 10s interval)
│   │   ├── timestamp (UTC ISO 8601)
│   │   ├── cpu_pct (from /proc/stat delta)
│   │   ├── mem_used_mb, mem_total_mb, mem_pct (from /proc/meminfo)
│   │   ├── disk_used_gb, disk_total_gb, disk_pct (df -BG /)
│   │   └── net_rx_mbps, net_tx_mbps (from /proc/net/dev delta)
│   │
│   ├── PHASE 1: Comprehensive NITRO API Tests (×2 VPXs)
│   │   └── (see NITRO TEST TREE below — 375+ assertions per VPX)
│   │
│   ├── PHASE 2: CLI Output Comparison
│   │   └── (see CLI DIFF TREE below — 35 commands)
│   │
│   ├── PHASE 2.5: System Log Collection
│   │   ├── "shell tail -200 /var/log/messages" .... system messages
│   │   ├── "shell tail -200 /var/nslog/ns.log" .... NetScaler log
│   │   ├── "show ns events" ....................... event history
│   │   └── "show running config" .................. full running config
│   │
│   └── PHASE 3: HTML Report Generation (generate-html-report.py)
│       ├── Executive summary (SVG donut charts per VPX)
│       ├── Category breakdown (SVG bar charts)
│       ├── Failures & warnings (prominent, tabbed)
│       ├── CLI differences (color-coded diffs)
│       ├── Resource usage (SVG line charts: CPU, memory, network, disk)
│       ├── Passed tests (collapsible by category, searchable)
│       ├── System logs (tabbed baseline/candidate)
│       └── CSV export (all assertions as downloadable CSV)
│
└── STAGE 4: CLEANUP (condition: always)
    ├── cleanup-vm.sh "vpx-baseline"
    ├── cleanup-vm.sh "vpx-candidate"
    ├── rm -rf /tmp/vpx-pipeline-certs
    └── Verify: virsh list --all, ls /home/vm-data/


================================================================================
 TERRAFORM RESOURCES (190 total)
================================================================================

module.system (17 resources) ─── Phase A, pre-reboot
│
├── citrixadc_nshostname.this
│   └── hostname = var.hostname
│
├── citrixadc_dnsnameserver.cloudflare
│   └── ip = "1.1.1.1"
│
├── citrixadc_dnsnameserver.google
│   └── ip = "8.8.8.8"
│
├── citrixadc_ntpserver.pool
│   └── servername = "pool.ntp.org"
│
├── citrixadc_systemparameter.this
│   ├── strongpassword = "enableall"
│   ├── minpasswordlen = 8
│   ├── maxclient = 10
│   ├── timeout = 600
│   ├── restrictedtimeout = "ENABLED"
│   └── forcepasswordchange = "DISABLED"
│
├── citrixadc_nsrpcnode.this
│   ├── ipaddress = var.nsip
│   ├── password = var.rpc_password
│   └── secure = "ON"
│
├── citrixadc_nsparam.this
│   └── cookieversion = 1
│
├── citrixadc_nsfeature.this
│   ├── lb = true
│   ├── cs = true
│   ├── ssl = true
│   ├── rewrite = true
│   ├── responder = true
│   ├── aaa = true
│   ├── appflow = true
│   ├── cmp = true
│   ├── sslvpn = true
│   └── ch = false
│
├── citrixadc_nsmode.this
│   ├── fr = true
│   ├── tcpb = true
│   ├── edge = true
│   ├── l3 = true
│   └── ulfd = true
│
├── citrixadc_nshttpprofile.default
│   │   name = "nshttp_default_profile"
│   ├── dropinvalreqs = "ENABLED"
│   ├── markhttp09inval = "ENABLED"
│   ├── markconnreqinval = "ENABLED"
│   ├── marktracereqinval = "ENABLED"
│   └── markrfc7230noncompliantinval = "ENABLED"
│
├── citrixadc_nstcpprofile.default
│   │   name = "nstcp_default_profile"
│   ├── rstwindowattenuate = "ENABLED"
│   ├── spoofsyndrop = "ENABLED"
│   ├── ecn = "ENABLED"
│   ├── timestamp = "ENABLED"
│   ├── dsack = "ENABLED"
│   └── frto = "ENABLED"
│
├── citrixadc_nsip.mgmt
│   ├── ipaddress = var.nsip
│   ├── netmask = "255.255.255.0"
│   ├── type = "NSIP"
│   ├── restrictaccess = "ENABLED"
│   └── gui = "SECUREONLY"
│
├── citrixadc_auditnslogparams.this
│   └── loglevel = ["ALL"]
│
├── citrixadc_auditmessageaction.enterprise_log
│   ├── loglevel = "INFORMATIONAL"
│   └── stringbuilderexpr = "Enterprise audit: " + CLIENT.IP.SRC + " " + HTTP.REQ.URL
│
├── citrixadc_nstimeout.this
│   ├── zombie = 600
│   ├── halfclose = 300
│   └── nontcpzombie = 300
│
├── citrixadc_sslparameter.this
│   └── defaultprofile = "ENABLED"  ◄── TRIGGERS WARM REBOOT REQUIREMENT
│
└── citrixadc_nsconfig_save.this


module.ssl (7 resources) ─── Phase B, post-reboot
│
├── citrixadc_sslprofile.frontend
│   │   name = "ns_default_ssl_profile_frontend"
│   ├── ssl3 = "DISABLED"
│   ├── tls1 = "DISABLED"
│   ├── tls11 = "DISABLED"
│   ├── tls12 = "ENABLED"
│   ├── tls13 = "ENABLED"
│   ├── denysslreneg = "NONSECURE"
│   ├── hsts = "ENABLED"
│   └── maxage = 31536000 (1 year)
│
├── citrixadc_sslprofile.backend
│   │   name = "ns_default_ssl_profile_backend"
│   ├── ssl3 = "DISABLED"
│   ├── tls1 = "DISABLED"
│   ├── tls11 = "DISABLED"
│   ├── tls12 = "ENABLED"
│   └── tls13 = "ENABLED"
│
├── citrixadc_sslprofile_sslcipher_binding.frontend_aes256_gcm
│   ├── ciphername = "TLS1.2-AES256-GCM-SHA384"
│   └── cipherpriority = 1
│
├── citrixadc_sslprofile_sslcipher_binding.frontend_aes128_gcm
│   ├── ciphername = "TLS1.2-AES128-GCM-SHA256"
│   └── cipherpriority = 2
│
├── citrixadc_sslprofile_sslcipher_binding.frontend_tls13_aes256
│   ├── ciphername = "TLS1.3-AES256-GCM-SHA384"
│   └── cipherpriority = 3
│
├── citrixadc_sslprofile_sslcipher_binding.frontend_tls13_chacha
│   ├── ciphername = "TLS1.3-CHACHA20-POLY1305-SHA256"
│   └── cipherpriority = 4
│
└── citrixadc_nsconfig_save.ssl


module.certificates (5 resources) ─── Phase B
│
├── citrixadc_systemfile.lab_ca_crt
│   ├── filename = "lab-ca.crt"
│   └── filelocation = "/nsconfig/ssl/"
│
├── citrixadc_systemfile.wildcard_crt
│   ├── filename = "wildcard.lab.local.crt"
│   └── filelocation = "/nsconfig/ssl/"
│
├── citrixadc_systemfile.wildcard_key
│   ├── filename = "wildcard.lab.local.key"
│   └── filelocation = "/nsconfig/ssl/"
│
├── citrixadc_sslcertkey.lab_ca
│   ├── certkey = "lab-ca"
│   └── cert = "/nsconfig/ssl/lab-ca.crt"
│
└── citrixadc_sslcertkey.wildcard
    ├── certkey = "wildcard.lab.local"
    ├── cert = "/nsconfig/ssl/wildcard.lab.local.crt"
    ├── key = "/nsconfig/ssl/wildcard.lab.local.key"
    └── linkcertkeyname = "lab-ca"  (certificate chain)


module.traffic — main.tf (34 resources) ─── Phase B
│
├── citrixadc_nsip.snip
│   ├── ipaddress = var.snip (10.0.1.254 / 10.0.1.253)
│   ├── netmask = "255.255.255.0"
│   ├── type = "SNIP"
│   └── mgmtaccess = "ENABLED"
│
├── citrixadc_nstcpprofile.web
│   │   name = "tcp_prof_web"
│   ├── ws = "ENABLED"
│   ├── wsval = 8
│   ├── sack = "ENABLED"
│   ├── nagle = "DISABLED"
│   ├── maxburst = 10
│   ├── initialcwnd = 16
│   ├── oooqsize = 300
│   ├── minrto = 400
│   ├── flavor = "CUBIC"
│   ├── rstwindowattenuate = "ENABLED"
│   ├── spoofsyndrop = "ENABLED"
│   ├── ecn = "ENABLED"
│   ├── timestamp = "ENABLED"
│   ├── dsack = "ENABLED"
│   ├── frto = "ENABLED"
│   ├── ka = "ENABLED"
│   ├── kaprobeinterval = 30
│   ├── kaconnidletime = 300
│   └── kamaxprobes = 5
│
├── citrixadc_nshttpprofile.web
│   │   name = "http_prof_web"
│   ├── dropinvalreqs = "ENABLED"
│   ├── markhttp09inval = "ENABLED"
│   ├── markconnreqinval = "ENABLED"
│   ├── marktracereqinval = "ENABLED"
│   ├── markrfc7230noncompliantinval = "ENABLED"
│   ├── conmultiplex = "ENABLED"
│   ├── maxreusepool = 0
│   ├── dropextradata = "ENABLED"
│   ├── websocket = "ENABLED"
│   ├── http2 = "ENABLED"
│   ├── http2maxconcurrentstreams = 128
│   └── http2maxheaderlistsize = 32768
│
├── citrixadc_server.host01
│   ├── name = "srv_host01"
│   ├── ipaddress = "10.0.1.1"
│   └── comment = "KVM host"
│
├── citrixadc_server.opnsense
│   ├── name = "srv_opnsense"
│   ├── ipaddress = "10.0.1.2"
│   └── comment = "OPNsense firewall"
│
├── citrixadc_lbmonitor.http_200
│   ├── monitorname = "mon_http_200"
│   ├── type = "HTTP"
│   ├── respcode = ["200"]
│   ├── httprequest = "HEAD /"
│   ├── lrtm = "ENABLED"
│   ├── interval = 10
│   ├── resptimeout = 5
│   ├── downtime = 15
│   └── retries = 3
│
├── citrixadc_lbmonitor.tcp_quick
│   ├── monitorname = "mon_tcp_quick"
│   ├── type = "TCP"
│   ├── interval = 5
│   ├── resptimeout = 3
│   ├── downtime = 10
│   └── retries = 3
│
├── citrixadc_lbmonitor.https_200
│   ├── monitorname = "mon_https_200"
│   ├── type = "HTTP-ECV"
│   ├── send = "HEAD / HTTP/1.1\r\nHost: health.lab.local\r\n..."
│   ├── recv = "200 OK"
│   ├── secure = "YES"
│   ├── interval = 10
│   ├── resptimeout = 5
│   └── downtime = 15
│
├── citrixadc_servicegroup.web_http ─── sg_web_http (HTTP)
│   ├── servicetype = "HTTP"
│   ├── usip = "NO"
│   ├── cka = "YES"
│   ├── tcpb = "YES"
│   ├── cmp = "YES"
│   ├── tcpprofilename = "tcp_prof_web"
│   └── httpprofilename = "http_prof_web"
├── citrixadc_servicegroup_servicegroupmember_binding.web_http_host01
│   └── srv_host01:80
├── citrixadc_servicegroup_servicegroupmember_binding.web_http_opnsense
│   └── srv_opnsense:80
├── citrixadc_servicegroup_lbmonitor_binding.web_http_mon
│   └── monitorname = "mon_http_200"
│
├── citrixadc_servicegroup.web_https ─── sg_web_https (SSL)
│   ├── servicetype = "SSL"
│   ├── usip = "NO"
│   ├── cka = "YES"
│   ├── tcpb = "YES"
│   └── tcpprofilename = "tcp_prof_web"
├── citrixadc_servicegroup_servicegroupmember_binding.web_https_host01
│   └── srv_host01:443
├── citrixadc_servicegroup_servicegroupmember_binding.web_https_opnsense
│   └── srv_opnsense:443
├── citrixadc_servicegroup_lbmonitor_binding.web_https_mon
│   └── monitorname = "mon_https_200"
│
├── citrixadc_servicegroup.tcp_generic ─── sg_tcp_generic (TCP)
│   ├── servicetype = "TCP"
│   ├── usip = "NO"
│   ├── cka = "YES"
│   ├── tcpb = "YES"
│   └── tcpprofilename = "tcp_prof_web"
├── citrixadc_servicegroup_servicegroupmember_binding.tcp_host01
│   └── srv_host01:8080
├── citrixadc_servicegroup_servicegroupmember_binding.tcp_opnsense
│   └── srv_opnsense:8080
├── citrixadc_servicegroup_lbmonitor_binding.tcp_mon
│   └── monitorname = "mon_tcp_quick"
│
├── citrixadc_servicegroup.dns ─── sg_dns (DNS)
│   ├── servicetype = "DNS"
│   └── usip = "NO"
├── citrixadc_servicegroup_servicegroupmember_binding.dns_host01
│   └── srv_host01:53
├── citrixadc_servicegroup_servicegroupmember_binding.dns_opnsense
│   └── srv_opnsense:53
├── citrixadc_servicegroup_lbmonitor_binding.dns_mon
│   └── monitorname = "dns" (built-in)
│
├── citrixadc_lbvserver.web ─── lb_vsrv_web
│   ├── servicetype = "HTTP"
│   ├── lbmethod = "ROUNDROBIN"
│   ├── persistencetype = "COOKIEINSERT"
│   ├── cookiename = "NSLB"
│   ├── tcpprofilename = "tcp_prof_web"
│   └── httpprofilename = "http_prof_web"
├── citrixadc_lbvserver_servicegroup_binding.web
│   └── servicegroupname = "sg_web_http"
│
├── citrixadc_lbvserver.web_ssl ─── lb_vsrv_web_ssl
│   ├── servicetype = "SSL"
│   ├── lbmethod = "ROUNDROBIN"
│   ├── persistencetype = "SOURCEIP"
│   └── tcpprofilename = "tcp_prof_web"
├── citrixadc_lbvserver_servicegroup_binding.web_ssl
│   └── servicegroupname = "sg_web_https"
│
├── citrixadc_lbvserver.api ─── lb_vsrv_api
│   ├── servicetype = "HTTP"
│   ├── lbmethod = "LEASTCONNECTION"
│   ├── persistencetype = "SOURCEIP"
│   ├── tcpprofilename = "tcp_prof_web"
│   └── httpprofilename = "http_prof_web"
├── citrixadc_lbvserver_servicegroup_binding.api
│   └── servicegroupname = "sg_web_http"
│
├── citrixadc_lbvserver.tcp ─── lb_vsrv_tcp
│   ├── servicetype = "TCP"
│   ├── ipv46 = var.vip_tcp (10.0.1.115 / 10.0.1.116)
│   ├── port = 8080
│   ├── lbmethod = "LEASTCONNECTION"
│   ├── persistencetype = "SOURCEIP"
│   └── tcpprofilename = "tcp_prof_web"
├── citrixadc_lbvserver_servicegroup_binding.tcp
│   └── servicegroupname = "sg_tcp_generic"
│
├── citrixadc_lbvserver.dns ─── lb_vsrv_dns
│   ├── servicetype = "DNS"
│   ├── ipv46 = var.vip_dns (10.0.1.125 / 10.0.1.126)
│   ├── port = 53
│   └── lbmethod = "ROUNDROBIN"
└── citrixadc_lbvserver_servicegroup_binding.dns
    └── servicegroupname = "sg_dns"


module.traffic — cs.tf (11 resources) ─── Phase B
│
├── citrixadc_csvserver.https ─── cs_vsrv_https
│   ├── servicetype = "SSL"
│   ├── ipv46 = var.vip_cs (10.0.1.105 / 10.0.1.106)
│   ├── port = 443
│   ├── clttimeout = 180
│   ├── httpprofilename = "http_prof_web"
│   ├── tcpprofilename = "tcp_prof_web"
│   └── sslprofile = "ns_default_ssl_profile_frontend"
│
├── citrixadc_sslvserver_sslcertkey_binding.https
│   ├── vservername = "cs_vsrv_https"
│   └── certkeyname = "wildcard.lab.local"
│
├── citrixadc_csvserver.http ─── cs_vsrv_http
│   ├── servicetype = "HTTP"
│   ├── ipv46 = var.vip_cs
│   ├── port = 80
│   ├── clttimeout = 60
│   ├── httpprofilename = "http_prof_web"
│   └── tcpprofilename = "tcp_prof_web"
│
├── citrixadc_csaction.api
│   └── targetlbvserver = "lb_vsrv_api"
│
├── citrixadc_csaction.web
│   └── targetlbvserver = "lb_vsrv_web"
│
├── citrixadc_cspolicy.api ─── cs_pol_api
│   ├── rule = HTTP.REQ.HOSTNAME.EQ("api.lab.local")
│   └── action = "cs_act_api"
│
├── citrixadc_cspolicy.static ─── cs_pol_static
│   ├── rule = HTTP.REQ.HOSTNAME.EQ("static.lab.local")
│   └── action = "cs_act_web"
│
├── citrixadc_cspolicy.app ─── cs_pol_app
│   ├── rule = HTTP.REQ.HOSTNAME.EQ("app.lab.local")
│   └── action = "cs_act_web"
│
├── citrixadc_csvserver_cspolicy_binding.api
│   ├── policyname = "cs_pol_api"
│   └── priority = 100
│
├── citrixadc_csvserver_cspolicy_binding.static
│   ├── policyname = "cs_pol_static"
│   └── priority = 110
│
└── citrixadc_csvserver_cspolicy_binding.app
    ├── policyname = "cs_pol_app"
    └── priority = 120


module.traffic — security.tf (83 resources) ─── Phase B
│
├── HTTPS Redirect (3 resources)
│   ├── citrixadc_responderaction.https_redirect ─── rs_act_https_redirect
│   │   ├── type = "redirect"
│   │   ├── target = "https://" + HTTP.REQ.HOSTNAME + HTTP.REQ.URL
│   │   └── responsestatuscode = 301
│   ├── citrixadc_responderpolicy.https_redirect ─── rs_pol_https_redirect
│   │   ├── rule = HTTP.REQ.IS_VALID
│   │   └── action = "rs_act_https_redirect"
│   └── citrixadc_csvserver_responderpolicy_binding.http_redirect
│       ├── name = "cs_vsrv_http"
│       ├── policyname = "rs_pol_https_redirect"
│       ├── priority = 100
│       └── bindpoint = "REQUEST"
│
├── Security Response Headers (27 resources: 9 actions + 9 policies + 9 bindings)
│   │
│   ├── X-Frame-Options: DENY
│   │   ├── citrixadc_rewriteaction.xframe ─── rw_act_xframe
│   │   │   └── type = insert_http_header, target = "X-Frame-Options"
│   │   ├── citrixadc_rewritepolicy.xframe ─── rw_pol_security_headers
│   │   │   └── rule = HTTP.RES.IS_VALID
│   │   └── citrixadc_csvserver_rewritepolicy_binding.xframe
│   │       └── priority = 100, bindpoint = RESPONSE
│   │
│   ├── X-Content-Type-Options: nosniff
│   │   ├── rw_act_nosniff → insert_http_header
│   │   ├── rw_pol_nosniff → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 110, RESPONSE
│   │
│   ├── X-XSS-Protection: 1; mode=block
│   │   ├── rw_act_xss → insert_http_header
│   │   ├── rw_pol_xss → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 120, RESPONSE
│   │
│   ├── Referrer-Policy: strict-origin-when-cross-origin
│   │   ├── rw_act_referrer → insert_http_header
│   │   ├── rw_pol_referrer → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 130, RESPONSE
│   │
│   ├── Permissions-Policy: geolocation=(), camera=(), microphone=()
│   │   ├── rw_act_permissions → insert_http_header
│   │   ├── rw_pol_permissions → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 140, RESPONSE
│   │
│   ├── Content-Security-Policy: default-src 'self'; script-src 'self'; ...
│   │   ├── rw_act_csp → insert_http_header
│   │   ├── rw_pol_csp → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 150, RESPONSE
│   │
│   ├── Server: (DELETE)
│   │   ├── rw_act_del_server → delete_http_header
│   │   ├── rw_pol_del_server → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 200, RESPONSE
│   │
│   ├── X-Powered-By: (DELETE)
│   │   ├── rw_act_del_powered → delete_http_header
│   │   ├── rw_pol_del_powered → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 210, RESPONSE
│   │
│   └── X-AspNet-Version: (DELETE)
│       ├── rw_act_del_aspnet → delete_http_header
│       ├── rw_pol_del_aspnet → rule = HTTP.RES.IS_VALID
│       └── binding → priority = 220, RESPONSE
│
├── Request Headers (12 resources: 4 actions + 4 policies + 4 bindings)
│   │
│   ├── X-Forwarded-For: CLIENT.IP.SRC
│   │   ├── rw_act_xff → insert_http_header
│   │   ├── rw_pol_xff → rule = HTTP.REQ.IS_VALID
│   │   └── binding → priority = 100, REQUEST
│   │
│   ├── X-Real-IP: CLIENT.IP.SRC
│   │   ├── rw_act_xrealip → insert_http_header
│   │   ├── rw_pol_xrealip → rule = HTTP.REQ.IS_VALID
│   │   └── binding → priority = 110, REQUEST
│   │
│   ├── X-Forwarded-Proto: "https"
│   │   ├── rw_act_xproto → insert_http_header
│   │   ├── rw_pol_xproto → rule = HTTP.REQ.IS_VALID
│   │   └── binding → priority = 120, REQUEST
│   │
│   └── X-Request-ID: CLIENT.TCP.SRCPORT + "-" + SYS.TIME
│       ├── rw_act_reqid → insert_http_header
│       ├── rw_pol_reqid → rule = HTTP.REQ.IS_VALID
│       └── binding → priority = 130, REQUEST
│
├── Additional Security Headers (9 resources: 3 actions + 3 policies + 3 bindings)
│   │
│   ├── X-Download-Options: noopen
│   │   ├── rw_act_download_options → insert_http_header
│   │   ├── rw_pol_download_options → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 160, RESPONSE
│   │
│   ├── X-Permitted-Cross-Domain-Policies: none
│   │   ├── rw_act_cross_domain → insert_http_header
│   │   ├── rw_pol_cross_domain → rule = HTTP.RES.IS_VALID
│   │   └── binding → priority = 170, RESPONSE
│   │
│   └── Cache-Control: no-store, no-cache, must-revalidate, private
│       ├── rw_act_cache_control → insert_http_header
│       ├── rw_pol_cache_control → rule = /api/ OR /login OR /auth
│       └── binding → priority = 180, RESPONSE
│
├── CORS Headers (15 resources: 5 actions + 5 policies + 5 bindings)
│   │   Condition: Origin header present AND Origin in ps_allowed_origins
│   │
│   ├── Access-Control-Allow-Origin: HTTP.REQ.HEADER("Origin")
│   │   ├── rw_act_cors_origin → insert_http_header
│   │   ├── rw_pol_cors_origin → Origin.CONTAINS_ANY("ps_allowed_origins")
│   │   └── binding → priority = 250, RESPONSE
│   │
│   ├── Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
│   │   ├── rw_act_cors_methods → insert_http_header
│   │   ├── rw_pol_cors_methods → Origin.CONTAINS_ANY("ps_allowed_origins")
│   │   └── binding → priority = 260, RESPONSE
│   │
│   ├── Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With
│   │   ├── rw_act_cors_headers → insert_http_header
│   │   ├── rw_pol_cors_headers → Origin.CONTAINS_ANY("ps_allowed_origins")
│   │   └── binding → priority = 270, RESPONSE
│   │
│   ├── Access-Control-Allow-Credentials: true
│   │   ├── rw_act_cors_credentials → insert_http_header
│   │   ├── rw_pol_cors_credentials → Origin.CONTAINS_ANY("ps_allowed_origins")
│   │   └── binding → priority = 280, RESPONSE
│   │
│   └── Access-Control-Max-Age: 86400
│       ├── rw_act_cors_maxage → insert_http_header
│       ├── rw_pol_cors_maxage → Origin.CONTAINS_ANY("ps_allowed_origins")
│       └── binding → priority = 290, RESPONSE
│
├── CORS Preflight Fast Path (3 resources)
│   ├── citrixadc_responderaction.cors_preflight ─── rs_act_cors_preflight
│   │   ├── type = "respondwith"
│   │   └── target = HTTP/1.1 204 No Content + CORS headers
│   ├── citrixadc_responderpolicy.cors_preflight ─── rs_pol_cors_preflight
│   │   └── rule = METHOD.EQ(OPTIONS) AND Origin.LENGTH.GT(0)
│   └── citrixadc_csvserver_responderpolicy_binding.cors_preflight
│       ├── name = "cs_vsrv_https"
│       ├── priority = 25
│       └── bindpoint = "REQUEST"
│
└── Bot Blocking (14 resources: 1 patset + 10 patterns + 1 action + 1 policy + 1 binding)
    ├── citrixadc_policypatset.bad_useragents ─── ps_bad_useragents
    ├── citrixadc_policypatset_pattern_binding.ua_sqlmap ─── "sqlmap" (index 1)
    ├── citrixadc_policypatset_pattern_binding.ua_nikto ─── "nikto" (index 2)
    ├── citrixadc_policypatset_pattern_binding.ua_masscan ─── "masscan" (index 3)
    ├── citrixadc_policypatset_pattern_binding.ua_nmap ─── "nmap" (index 4)
    ├── citrixadc_policypatset_pattern_binding.ua_dirbuster ─── "dirbuster" (index 5)
    ├── citrixadc_policypatset_pattern_binding.ua_gobuster ─── "gobuster" (index 6)
    ├── citrixadc_policypatset_pattern_binding.ua_wpscan ─── "wpscan" (index 7)
    ├── citrixadc_policypatset_pattern_binding.ua_nuclei ─── "nuclei" (index 8)
    ├── citrixadc_policypatset_pattern_binding.ua_zmeu ─── "ZmEu" (index 9)
    ├── citrixadc_policypatset_pattern_binding.ua_python ─── "python-requests" (index 10)
    ├── citrixadc_responderaction.block_bot ─── rs_act_block_bot
    │   ├── type = "respondwith"
    │   └── target = HTTP/1.1 403 Forbidden
    ├── citrixadc_responderpolicy.block_bot ─── rs_pol_block_bot
    │   └── rule = User-Agent.CONTAINS_ANY("ps_bad_useragents")
    └── citrixadc_csvserver_responderpolicy_binding.block_bot
        ├── name = "cs_vsrv_https"
        ├── priority = 40
        └── bindpoint = "REQUEST"


module.traffic — extras.tf (33 resources) ─── Phase B
│
├── Maintenance Mode (5 resources)
│   ├── citrixadc_nsvariable.maintenance ─── v_maintenance
│   │   ├── type = "ulong"
│   │   └── scope = "global"
│   ├── citrixadc_nsassignment.maintenance_off ─── a_maintenance_off
│   │   └── variable = "$v_maintenance", set = "0"
│   ├── citrixadc_nsassignment.maintenance_on ─── a_maintenance_on
│   │   └── variable = "$v_maintenance", set = "1"
│   ├── citrixadc_responderaction.maintenance ─── rs_act_maintenance
│   │   ├── type = "respondwith"
│   │   └── target = HTTP/1.1 503 Service Unavailable, Retry-After: 300
│   └── citrixadc_responderpolicy.maintenance ─── rs_pol_maint1
│       ├── rule = $v_maintenance.EQ(1)
│       └── bound to cs_vsrv_https, priority 30, REQUEST
│
├── Compression Policies (10 resources: 5 policies + 5 bindings)
│   ├── citrixadc_cmppolicy.text ─── cmp_pol_text
│   │   └── rule = Content-Type.CONTAINS("text/"), resaction = COMPRESS
│   ├── citrixadc_csvserver_cmppolicy_binding.text
│   │   └── priority = 100, RESPONSE
│   │
│   ├── citrixadc_cmppolicy.json ─── cmp_pol_json
│   │   └── rule = Content-Type.CONTAINS("application/json")
│   ├── citrixadc_csvserver_cmppolicy_binding.json
│   │   └── priority = 110, RESPONSE
│   │
│   ├── citrixadc_cmppolicy.js ─── cmp_pol_js
│   │   └── rule = Content-Type.CONTAINS("application/javascript")
│   ├── citrixadc_csvserver_cmppolicy_binding.js
│   │   └── priority = 120, RESPONSE
│   │
│   ├── citrixadc_cmppolicy.xml ─── cmp_pol_xml
│   │   └── rule = Content-Type.CONTAINS("application/xml")
│   ├── citrixadc_csvserver_cmppolicy_binding.xml
│   │   └── priority = 130, RESPONSE
│   │
│   ├── citrixadc_cmppolicy.svg ─── cmp_pol_svg
│   │   └── rule = Content-Type.CONTAINS("image/svg+xml")
│   └── citrixadc_csvserver_cmppolicy_binding.svg
│       └── priority = 140, RESPONSE
│
├── Audit Logging (6 resources)
│   ├── citrixadc_auditmessageaction.request ─── audit_act_request
│   │   ├── loglevel = "INFORMATIONAL"
│   │   └── "REQ: " + CLIENT.IP.SRC + " " + METHOD + " " + HOSTNAME + URL
│   ├── citrixadc_auditmessageaction.response ─── audit_act_response
│   │   ├── loglevel = "INFORMATIONAL"
│   │   └── "RES: " + CLIENT.IP.SRC + " " + HTTP.RES.STATUS
│   ├── citrixadc_rewriteaction.log_req ─── rw_act_log_req
│   │   └── type = "noop" (triggers logaction only)
│   ├── citrixadc_rewritepolicy.log_req ─── rw_pol_log_req
│   │   ├── rule = HTTP.REQ.IS_VALID
│   │   └── logaction = "audit_act_request"
│   ├── citrixadc_rewriteaction.log_res ─── rw_act_log_res
│   │   └── type = "noop"
│   ├── citrixadc_rewritepolicy.log_res ─── rw_pol_log_res
│   │   ├── rule = HTTP.RES.IS_VALID
│   │   └── logaction = "audit_act_response"
│   │
│   ├── citrixadc_csvserver_rewritepolicy_binding.log_req
│   │   └── priority = 900, REQUEST
│   └── citrixadc_csvserver_rewritepolicy_binding.log_res
│       └── priority = 900, RESPONSE
│
├── AppExpert — URL String Map (4 resources)
│   ├── citrixadc_policystringmap.url_routes ─── sm_url_routes
│   ├── citrixadc_policystringmap_pattern_binding.route_api
│   │   └── /api → lb_vsrv_api
│   ├── citrixadc_policystringmap_pattern_binding.route_app
│   │   └── /app → lb_vsrv_web
│   └── citrixadc_policystringmap_pattern_binding.route_health
│       └── /health → lb_vsrv_web
│
├── AppExpert — Allowed Origins Patset (4 resources)
│   ├── citrixadc_policypatset.allowed_origins ─── ps_allowed_origins
│   ├── citrixadc_policypatset_pattern_binding.origin_app
│   │   └── "https://app.lab.local"
│   ├── citrixadc_policypatset_pattern_binding.origin_api
│   │   └── "https://api.lab.local"
│   └── citrixadc_policypatset_pattern_binding.origin_lab
│       └── "https://lab.local"
│
└── citrixadc_nsconfig_save.traffic


================================================================================
 NITRO API TEST TREE (375+ assertions per VPX, 16 categories)
================================================================================

run-comprehensive-tests.sh
│
├── [1/16] System Identity & Network (4 assertions)
│   ├── check_resource "nshostname" ......................... exists
│   ├── check_resource "dnsnameserver/1.1.1.1" .............. exists
│   ├── check_resource "dnsnameserver/8.8.8.8" .............. exists
│   └── check_resource "ntpserver/pool.ntp.org" ............. exists
│
├── [2/16] Security Parameters (12 assertions)
│   ├── check_resource "systemparameter"
│   │   ├── exists
│   │   └── strongpassword = "enableall"
│   ├── check_resource "systemparameter"
│   │   ├── exists
│   │   └── minpasswordlen = "8"
│   ├── check_resource "systemparameter"
│   │   ├── exists
│   │   └── timeout = "600"
│   ├── check_resource "systemparameter"
│   │   ├── exists
│   │   └── maxclient = "10"
│   ├── check_resource "systemparameter"
│   │   ├── exists
│   │   └── restrictedtimeout = "ENABLED"
│   ├── check_resource "nsrpcnode/$NSIP"
│   │   ├── exists
│   │   └── secure = "ON"
│   └── check_resource "nsparam"
│       ├── exists
│       └── cookieversion = "1"
│
├── [3/16] Features & Modes (14 assertions, via SSH)
│   ├── check_feature "feature:LB" ........... ENABLED
│   ├── check_feature "feature:CS" ........... ENABLED
│   ├── check_feature "feature:SSL" .......... ENABLED
│   ├── check_feature "feature:Rewrite" ...... ENABLED
│   ├── check_feature "feature:Responder" .... ENABLED
│   ├── check_feature "feature:AppFlow" ...... ENABLED
│   ├── check_feature "feature:CMP" .......... ENABLED
│   ├── check_feature "feature:SSLVPN" ....... ENABLED
│   ├── check_feature "feature:CH" ........... DISABLED
│   ├── check_feature "mode:FR" .............. ENABLED
│   ├── check_feature "mode:TCPB" ............ ENABLED
│   ├── check_feature "mode:Edge" ............ ENABLED
│   ├── check_feature "mode:L3" .............. ENABLED
│   └── check_feature "mode:ULFD" ............ ENABLED
│
├── [4/16] HTTP & TCP Profiles (26 assertions)
│   ├── nshttp_default_profile
│   │   ├── exists + dropinvalreqs = "ENABLED"
│   │   ├── exists + markhttp09inval = "ENABLED"
│   │   ├── exists + markconnreqinval = "ENABLED"
│   │   └── exists + marktracereqinval = "ENABLED"
│   ├── nstcp_default_profile
│   │   ├── exists + rstwindowattenuate = "ENABLED"
│   │   ├── exists + spoofsyndrop = "ENABLED"
│   │   ├── exists + ecn = "ENABLED"
│   │   ├── exists + dsack = "ENABLED"
│   │   └── exists + frto = "ENABLED"
│   ├── tcp_prof_web
│   │   ├── exists + flavor = "CUBIC"
│   │   ├── exists + ka = "ENABLED"
│   │   ├── exists + ws = "ENABLED"
│   │   └── exists + sack = "ENABLED"
│   └── http_prof_web
│       ├── exists + http2 = "ENABLED"
│       ├── exists + websocket = "ENABLED"
│       ├── exists + dropinvalreqs = "ENABLED"
│       └── exists + conmultiplex = "ENABLED"
│
├── [5/16] SSL Configuration (25 assertions)
│   ├── sslparameter
│   │   ├── exists
│   │   └── defaultprofile = "ENABLED"
│   ├── ns_default_ssl_profile_frontend
│   │   ├── exists + ssl3 = "DISABLED"
│   │   ├── exists + tls1 = "DISABLED"
│   │   ├── exists + tls11 = "DISABLED"
│   │   ├── exists + tls12 = "ENABLED"
│   │   ├── exists + tls13 = "ENABLED"
│   │   ├── exists + denysslreneg = "NONSECURE"
│   │   └── exists + hsts = "ENABLED"
│   └── ns_default_ssl_profile_backend
│       ├── exists + ssl3 = "DISABLED"
│       ├── exists + tls1 = "DISABLED"
│       ├── exists + tls11 = "DISABLED"
│       ├── exists + tls12 = "ENABLED"
│       └── exists + tls13 = "ENABLED"
│
├── [6/16] SSL Certificates (9 assertions)
│   ├── check_resource "sslcertkey/lab-ca" ................. exists
│   ├── check_resource "sslcertkey/wildcard.lab.local"
│   │   ├── exists
│   │   └── linkcertkeyname = "lab-ca"
│   ├── file: lab-ca.crt .................................. exists in /nsconfig/ssl
│   ├── file: wildcard.lab.local.crt ...................... exists in /nsconfig/ssl
│   └── file: wildcard.lab.local.key ...................... exists in /nsconfig/ssl
│
├── [7/16] Servers, Monitors, Service Groups (22 assertions)
│   ├── server/srv_host01
│   │   ├── exists
│   │   └── ipaddress = "10.0.1.1"
│   ├── server/srv_opnsense
│   │   ├── exists
│   │   └── ipaddress = "10.0.1.2"
│   ├── lbmonitor/mon_http_200
│   │   ├── exists
│   │   └── type = "HTTP"
│   ├── lbmonitor/mon_tcp_quick
│   │   ├── exists
│   │   └── type = "TCP"
│   ├── lbmonitor/mon_https_200
│   │   ├── exists
│   │   └── type = "HTTP-ECV"
│   ├── servicegroup/sg_web_http ............. exists
│   ├── servicegroup/sg_web_https ............ exists
│   ├── servicegroup/sg_tcp_generic .......... exists
│   ├── servicegroup/sg_dns .................. exists
│   ├── sg_web_http → exists + servicetype = "HTTP"
│   ├── sg_web_https → exists + servicetype = "SSL"
│   ├── sg_tcp_generic → exists + servicetype = "TCP"
│   └── sg_dns → exists + servicetype = "DNS"
│
├── [8/16] LB & CS VServers (24 assertions)
│   ├── lbvserver/lb_vsrv_web
│   │   ├── exists + servicetype = "HTTP"
│   │   └── exists + lbmethod = "ROUNDROBIN"
│   ├── lbvserver/lb_vsrv_web_ssl
│   │   └── exists + servicetype = "SSL"
│   ├── lbvserver/lb_vsrv_api
│   │   ├── exists + servicetype = "HTTP"
│   │   └── exists + lbmethod = "LEASTCONNECTION"
│   ├── lbvserver/lb_vsrv_tcp
│   │   └── exists + servicetype = "TCP"
│   ├── lbvserver/lb_vsrv_dns
│   │   └── exists + servicetype = "DNS"
│   ├── csvserver/cs_vsrv_https
│   │   ├── exists + servicetype = "SSL"
│   │   └── exists + port = "443"
│   ├── csvserver/cs_vsrv_http
│   │   ├── exists + servicetype = "HTTP"
│   │   └── exists + port = "80"
│   ├── cspolicy/cs_pol_api .................. exists
│   ├── cspolicy/cs_pol_static ............... exists
│   ├── cspolicy/cs_pol_app .................. exists
│   ├── csaction/cs_act_api
│   │   ├── exists
│   │   └── targetlbvserver = "lb_vsrv_api"
│   └── csaction/cs_act_web
│       ├── exists
│       └── targetlbvserver = "lb_vsrv_web"
│
├── [9/16] Security Policies (55 assertions)
│   ├── Rewrite Actions (23 exists checks)
│   │   ├── rewriteaction/rw_act_xframe
│   │   ├── rewriteaction/rw_act_nosniff
│   │   ├── rewriteaction/rw_act_xss
│   │   ├── rewriteaction/rw_act_referrer
│   │   ├── rewriteaction/rw_act_permissions
│   │   ├── rewriteaction/rw_act_csp
│   │   ├── rewriteaction/rw_act_del_server
│   │   ├── rewriteaction/rw_act_del_powered
│   │   ├── rewriteaction/rw_act_del_aspnet
│   │   ├── rewriteaction/rw_act_xff
│   │   ├── rewriteaction/rw_act_xrealip
│   │   ├── rewriteaction/rw_act_xproto
│   │   ├── rewriteaction/rw_act_reqid
│   │   ├── rewriteaction/rw_act_log_req
│   │   ├── rewriteaction/rw_act_log_res
│   │   ├── rewriteaction/rw_act_download_options
│   │   ├── rewriteaction/rw_act_cross_domain
│   │   ├── rewriteaction/rw_act_cache_control
│   │   ├── rewriteaction/rw_act_cors_origin
│   │   ├── rewriteaction/rw_act_cors_methods
│   │   ├── rewriteaction/rw_act_cors_headers
│   │   ├── rewriteaction/rw_act_cors_credentials
│   │   └── rewriteaction/rw_act_cors_maxage
│   │
│   ├── Rewrite Policies (23 exists checks)
│   │   ├── rewritepolicy/rw_pol_security_headers
│   │   ├── rewritepolicy/rw_pol_nosniff
│   │   ├── rewritepolicy/rw_pol_xss
│   │   ├── rewritepolicy/rw_pol_referrer
│   │   ├── rewritepolicy/rw_pol_permissions
│   │   ├── rewritepolicy/rw_pol_csp
│   │   ├── rewritepolicy/rw_pol_del_server
│   │   ├── rewritepolicy/rw_pol_del_powered
│   │   ├── rewritepolicy/rw_pol_del_aspnet
│   │   ├── rewritepolicy/rw_pol_xff
│   │   ├── rewritepolicy/rw_pol_xrealip
│   │   ├── rewritepolicy/rw_pol_xproto
│   │   ├── rewritepolicy/rw_pol_reqid
│   │   ├── rewritepolicy/rw_pol_log_req
│   │   ├── rewritepolicy/rw_pol_log_res
│   │   ├── rewritepolicy/rw_pol_download_options
│   │   ├── rewritepolicy/rw_pol_cross_domain
│   │   ├── rewritepolicy/rw_pol_cache_control
│   │   ├── rewritepolicy/rw_pol_cors_origin
│   │   ├── rewritepolicy/rw_pol_cors_methods
│   │   ├── rewritepolicy/rw_pol_cors_headers
│   │   ├── rewritepolicy/rw_pol_cors_credentials
│   │   └── rewritepolicy/rw_pol_cors_maxage
│   │
│   ├── Responder Actions (4 exists checks)
│   │   ├── responderaction/rs_act_https_redirect
│   │   ├── responderaction/rs_act_block_bot
│   │   ├── responderaction/rs_act_maintenance
│   │   └── responderaction/rs_act_cors_preflight
│   │
│   ├── Responder Policies (4 exists checks)
│   │   ├── responderpolicy/rs_pol_https_redirect
│   │   ├── responderpolicy/rs_pol_block_bot
│   │   ├── responderpolicy/rs_pol_maint1
│   │   └── responderpolicy/rs_pol_cors_preflight
│   │
│   └── Bot Blocking Patset
│       └── policypatset/ps_bad_useragents ........... exists
│
├── [10/16] Extras (15 assertions)
│   ├── Compression Policies (5 exists checks)
│   │   ├── cmppolicy/cmp_pol_text
│   │   ├── cmppolicy/cmp_pol_json
│   │   ├── cmppolicy/cmp_pol_js
│   │   ├── cmppolicy/cmp_pol_xml
│   │   └── cmppolicy/cmp_pol_svg
│   │
│   ├── Audit Actions (2 exists checks)
│   │   ├── auditmessageaction/audit_act_request
│   │   └── auditmessageaction/audit_act_response
│   │
│   ├── AppExpert (2 exists checks)
│   │   ├── policystringmap/sm_url_routes
│   │   └── policypatset/ps_allowed_origins
│   │
│   ├── Maintenance
│   │   └── nsvariable/v_maintenance ................. exists
│   │
│   ├── Timeouts (6 assertions)
│   │   ├── nstimeout → exists + zombie = "600"
│   │   ├── nstimeout → exists + halfclose = "300"
│   │   └── nstimeout → exists + nontcpzombie = "300"
│   │
│   └── Management (4 assertions)
│       ├── nsip/$NSIP → exists + gui = "SECUREONLY"
│       └── nsip/$NSIP → exists + restrictaccess = "ENABLED"
│
├── [11/16] Service Group Member Bindings (8 assertions)
│   ├── sg_web_http ← srv_host01:80 ................. bound + port verified
│   ├── sg_web_http ← srv_opnsense:80 ............... bound + port verified
│   ├── sg_web_https ← srv_host01:443 ............... bound + port verified
│   ├── sg_web_https ← srv_opnsense:443 ............. bound + port verified
│   ├── sg_tcp_generic ← srv_host01:8080 ............ bound + port verified
│   ├── sg_tcp_generic ← srv_opnsense:8080 .......... bound + port verified
│   ├── sg_dns ← srv_host01:53 ...................... bound + port verified
│   └── sg_dns ← srv_opnsense:53 .................... bound + port verified
│
├── [11/16 cont.] Service Group Monitor Bindings (4 assertions)
│   ├── sg_web_http ← mon_http_200 .................. bound
│   ├── sg_web_https ← mon_https_200 ................ bound
│   ├── sg_tcp_generic ← mon_tcp_quick .............. bound
│   └── sg_dns ← dns (built-in) ..................... bound
│
├── [12/16] LB VServer Bindings (12 assertions)
│   ├── lb_vsrv_web ← sg_web_http ................... bound
│   ├── lb_vsrv_web_ssl ← sg_web_https .............. bound
│   ├── lb_vsrv_api ← sg_web_http ................... bound
│   ├── lb_vsrv_tcp ← sg_tcp_generic ................ bound
│   ├── lb_vsrv_dns ← sg_dns ........................ bound
│   ├── lb_vsrv_web → persistencetype = "COOKIEINSERT"
│   ├── lb_vsrv_web → cookiename = "NSLB"
│   ├── lb_vsrv_web_ssl → persistencetype = "SOURCEIP"
│   ├── lb_vsrv_api → persistencetype = "SOURCEIP"
│   ├── lb_vsrv_tcp → persistencetype = "SOURCEIP"
│   ├── lb_vsrv_tcp → ipv46 = $VIP_TCP
│   └── lb_vsrv_dns → ipv46 = $VIP_DNS
│
├── [13/16] CS VServer Bindings (31 assertions)
│   ├── CS Policy Bindings (3 — with priority verification)
│   │   ├── cs_vsrv_https ← cs_pol_api, priority = 100
│   │   ├── cs_vsrv_https ← cs_pol_static, priority = 110
│   │   └── cs_vsrv_https ← cs_pol_app, priority = 120
│   │
│   ├── SSL Cert Binding (1)
│   │   └── cs_vsrv_https ← wildcard.lab.local
│   │
│   ├── Responder Policy Bindings (4)
│   │   ├── cs_vsrv_https ← rs_pol_block_bot
│   │   ├── cs_vsrv_https ← rs_pol_maint1
│   │   ├── cs_vsrv_https ← rs_pol_cors_preflight
│   │   └── cs_vsrv_http ← rs_pol_https_redirect
│   │
│   ├── Rewrite Policy Bindings (23 — all bound to cs_vsrv_https)
│   │   ├── rw_pol_security_headers
│   │   ├── rw_pol_nosniff
│   │   ├── rw_pol_xss
│   │   ├── rw_pol_referrer
│   │   ├── rw_pol_permissions
│   │   ├── rw_pol_csp
│   │   ├── rw_pol_del_server
│   │   ├── rw_pol_del_powered
│   │   ├── rw_pol_del_aspnet
│   │   ├── rw_pol_xff
│   │   ├── rw_pol_xrealip
│   │   ├── rw_pol_xproto
│   │   ├── rw_pol_reqid
│   │   ├── rw_pol_log_req
│   │   ├── rw_pol_log_res
│   │   ├── rw_pol_download_options
│   │   ├── rw_pol_cross_domain
│   │   ├── rw_pol_cache_control
│   │   ├── rw_pol_cors_origin
│   │   ├── rw_pol_cors_methods
│   │   ├── rw_pol_cors_headers
│   │   ├── rw_pol_cors_credentials
│   │   └── rw_pol_cors_maxage
│   │
│   └── Compression Policy Bindings (5 — all bound to cs_vsrv_https)
│       ├── cmp_pol_text
│       ├── cmp_pol_json
│       ├── cmp_pol_js
│       ├── cmp_pol_xml
│       └── cmp_pol_svg
│
├── [14/16] Deep Value Validations (28 assertions)
│   ├── tcp_prof_web (24 assertions: 12 fields × 2 = exists + value)
│   │   ├── nagle = "DISABLED"
│   │   ├── maxburst = "10"
│   │   ├── initialcwnd = "16"
│   │   ├── oooqsize = "300"
│   │   ├── minrto = "400"
│   │   ├── ecn = "ENABLED"
│   │   ├── timestamp = "ENABLED"
│   │   ├── dsack = "ENABLED"
│   │   ├── frto = "ENABLED"
│   │   ├── kaconnidletime = "300"
│   │   ├── kamaxprobes = "5"
│   │   └── kaprobeinterval = "30"
│   │
│   ├── http_prof_web (16 assertions: 8 fields × 2)
│   │   ├── http2maxconcurrentstreams = "128"
│   │   ├── http2maxheaderlistsize = "32768"
│   │   ├── maxreusepool = "0"
│   │   ├── dropextradata = "ENABLED"
│   │   ├── markhttp09inval = "ENABLED"
│   │   ├── markconnreqinval = "ENABLED"
│   │   ├── marktracereqinval = "ENABLED"
│   │   └── markrfc7230noncompliantinval = "ENABLED"
│   │
│   ├── mon_http_200 (10 assertions: 5 fields × 2)
│   │   ├── interval = "10"
│   │   ├── resptimeout = "5"
│   │   ├── retries = "3"
│   │   ├── downtime = "15"
│   │   └── lrtm = "ENABLED"
│   │
│   ├── mon_tcp_quick (4 assertions: 2 fields × 2)
│   │   ├── interval = "5"
│   │   └── resptimeout = "3"
│   │
│   └── ns_default_ssl_profile_frontend (2 assertions)
│       ├── exists
│       └── maxage = "31536000"
│
├── [15/16] Certificate Expiry & Chain (5 assertions)
│   ├── check_cert_expiry "wildcard.lab.local" ≥ 30 days
│   ├── check_cert_expiry "lab-ca" ≥ 30 days
│   └── sslcertkey/wildcard.lab.local
│       ├── exists
│       └── linkcertkeyname = "lab-ca"
│
└── [16/16] Network IPs & Patset Patterns (15 assertions)
    ├── nsip/$SNIP
    │   ├── exists + type = "SNIP"
    │   └── exists + mgmtaccess = "ENABLED"
    │
    ├── Bot Pattern Bindings (8 — in ps_bad_useragents)
    │   ├── "sqlmap" ......... bound
    │   ├── "nikto" .......... bound
    │   ├── "nmap" ........... bound
    │   ├── "nuclei" ......... bound
    │   ├── "masscan" ........ bound
    │   ├── "dirbuster" ...... bound
    │   ├── "gobuster" ....... bound
    │   └── "python-requests"  bound
    │
    └── Allowed Origin Bindings (3 — in ps_allowed_origins)
        ├── "https://app.lab.local" .. bound
        ├── "https://api.lab.local" .. bound
        └── "https://lab.local" ...... bound


================================================================================
 CLI DIFF TREE (35 commands, normalized + diffed between baseline & candidate)
================================================================================

run-regression-tests.sh → collect on both VPXs → normalize IPs → sort → diff
│
├── System (4 commands)
│   ├── "show ns version" ........................... ◄ EXPECTED TO DIFFER
│   ├── "show ns hardware" .......................... ◄ EXPECTED TO DIFFER
│   ├── "show ns hostname"
│   └── "show ns ip"
│
├── Security (3 commands)
│   ├── "show system parameter"
│   ├── "show ns timeout"
│   └── "show ns variable"
│
├── Features & Modes (2 commands)
│   ├── "show ns feature"
│   └── "show ns mode"
│
├── SSL (4 commands)
│   ├── "show ssl parameter"
│   ├── "show ssl profile ns_default_ssl_profile_frontend"
│   ├── "show ssl profile ns_default_ssl_profile_backend"
│   └── "show ssl certKey"
│
├── Profiles (4 commands)
│   ├── "show ns httpProfile nshttp_default_profile"
│   ├── "show ns httpProfile http_prof_web"
│   ├── "show ns tcpProfile nstcp_default_profile"
│   └── "show ns tcpProfile tcp_prof_web"
│
├── Load Balancing (2 commands)
│   ├── "show lb vserver"
│   └── "show lb monitor"
│
├── Content Switching (3 commands)
│   ├── "show cs vserver"
│   ├── "show cs policy"
│   └── "show cs action"
│
├── Service Groups (4 commands)
│   ├── "show serviceGroup sg_web_http"
│   ├── "show serviceGroup sg_web_https"
│   ├── "show serviceGroup sg_tcp_generic"
│   └── "show serviceGroup sg_dns"
│
├── Policies (3 commands)
│   ├── "show rewrite policy"
│   ├── "show responder policy"
│   └── "show cmp policy"
│
├── Objects (6 commands)
│   ├── "show policy patset ps_bad_useragents"
│   ├── "show policy patset ps_allowed_origins"
│   ├── "show policy stringmap sm_url_routes"
│   ├── "show audit messageaction"
│   ├── "show server"
│   └── "show ssl certKey"
│
├── Normalization Rules (applied to all outputs before diff)
│   ├── 10.0.1.5 / 10.0.1.6 → NSIP
│   ├── 10.0.1.254 / 10.0.1.253 → SNIP
│   ├── 10.0.1.105 / 10.0.1.106 → VIP_CS
│   ├── 10.0.1.115 / 10.0.1.116 → VIP_TCP
│   ├── 10.0.1.125 / 10.0.1.126 → VIP_DNS
│   ├── vpx-baseline / vpx-candidate → VPX_HOSTNAME
│   ├── /uptime/i → removed
│   ├── /since/i → removed
│   ├── blank lines → removed
│   ├── numbered prefixes → stripped
│   └── Priority : NNN → stripped
│
└── Diff Classification
    ├── PASS: no differences after normalization
    ├── EXPECTED: "show ns version" or "show ns hardware"
    └── FAIL: any other command with differences → potential regression


================================================================================
 SYSTEM LOG COLLECTION (4 commands per VPX, collected but not diffed)
================================================================================

Phase 2.5: Log Collection
├── "shell tail -200 /var/log/messages" ...... last 200 lines of system log
├── "shell tail -200 /var/nslog/ns.log" ...... last 200 lines of NetScaler log
├── "show ns events" ......................... NS event history
└── "show running config" .................... full running configuration dump


================================================================================
 FINAL TOTALS
================================================================================

 Terraform Resources ............. 190
   module.system ................... 17
   module.ssl ...................... 7
   module.certificates ............. 5
   module.traffic/main.tf ......... 34
   module.traffic/cs.tf ........... 11
   module.traffic/security.tf ..... 83
   module.traffic/extras.tf ....... 33

 NITRO API Assertions (per VPX) .. ~375
   [1/16]  System ................... 4
   [2/16]  Security ................ 12
   [3/16]  Features & Modes ........ 14
   [4/16]  Profiles ................ 26
   [5/16]  SSL ..................... 25
   [6/16]  Certificates ............. 9
   [7/16]  Servers/Monitors/SGs .... 22
   [8/16]  LB/CS VServers .......... 24
   [9/16]  Security Policies ....... 55
   [10/16] Extras .................. 15
   [11/16] SG Bindings ............. 12
   [12/16] LB Bindings ............. 12
   [13/16] CS Bindings ............. 36
   [14/16] Deep Values ............. 28
   [15/16] Cert Expiry/Chain ........ 5
   [16/16] Network/Patsets ......... 15

 CLI Diff Comparisons ............ 35
   Expected to differ .............. 2
   Should be identical ............. 33

 System Logs Collected ........... 4 per VPX

 Background Host Metrics ......... every 10s (CPU, RAM, disk, network)

 × 2 VPXs (baseline + candidate)
```
