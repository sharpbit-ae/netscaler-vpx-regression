variable "nsip" {
  description = "NetScaler management IP"
  type        = string
}

variable "snip" {
  description = "Subnet IP"
  type        = string
}

variable "vip_cs" {
  description = "Content switching VIP"
  type        = string
}

variable "vip_tcp" {
  description = "TCP LB VIP"
  type        = string
}

variable "vip_dns" {
  description = "DNS LB VIP"
  type        = string
}
