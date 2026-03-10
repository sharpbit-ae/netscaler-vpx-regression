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
