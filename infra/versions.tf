# OnlyTTY infrastructure — GCP. A global external HTTPS load balancer (Google-
# managed TLS via Certificate Manager) fronts a regional Managed Instance Group
# running the onlytty container on Container-Optimized OS in a dedicated VPC. The
# image is pulled from public GHCR. TLS terminates at the LB (no sidecar TLS
# proxy) and there is no GCP image registry.
#
# A single small VM is the cheapest setup; larger MIGs work out of the box — the BEAM
# nodes discover each other via libcluster's GCE strategy (see lb.tf + README).

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
