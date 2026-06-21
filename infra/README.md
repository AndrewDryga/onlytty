# infra — OnlyTTY on GCP

A production deployment fronted by a **global external HTTPS load balancer** with a
**Google-managed TLS certificate** (Certificate Manager + DNS authorization), backing
a **regional Managed Instance Group** of Container-Optimized OS instances in a
dedicated VPC/subnet. The instances run the `onlytty` relay container pulled from
**public GHCR**. `SECRET_KEY_BASE` lives in Secret Manager. TLS terminates at the load
balancer — there is no sidecar TLS proxy and no GCP image registry.

```
            ┌─ IPv4/IPv6 anycast ─┐
DNS A/AAAA ─┤  HTTPS LB (TLS, LB- ├─► backend (HTTP, /healthz) ─► dedicated VPC ─► MIG (1+ nodes)
            │  managed cert)      │                                                COS, BEAM, no DB
            └─ :80 → :443 redirect┘
```

WebSockets traverse the HTTP backend natively (Upgrade); `backend_timeout_sec` caps a
single connection's lifetime (default 1 day) and the runner reconnects + resumes.

## Scaling out (more than one instance)

OnlyTTY sessions are held **in memory on the node that created them**, but each session
is registered **cluster-wide via `:global`**, so a runner and a viewer that land on
different instances resolve the same session over Erlang distribution. To run more than
one node:

1. Set `instance_count` > 1.
2. Set `dns_cluster_query` to a DNS name that resolves to **all** instance IPs —
   DNSCluster polls it to connect the nodes. This is the one operator-supplied piece on
   a bare GCP MIG (point it at a Cloud DNS record covering the instances, or a managed
   internal record the instances register into); on headless-DNS platforms (Fly, k8s)
   the platform name works directly.

Terraform rejects `instance_count > 1` when `dns_cluster_query` is empty, because a
multi-node MIG without cluster discovery can split a runner and viewer across nodes.

The container runs with `--network host`, and the `onlytty-allow-cluster` firewall opens
epmd (4369) + the distribution ports (9100–9105) tag→tag between the relay's own
instances only. Each node is named `onlytty@<internal-ip>`; the cookie is the
hex SHA-256 of `onlytty-release-cookie:<SECRET_KEY_BASE>`, so it stays stable across
image builds and rolling updates without adding another secret. A node that dies loses
only its own sessions — the runner reconnects and re-creates — which is fine: the live
sockets die with the node, so there is no session hand-off to engineer.

## Image: public vs private GHCR

The default pulls `ghcr.io/andrewdryga/onlytty:latest` **anonymously** — publish the
image publicly (the release workflow does) and the instances need no registry
credentials. For a private repo instead: store a read-only GHCR PAT in Secret Manager
and add a `docker login ghcr.io` step in `templates/cloud-init.yaml` before the pull.

## First-time setup

```bash
# 0. Log in to Terraform Cloud (once):
terraform login

# 1. Configure:
cp terraform.tfvars.example terraform.tfvars   # then edit (project, domain, dns_name, image)

# 2. Apply:
terraform init
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

State is stored in the Terraform Cloud workspace
`OnlyTTY/onlytty` (`https://app.terraform.io/app/OnlyTTY/workspaces/onlytty`). If the
workspace uses local execution, your local `gcloud` credentials perform the plan/apply.
If it uses remote execution, configure GCP credentials in the Terraform Cloud workspace
variables before applying, and set the Terraform input variables there too
(`terraform.tfvars` is intentionally excluded by `.terraformignore`).

## Variables & secrets

| Variable | Default | Meaning |
|----------|---------|---------|
| `project_id` | — | GCP project (e.g. `onlytty`) |
| `domain` | — | public hostname served by the LB |
| `dns_name` | — | Cloud DNS managed-zone name, trailing dot (e.g. `onlytty.com.`) |
| `subnet_cidr` | `10.80.0.0/24` | CIDR for the dedicated OnlyTTY subnet |
| `container_image` | `ghcr.io/andrewdryga/onlytty:latest` | public GHCR image |
| `app_port` | `4000` | relay container port (LB backend + health check) |
| `machine_type` | `e2-small` | instance size |
| `instance_count` | `1` | MIG size; `>1` requires `dns_cluster_query` |
| `dns_cluster_query` | `""` | DNS name resolving to all relay instance IPs for BEAM clustering |
| `backend_timeout_sec` | `86400` | LB backend timeout = max WebSocket lifetime |

`SECRET_KEY_BASE` is **not** a variable — it lives only in Secret Manager, never in TF
state. `terraform.tfvars` and `*.tfstate*` are git-ignored.

## Notes

- **Updating the app:** push a new image tag, set `container_image`, `terraform apply`
  (a rolling MIG update replaces the instance). For a plain image re-pull at the current
  tag, the `Deploy` GitHub workflow (`.github/workflows/deploy.yml`) runs
  `gcloud compute instance-groups managed rolling-action replace onlytty-mig
  --region=<region>` after a release; run that command manually for an ad-hoc roll.
- **No external IP:** instances have no public IP. Egress (GHCR pull, Secret Manager,
  Cloud Logging) goes through **Cloud NAT** scoped only to the dedicated OnlyTTY subnet;
  ingress arrives from the LB over the internal network.
- **SSH:** via Identity-Aware Proxy only — `gcloud compute ssh <instance>
  --tunnel-through-iap` (works without a public IP). No `0.0.0.0/0` SSH rule.
- **Validate locally:** after `terraform login` + `terraform init`, run
  `terraform fmt -check -recursive && terraform validate`.
- **Live `plan`/`apply` + end-to-end HTTPS/WS verification** is the separate
  creds-gated deploy step.
