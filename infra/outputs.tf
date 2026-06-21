output "ipv4_address" {
  description = "Global anycast IPv4 of the HTTPS load balancer."
  value       = google_compute_global_address.default.address
}

output "ipv6_address" {
  description = "Global anycast IPv6 of the HTTPS load balancer."
  value       = google_compute_global_address.ipv6.address
}

output "url" {
  description = "Public URL once DNS resolves and the managed cert provisions."
  value       = "https://${var.domain}"
}

output "nameservers" {
  description = "Delegate the registrar's NS records to these so the managed zone is authoritative."
  value       = google_dns_managed_zone.default.name_servers
}

output "next_steps" {
  description = "Manual one-time steps after apply."
  value       = <<-EOT
    1. Delegate your domain's nameservers to the Cloud DNS zone:
         ${join("\n         ", google_dns_managed_zone.default.name_servers)}
       (The A/AAAA records and the cert DNS-authorization CNAME are managed here.)
    2. Add SECRET_KEY_BASE (never in TF state):
         openssl rand -base64 64 | gcloud secrets versions add ${google_secret_manager_secret.secret_key_base.secret_id} --data-file=- --project=${var.project_id}
    3. Publish the image to public GHCR (the release workflow does this) and set
       var.container_image to it (default ghcr.io/andrewdryga/onlytty:latest).
    4. Wait for the managed cert to go ACTIVE (DNS authorization can take minutes),
       then GET https://${var.domain}/healthz should return 200.
  EOT
}
