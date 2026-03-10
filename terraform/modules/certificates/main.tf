# =============================================================================
# Certificates Module — Upload cert files + create certkey bindings
# Maps: upload-certs.sh + certkey portion of apply-traffic-management.sh
# =============================================================================

# --- Upload certificate files via NITRO API ---

resource "citrixadc_systemfile" "lab_ca_crt" {
  filename     = "lab-ca.crt"
  filelocation = "/nsconfig/ssl/"
  filecontent  = var.lab_ca_crt
}

resource "citrixadc_systemfile" "wildcard_crt" {
  filename     = "wildcard.lab.local.crt"
  filelocation = "/nsconfig/ssl/"
  filecontent  = var.wildcard_crt
}

resource "citrixadc_systemfile" "wildcard_key" {
  filename     = "wildcard.lab.local.key"
  filelocation = "/nsconfig/ssl/"
  filecontent  = var.wildcard_key
}

# --- CertKey resources ---

resource "citrixadc_sslcertkey" "lab_ca" {
  certkey = "lab-ca"
  cert    = "/nsconfig/ssl/lab-ca.crt"

  depends_on = [citrixadc_systemfile.lab_ca_crt]
}

resource "citrixadc_sslcertkey" "wildcard" {
  certkey          = "wildcard.lab.local"
  cert             = "/nsconfig/ssl/wildcard.lab.local.crt"
  key              = "/nsconfig/ssl/wildcard.lab.local.key"
  linkcertkeyname  = citrixadc_sslcertkey.lab_ca.certkey

  depends_on = [
    citrixadc_systemfile.wildcard_crt,
    citrixadc_systemfile.wildcard_key,
  ]
}
