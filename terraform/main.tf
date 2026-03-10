provider "citrixadc" {
  endpoint = "https://${var.nsip}"
  username = "nsroot"
  password = var.password

  insecure_skip_verify = true
}

module "system" {
  source = "./modules/system"

  nsip         = var.nsip
  hostname     = var.hostname
  rpc_password = var.rpc_password
}

module "ssl" {
  source = "./modules/ssl"
}

module "certificates" {
  source = "./modules/certificates"

  lab_ca_crt   = var.lab_ca_crt
  wildcard_crt = var.wildcard_crt
  wildcard_key = var.wildcard_key
}

module "traffic" {
  source = "./modules/traffic"

  nsip    = var.nsip
  snip    = var.snip
  vip_cs  = var.vip_cs
  vip_tcp = var.vip_tcp
  vip_dns = var.vip_dns

  depends_on = [module.ssl, module.certificates]
}
