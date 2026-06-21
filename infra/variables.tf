variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into (e.g. onlytty)."
}

variable "region" {
  type        = string
  description = "GCP region for the regional MIG."
  default     = "us-central1"
}

variable "domain" {
  type        = string
  description = "Public hostname for the relay (e.g. onlytty.com). Served by the HTTPS LB."
}

variable "dns_name" {
  type        = string
  description = "DNS name of the Cloud DNS managed zone, with a trailing dot (e.g. onlytty.com.)."
}

variable "container_image" {
  type        = string
  description = "Fully-qualified onlytty image. Public GHCR by default; the release workflow publishes it."
  default     = "ghcr.io/AndrewDryga/onlytty:latest"
}

variable "app_port" {
  type        = number
  description = "Port the relay container listens on (LB backend + health check target)."
  default     = 4000
}

variable "machine_type" {
  type        = string
  description = "Instance size. e2-small is ~US$13/mo."
  default     = "e2-small"
}

variable "instance_count" {
  type        = number
  description = "MIG size. MUST stay 1 — sessions are in-memory per instance (see lb.tf / README)."
  default     = 1

  validation {
    condition     = var.instance_count == 1
    error_message = "instance_count must be 1 until BEAM clustering + a shared session registry land; >1 splits a session's runner and viewer across instances."
  }
}

variable "backend_timeout_sec" {
  type        = number
  description = "LB backend timeout. For WebSockets this caps a single connection's lifetime; the runner reconnects+resumes, so a day is plenty and avoids holding backends forever."
  default     = 86400
}
