# OnlyTTY infrastructure — GCP. A global external HTTPS load balancer (Google-
# managed TLS via Certificate Manager) fronts a regional Managed Instance Group
# running the onlytty container on Container-Optimized OS in a dedicated VPC. The
# image is pulled from public GHCR. TLS terminates at the LB (no sidecar TLS
# proxy) and there is no GCP image registry.
#
# The default is one small VM for cost. Larger MIGs are supported when the BEAM
# nodes can discover each other via dns_cluster_query (see lb.tf + README).

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # State lives in Terraform Cloud:
  # https://app.terraform.io/app/OnlyTTY/workspaces/onlytty
  cloud {
    organization = "OnlyTTY"

    workspaces {
      name = "onlytty"
    }
  }
}
