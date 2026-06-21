# infra — OnlyTTY on GCP

A production deployment fronted by a **global external HTTPS load balancer** with a
**Google-managed TLS certificate** (Certificate Manager + DNS authorization), backing
a **regional Managed Instance Group** of Container-Optimized OS instances that run the
`onlytty` relay container pulled from **public GHCR**. `SECRET_KEY_BASE` lives in Secret
Manager. TLS terminates at the load balancer — there is no sidecar TLS proxy and no GCP
image registry.

```
            ┌─ IPv4/IPv6 anycast ─┐
DNS A/AAAA ─┤  HTTPS LB (TLS, LB- ├─► backend (HTTP, /healthz) ─► MIG (size 1) ─► onlytty :4000
            │  managed cert)      │                                  COS instance, in-memory, no DB
            └─ :80 → :443 redirect┘
```

WebSockets traverse the HTTP backend natively (Upgrade); `backend_timeout_sec` caps a
single connection's lifetime (default 1 day) and the runner reconnects + resumes.

## ⚠️ The MIG stays at one instance

OnlyTTY sessions are held **in memory on the instance that created them**
(`Onlytty.SessionStore` is not shared). With more than one instance a session's runner
and viewer can land on different instances and never connect — and LB session affinity
cannot fix it, because the runner and the viewer are *different clients*. So
`instance_count` is **1** and the variable validation enforces it. Raising it requires a
follow-up that adds BEAM clustering + a distributed session registry (libcluster +
`pg`/Horde); file that separately before scaling out.

## Image: public vs private GHCR

The default pulls `ghcr.io/AndrewDryga/onlytty:latest` **anonymously** — publish the
image publicly (the release workflow does) and the instances need no registry
credentials. For a private repo instead: store a read-only GHCR PAT in Secret Manager
and add a `docker login ghcr.io` step in `templates/cloud-init.yaml` before the pull.

## First-time setup

```bash
# 0. A versioned GCS bucket for Terraform state (once):
gcloud storage buckets create gs://<tf-state-bucket> --location=us-central1
gcloud storage buckets update gs://<tf-state-bucket> --versioning

# 1. Configure:
cp terraform.tfvars.example terraform.tfvars   # then edit (project, domain, dns_name, image)

# 2. Apply:
terraform init -backend-config="bucket=<tf-state-bucket>"
terraform apply

# 3. Delegate your domain's nameservers to the Cloud DNS zone:
terraform output nameservers      # set these as the NS records at your registrar
#    (A/AAAA + the cert DNS-authorization CNAME are managed in the zone for you.)

# 4. Add the session secret (never stored in TF state):
openssl rand -base64 64 | gcloud secrets versions add onlytty-secret-key-base \
  --data-file=- --project=<project>

# 5. Publish the image to public GHCR (the release workflow in .github/workflows
#    does this). Instances pull it on boot.
```

The Google-managed cert goes ACTIVE once the DNS authorization resolves (minutes after
the NS delegation propagates). Then `GET https://<domain>/healthz` returns 200.

## Variables & secrets

| Variable | Default | Meaning |
|----------|---------|---------|
| `project_id` | — | GCP project (e.g. `onlytty`) |
| `domain` | — | public hostname served by the LB |
| `dns_name` | — | Cloud DNS managed-zone name, trailing dot (e.g. `onlytty.com.`) |
| `container_image` | `ghcr.io/AndrewDryga/onlytty:latest` | public GHCR image |
| `app_port` | `4000` | relay container port (LB backend + health check) |
| `machine_type` | `e2-small` | instance size |
| `instance_count` | `1` | **must stay 1** (in-memory sessions); enforced by validation |
| `backend_timeout_sec` | `86400` | LB backend timeout = max WebSocket lifetime |

`SECRET_KEY_BASE` is **not** a variable — it lives only in Secret Manager, never in TF
state. `terraform.tfvars` and `*.tfstate*` are git-ignored.

## Notes

- **Updating the app:** push a new image tag, set `container_image`, `terraform apply`
  (a rolling MIG update replaces the instance), or `gcloud compute instance-groups
  managed rolling-action restart onlytty-mig --region=<region>`.
- **SSH:** via Identity-Aware Proxy only — `gcloud compute ssh <instance>
  --tunnel-through-iap`. No `0.0.0.0/0` SSH rule.
- **Validate locally (no creds):**
  `terraform fmt -check -recursive && terraform init -backend=false && terraform validate`.
- **Live `plan`/`apply` + end-to-end HTTPS/WS verification** is the separate
  creds-gated deploy step.
