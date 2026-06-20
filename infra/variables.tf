variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into."
}

variable "region" {
  type        = string
  description = "GCP region (Artifact Registry + static IP)."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the VM."
  default     = "us-central1-a"
}

variable "domain" {
  type        = string
  description = "Public hostname for the relay; create a DNS A record pointing at the VM's IP (an output)."
}

variable "acme_email" {
  type        = string
  description = "Contact email for Caddy's Let's Encrypt certificates."
}

variable "machine_type" {
  type        = string
  description = "VM size. e2-small is ~US$13/mo; e2-micro is near the always-free tier."
  default     = "e2-small"
}

variable "container_image" {
  type        = string
  description = "Fully-qualified onlytty image, e.g. us-central1-docker.pkg.dev/PROJECT/onlytty/onlytty:TAG. CI publishes it to the registry output."
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (tcp/22). Lock this down to your IP in production."
  default     = ["0.0.0.0/0"]
}
