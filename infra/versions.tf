# OnlyTTY infrastructure — GCP. Pragmatic + cheap: one small GCE VM running the
# onlytty container behind Caddy (auto-TLS). Chosen over Cloud Run because the relay
# holds long-lived WebSockets (up to 7 days) and Cloud Run caps a request at 60 min.

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
