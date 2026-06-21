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
  type = string
  # Lowercase owner — Docker refs must be lowercase, and release.yml publishes to
  # ghcr.io/<owner>/onlytty (lowercased). Default is the mutable :latest tag; the
  # Deploy workflow re-pulls it via a MIG rolling-replace. For a reproducible
  # `terraform apply` rollout, override with a pinned version tag or digest
  # (e.g. ghcr.io/andrewdryga/onlytty:0.1.0) in terraform.tfvars.
  description = "Fully-qualified onlytty image (public GHCR). Pin a version tag/digest for reproducible applies."
  default     = "ghcr.io/andrewdryga/onlytty:latest"
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
  description = "MIG size. Sessions are registered cluster-wide via :global, so >1 is supported once the nodes form a BEAM cluster — set dns_cluster_query so DNSCluster can find peers."
  default     = 1

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be >= 1."
  }
}

variable "dns_cluster_query" {
  type        = string
  description = "DNS name resolving to ALL relay instance IPs, polled by DNSCluster to form the BEAM cluster. Required when instance_count > 1; leave empty for a single instance. On a GCP MIG, point it at a Cloud DNS record covering the instances (see README); on headless-DNS platforms it is automatic."
  default     = ""
}

variable "backend_timeout_sec" {
  type        = number
  description = "LB backend timeout. For WebSockets this caps a single connection's lifetime; the runner reconnects+resumes, so a day is plenty and avoids holding backends forever."
  default     = 86400
}
