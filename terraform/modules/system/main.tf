# =============================================================================
# System Hardening Module
# Maps: apply-enterprise-config.sh + ssl parameter enable
# =============================================================================

# --- Step 1: System Identity & Network ---

resource "citrixadc_nshostname" "this" {
  hostname = var.hostname
}

resource "citrixadc_dnsnameserver" "cloudflare" {
  ip = "1.1.1.1"
}

resource "citrixadc_dnsnameserver" "google" {
  ip = "8.8.8.8"
}

resource "citrixadc_ntpserver" "pool" {
  servername = "pool.ntp.org"
}

# citrixadc_ntpsync has a provider bug ("Root object was present, but now
# absent") — NTP sync is enabled via NITRO in change-default-password.sh

# --- Step 2: Security Hardening ---

resource "citrixadc_systemparameter" "this" {
  strongpassword      = "enableall"
  minpasswordlen      = 8
  maxclient           = 10
  timeout             = 600
  restrictedtimeout   = "ENABLED"
  forcepasswordchange = "DISABLED"
}

resource "citrixadc_nsrpcnode" "this" {
  ipaddress = var.nsip
  password  = var.rpc_password
  secure    = "ON"
}

# nsroot user managed by change-default-password.sh — the provider has a
# bug with the built-in user ("Root object was present, but now absent")

resource "citrixadc_nsparam" "this" {
  cookieversion = 1
}

# --- Step 3: Features & Modes ---

resource "citrixadc_nsfeature" "this" {
  lb        = true
  cs        = true
  ssl       = true
  rewrite   = true
  responder = true
  aaa       = true
  appflow   = true
  cmp       = true
  sslvpn    = true
  ch        = false
}

resource "citrixadc_nsmode" "this" {
  fr   = true
  tcpb = true
  edge = true
  l3   = true
  ulfd = true
}

# --- Step 4: HTTP Profile Hardening ---

resource "citrixadc_nshttpprofile" "default" {
  name                         = "nshttp_default_profile"
  dropinvalreqs                = "ENABLED"
  markhttp09inval              = "ENABLED"
  markconnreqinval             = "ENABLED"
  marktracereqinval            = "ENABLED"
  markrfc7230noncompliantinval = "ENABLED"
}

# --- Step 5: TCP Profile Hardening ---

resource "citrixadc_nstcpprofile" "default" {
  name                = "nstcp_default_profile"
  rstwindowattenuate  = "ENABLED"
  spoofsyndrop        = "ENABLED"
  ecn                 = "ENABLED"
  timestamp           = "ENABLED"
  dsack               = "ENABLED"
  frto                = "ENABLED"
}

# --- Step 6: Management Access ---

resource "citrixadc_nsip" "mgmt" {
  ipaddress      = var.nsip
  netmask        = "255.255.255.0"
  type           = "NSIP"
  restrictaccess = "ENABLED"
  gui            = "SECUREONLY"
}

# --- Step 7: Audit & Logging ---

resource "citrixadc_auditnslogparams" "this" {
  loglevel = ["ALL"]
}

resource "citrixadc_auditmessageaction" "enterprise_log" {
  name     = "enterprise_log"
  loglevel = "INFORMATIONAL"
  stringbuilderexpr = "\"Enterprise audit: \" + CLIENT.IP.SRC + \" \" + HTTP.REQ.URL"
}

# --- Step 8: Timeout Tuning ---

resource "citrixadc_nstimeout" "this" {
  zombie        = 600
  halfclose     = 300
  nontcpzombie  = 300
}

# --- SSL Parameter (requires warm reboot after apply) ---

resource "citrixadc_sslparameter" "this" {
  defaultprofile = "ENABLED"
}

# --- Save Config ---

resource "citrixadc_nsconfig_save" "this" {
  all        = true
  timestamp  = timestamp()

  depends_on = [
    citrixadc_nshostname.this,
    citrixadc_systemparameter.this,
    citrixadc_nsfeature.this,
    citrixadc_nsmode.this,
    citrixadc_sslparameter.this,
    citrixadc_nstimeout.this,
  ]
}
