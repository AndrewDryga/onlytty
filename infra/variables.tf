variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into (e.g. onlytty)."
}

variable "region" {
  type        = string
  description = "GCP region for the regional MIG."
  default     = "us-central1"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR block for the dedicated OnlyTTY subnet."
  default     = "10.80.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 1))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
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
  type = string
  # Lowercase owner — Docker refs must be lowercase, and release.yml publishes to
  # ghcr.io/<owner>/onlytty (lowercased). Default is the mutable :latest tag; the
  # manual Promote image workflow can set a pinned tag in TFC. For a reproducible
  # `terraform apply` rollout, override with a pinned version tag or digest.
  description = "Fully-qualified onlytty image (public GHCR). Pin a version tag/digest for reproducible applies."
  default     = "ghcr.io/andrewdryga/onlytty:latest"
}

variable "app_port" {
  type        = number
  description = "Port the relay container listens on (LB backend + health check target)."
  default     = 4000

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535 && floor(var.app_port) == var.app_port
    error_message = "app_port must be an integer between 1 and 65535."
  }
}

variable "machine_type" {
  type        = string
  description = "Compute Engine machine type for the relay instances."
}

variable "instance_count" {
  type        = number
  description = "MIG size. Sessions are registered cluster-wide via :global and the nodes form a BEAM cluster automatically (libcluster's GCE strategy discovers peers via the Compute API), so >1 needs no extra configuration."
  default     = 2

  validation {
    condition     = var.instance_count >= 1 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be an integer >= 1."
  }
}

variable "backend_timeout_sec" {
  type        = number
  description = "LB backend timeout. For WebSockets this caps a single connection's lifetime; the runner reconnects+resumes, so a day is plenty and avoids holding backends forever."
  default     = 86400

  validation {
    condition     = var.backend_timeout_sec >= 1 && var.backend_timeout_sec <= 86400 && floor(var.backend_timeout_sec) == var.backend_timeout_sec
    error_message = "backend_timeout_sec must be an integer between 1 and 86400."
  }
}
