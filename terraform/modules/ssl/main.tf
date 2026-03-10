# =============================================================================
# SSL Module — Profile settings and cipher bindings
# Maps: apply-ssl-profile.sh configure-ciphers phase
# NOTE: Only apply AFTER warm reboot (ssl defaultProfile must be active)
# =============================================================================

# --- Frontend SSL Profile ---

resource "citrixadc_sslprofile" "frontend" {
  name = "ns_default_ssl_profile_frontend"

  ssl3    = "DISABLED"
  tls1    = "DISABLED"
  tls11   = "DISABLED"
  tls12   = "ENABLED"
  tls13   = "ENABLED"

  denysslreneg = "NONSECURE"
  hsts         = "ENABLED"
  maxage       = 31536000
}

# --- Backend SSL Profile ---

resource "citrixadc_sslprofile" "backend" {
  name = "ns_default_ssl_profile_backend"

  ssl3    = "DISABLED"
  tls1    = "DISABLED"
  tls11   = "DISABLED"
  tls12   = "ENABLED"
  tls13   = "ENABLED"
}

# --- Frontend Cipher Bindings ---
# Unbinding DEFAULT is handled implicitly — we only bind the ciphers we want.

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_aes256_gcm" {
  name            = citrixadc_sslprofile.frontend.name
  ciphername      = "TLS1.2-AES256-GCM-SHA384"
  cipherpriority  = 1
}

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_aes128_gcm" {
  name            = citrixadc_sslprofile.frontend.name
  ciphername      = "TLS1.2-AES128-GCM-SHA256"
  cipherpriority  = 2
}

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_tls13_aes256" {
  name            = citrixadc_sslprofile.frontend.name
  ciphername      = "TLS1.3-AES256-GCM-SHA384"
  cipherpriority  = 3
}

resource "citrixadc_sslprofile_sslcipher_binding" "frontend_tls13_chacha" {
  name            = citrixadc_sslprofile.frontend.name
  ciphername      = "TLS1.3-CHACHA20-POLY1305-SHA256"
  cipherpriority  = 4
}

# --- Save Config ---

resource "citrixadc_nsconfig_save" "ssl" {
  all       = true
  timestamp = timestamp()

  depends_on = [
    citrixadc_sslprofile.frontend,
    citrixadc_sslprofile.backend,
    citrixadc_sslprofile_sslcipher_binding.frontend_aes256_gcm,
    citrixadc_sslprofile_sslcipher_binding.frontend_aes128_gcm,
    citrixadc_sslprofile_sslcipher_binding.frontend_tls13_aes256,
    citrixadc_sslprofile_sslcipher_binding.frontend_tls13_chacha,
  ]
}
