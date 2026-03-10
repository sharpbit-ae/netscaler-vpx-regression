variable "nsip" {
  description = "NetScaler management IP (NSIP)"
  type        = string
}

variable "password" {
  description = "nsroot password"
  type        = string
  sensitive   = true
}

variable "hostname" {
  description = "NetScaler hostname"
  type        = string
}

variable "rpc_password" {
  description = "RPC node password"
  type        = string
  sensitive   = true
}

variable "snip" {
  description = "Subnet IP (SNIP)"
  type        = string
}

variable "vip_cs" {
  description = "Content switching VIP"
  type        = string
}

variable "vip_tcp" {
  description = "TCP load balancing VIP"
  type        = string
}

variable "vip_dns" {
  description = "DNS load balancing VIP"
  type        = string
}

variable "lab_ca_crt" {
  description = "Lab CA certificate content (PEM)"
  type        = string
  sensitive   = true
}

variable "wildcard_crt" {
  description = "Wildcard certificate content (PEM)"
  type        = string
  sensitive   = true
}

variable "wildcard_key" {
  description = "Wildcard private key content (PEM)"
  type        = string
  sensitive   = true
}
