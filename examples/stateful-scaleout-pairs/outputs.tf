output "vips" {
  value       = { for k, v in google_compute_address.vip : k => v.address }
  description = <<-EOD
    A map of HA pair identifier (e.g. `pair-01`, `pair-02`) to the public VIP address for that pair.
    EOD
}

output "vip" {
  value       = google_compute_address.vip["pair-01"].address
  description = <<-EOD
    The public VIP address for the primary HA pair (`pair-01`).
    EOD
}

output "admin_password_secret_id" {
  value       = module.admin_password.secret_id
  description = <<-EOD
    The Secret Manager secret identifier containing the BIG-IP admin password shared across all HA pairs.
    EOD
}

output "self_links" {
  value       = merge([for k, m in module.bigip_ha : m.self_links]...)
  description = <<-EOD
    A flattened map of BIG-IP instance name to fully-qualified self-link across all HA pairs.
    EOD
}

output "pairs_self_links" {
  value       = { for k, m in module.bigip_ha : k => m.self_links }
  description = <<-EOD
    A map of HA pair identifier to its map of BIG-IP instance names and self-links.
    EOD
}
