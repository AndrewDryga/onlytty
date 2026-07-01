terraform {
  # State lives in Terraform Cloud:
  # https://app.terraform.io/app/OnlyTTY/workspaces/onlytty
  cloud {
    organization = "OnlyTTY"

    workspaces {
      name = "onlytty"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── APIs ────────────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "certificatemanager.googleapis.com",
    "dns.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── Network: a small dedicated VPC instead of the project default network ────
#
# The default VPC often carries broad "allow internal" rules and unrelated subnets.
# A dedicated network keeps OnlyTTY's firewall and NAT blast radius obvious without
# adding runtime cost.
resource "google_compute_network" "onlytty" {
  name                    = "onlytty-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "onlytty" {
  name                     = "onlytty-${var.region}"
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  network                  = google_compute_network.onlytty.id
  private_ip_google_access = true
}

# ── SECRET_KEY_BASE — created here, value added out-of-band (never in state) ─
resource "google_secret_manager_secret" "secret_key_base" {
  secret_id = "onlytty-secret-key-base"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

# ── Least-privilege service account for the instances ───────────────────────
# No image-registry GCP role: the image is pulled anonymously from public GHCR
# (see cloud-init). If you switch to a private GHCR repo, inject a read-only PAT
# via Secret Manager + `docker login` in cloud-init instead — still no GCP role.
resource "google_service_account" "vm" {
  account_id   = "onlytty-vm"
  display_name = "OnlyTTY relay instance"
}

resource "google_secret_manager_secret_iam_member" "vm_reads_secret" {
  secret_id = google_secret_manager_secret.secret_key_base.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_writes_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Read-only Compute access so the relay's libcluster GCE strategy can list the MIG's
# instances (compute.instances.list / compute.zones.list) to discover its cluster peers.
resource "google_project_iam_member" "vm_reads_compute" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# ── Health check (drives both the LB backend and MIG auto-healing) ───────────
resource "google_compute_health_check" "app" {
  name                = "onlytty-healthz"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/healthz"
    port         = var.app_port
    # force_ssl 301-redirects non-localhost hosts to HTTPS (Plug.SSL exempts localhost),
    # so the plain-HTTP probe must send Host: localhost or it gets a 301 (= unhealthy).
    host = "localhost"
  }

  depends_on = [google_project_service.apis]
}

# ── Instance template: Container-Optimized OS launching the relay container ──
data "google_compute_image" "cos" {
  project = "cos-cloud"
  family  = "cos-stable"
}

locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_image = var.container_image
    project_id      = var.project_id
    secret_name     = google_secret_manager_secret.secret_key_base.secret_id
    domain          = var.domain
    app_port        = var.app_port
  })
}

# Cloud Router + Cloud NAT give private instances outbound internet (GHCR image
# pull) without per-VM external IPs. NAT is scoped to the dedicated OnlyTTY subnet.
resource "google_compute_router" "onlytty" {
  name    = "onlytty-router"
  region  = var.region
  network = google_compute_network.onlytty.id

  depends_on = [google_project_service.apis]
}

resource "google_compute_router_nat" "onlytty" {
  name                               = "onlytty-nat"
  router                             = google_compute_router.onlytty.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.onlytty.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_instance_template" "onlytty" {
  name_prefix  = "onlytty-"
  machine_type = var.machine_type
  tags         = ["onlytty"]

  # libcluster's GCE strategy (OnlyTTY.Cluster.GCE) finds cluster peers by this label.
  labels = {
    cluster_name = "onlytty"
  }

  disk {
    source_image = data.google_compute_image.cos.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }

  # No external IP — egress (pull the image from GHCR, reach Secret Manager /
  # Cloud Logging) goes through Cloud NAT below; ingress arrives from the LB over
  # the internal network. IAP SSH tunnels through Google, so it needs no public IP.
  network_interface {
    network    = google_compute_network.onlytty.id
    subnetwork = google_compute_subnetwork.onlytty.id
  }

  metadata = {
    user-data                 = local.cloud_init
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ── Regional Managed Instance Group with auto-healing + rolling updates ──────
#
# Scaling: OnlyTTY sessions live IN MEMORY on the node that created them, but are now
# registered CLUSTER-WIDE via :global, so a runner and a viewer that land on different
# instances resolve the same session over Erlang distribution. Raising target_size just
# works: libcluster's GCE strategy (OnlyTTY.Cluster.GCE) discovers the new instances via
# the Compute API, and the onlytty-allow-cluster firewall (epmd + dist ports) lets them
# form one BEAM cluster. A node still loses only its own sessions if it dies (the runner
# reconnects and re-creates), by design.
resource "google_compute_region_instance_group_manager" "onlytty" {
  name               = "onlytty-mig"
  base_instance_name = "onlytty"
  region             = var.region
  target_size        = var.instance_count
  # EVEN can block a rollout when one selected zone is temporarily out of small VM
  # capacity. BALANCED still preserves zone diversity for the serving fleet, but lets
  # GCE prioritize zones that can actually allocate the replacement instances.
  distribution_policy_target_shape = "BALANCED"

  # Block `terraform apply` until the rollout finishes and every instance is on the new
  # version and stable — so a broken deploy (instances that never come up healthy) FAILS
  # the apply instead of returning while the fleet is down. With auto_healing below, an
  # instance that can't pass /healthz keeps the group unstable, so the apply waits until
  # it recovers or the timeouts below trip.
  wait_for_instances        = true
  wait_for_instances_status = "UPDATED"

  version {
    instance_template = google_compute_instance_template.onlytty.id
  }

  named_port {
    name = "http"
    port = var.app_port
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app.id
    initial_delay_sec = 120
  }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "REPLACE"
    # Keep full capacity during a deploy — surge new instances up first, never drop a
    # healthy one — so sessions migrate as old instances drain (see OnlyTTY.Drain).
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
  }

  # Bound the wait_for_instances wait so a rollout that never goes healthy fails in ~20m
  # instead of hanging.
  timeouts {
    create = "20m"
    update = "20m"
    delete = "15m"
  }

  # These are runtime boot prerequisites, not direct template fields. Without explicit
  # edges, Terraform can create the MIG while NAT, firewall, or IAM grants are still
  # converging; the COS instances then fail to pull the image, read SECRET_KEY_BASE,
  # or pass /healthz, and wait_for_instances can time out on create.
  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.onlytty,
    google_compute_firewall.lb_to_app,
    google_compute_firewall.cluster_dist,
    google_secret_manager_secret_iam_member.vm_reads_secret,
    google_project_iam_member.vm_writes_logs,
    google_project_iam_member.vm_reads_compute,
  ]
}
