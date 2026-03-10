output "nsip" {
  description = "Management IP"
  value       = var.nsip
}

output "hostname" {
  description = "NetScaler hostname"
  value       = var.hostname
}

output "snip" {
  description = "Subnet IP"
  value       = var.snip
}

output "vip_cs" {
  description = "Content switching VIP"
  value       = var.vip_cs
}

output "vip_tcp" {
  description = "TCP LB VIP"
  value       = var.vip_tcp
}

output "vip_dns" {
  description = "DNS LB VIP"
  value       = var.vip_dns
}
