variable "nsip" {
  description = "NetScaler management IP"
  type        = string
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
