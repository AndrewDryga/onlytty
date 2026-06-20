# infra — OnlyTTY on GCP

A small, cheap, pragmatic deployment: **one GCE VM** (Container-Optimized OS) running
the `onlytty` relay container behind **Caddy** (automatic Let's Encrypt TLS), with a
static IP, Artifact Registry for the image, and `SECRET_KEY_BASE` in Secret Manager.

## Why a VM, not Cloud Run

The relay holds **long-lived WebSockets** (up to 7 days). Cloud Run caps a single
request/connection at 60 minutes, so it can't host these sessions. A single `e2-small`
VM (~US$13/mo; `e2-micro` is near the always-free tier) handles it with no per-connection
limit — and Caddy gives free TLS without a paid load balancer.

```
DNS A record ──► static IP ──► VM (COS)
                                 ├── caddy:2        :80/:443  (auto-TLS, x-forwarded-proto)
                                 └── onlytty         :4000     (PHX_SERVER, in-memory, no DB)
```

## First-time setup

```bash
# 0. A versioned GCS bucket for Terraform state (once):
gcloud storage buckets create gs://<tf-state-bucket> --location=us-central1
gcloud storage buckets update gs://<tf-state-bucket> --versioning

# 1. Configure:
cp terraform.tfvars.example terraform.tfvars   # then edit (project, domain, image, email)

# 2. Apply:
terraform init -backend-config="bucket=<tf-state-bucket>"
terraform apply

# 3. Point DNS at the IP from `terraform output ip_address` (A record).

# 4. Add the session secret (never stored in TF state):
openssl rand -base64 64 | gcloud secrets versions add onlytty-secret-key-base \
  --data-file=- --project=<project>

# 5. Publish an image to the registry from `terraform output registry`
#    (the release workflow in .github/workflows does this), then reboot the VM
#    (or it pulls on next boot): gcloud compute instances reset onlytty-relay --zone=<zone>
```

## Notes

- **State & secrets:** `terraform.tfvars` and `*.tfstate*` are git-ignored. The
  `SECRET_KEY_BASE` value lives only in Secret Manager, never in TF.
- **Updating the app:** push a new image tag, set `container_image`, `terraform apply`
  (or just `gcloud compute instances reset` — `start.sh` re-pulls `latest` on boot).
- **Lock SSH down:** set `ssh_source_ranges` to your IP in `terraform.tfvars`.
- **Validate locally:** `terraform fmt -check -recursive && terraform init -backend=false && terraform validate`.
