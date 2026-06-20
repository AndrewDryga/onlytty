output "ip_address" {
  description = "Static external IP. Create a DNS A record: domain -> this IP."
  value       = google_compute_address.onlytty.address
}

output "url" {
  description = "Public URL once DNS resolves and Caddy has a cert."
  value       = "https://${var.domain}"
}

output "registry" {
  description = "Push the onlytty image here (CI does this)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.onlytty.repository_id}"
}

output "next_steps" {
  description = "Manual one-time steps after apply."
  value       = <<-EOT
    1. DNS:    A   ${var.domain}   ->   ${google_compute_address.onlytty.address}
    2. Secret: openssl rand -base64 64 | gcloud secrets versions add ${google_secret_manager_secret.secret_key_base.secret_id} --data-file=- --project=${var.project_id}
    3. Image:  push ${var.region}-docker.pkg.dev/${var.project_id}/onlytty/onlytty:<tag> (CI publishes it); the VM pulls on (re)boot.
  EOT
}
