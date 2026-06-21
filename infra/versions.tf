# OnlyTTY infrastructure — GCP. A global external HTTPS load balancer (Google-
# managed TLS via Certificate Manager) fronts a regional Managed Instance Group
# running the onlytty container on Container-Optimized OS. The image is pulled
# from public GHCR. TLS terminates at the LB (no sidecar TLS proxy) and there is
# no GCP image registry.
#
# The MIG is size 1 by design: sessions are in-memory per instance, so a multi-
# instance group would split a session's runner and viewer (see lb.tf + README).

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Remote state in a pre-created, versioned GCS bucket. Create it once:
  #   gcloud storage buckets create gs://<your-tf-state-bucket> --location=<region>
  #   gcloud storage buckets update gs://<your-tf-state-bucket> --versioning
  # then: terraform init -backend-config="bucket=<your-tf-state-bucket>"
  backend "gcs" {
    prefix = "onlytty"
  }
}
