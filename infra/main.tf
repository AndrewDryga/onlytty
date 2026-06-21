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

# ── Health check (drives both the LB backend and MIG auto-healing) ───────────
resource "google_compute_health_check" "default" {
  name                = "onlytty-healthz"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/healthz"
    port         = var.app_port
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

# Cloud Router + Cloud NAT give the instances egress (GHCR image pull, Secret
# Manager, Cloud Logging) without any external IP. Auto-allocated NAT addresses
# cover all subnets in the region.
resource "google_compute_router" "default" {
  name    = "onlytty-router"
  region  = var.region
  network = "default"

  depends_on = [google_project_service.apis]
}

resource "google_compute_router_nat" "default" {
  name                               = "onlytty-nat"
  router                             = google_compute_router.default.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_instance_template" "default" {
  name_prefix  = "onlytty-"
  machine_type = var.machine_type
  tags         = ["onlytty"]

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
    network = "default"
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
# CRITICAL — size stays 1. OnlyTTY sessions live IN MEMORY on the single
# instance that created them (Onlytty.SessionStore is not shared). With >1
# instance a runner and a viewer for the same session can land on different
# instances and never connect, and LB session affinity can't fix it (they are
# different clients). Do NOT raise target_size until a follow-up adds BEAM
# clustering + a distributed session registry (libcluster + pg/Horde).
resource "google_compute_region_instance_group_manager" "default" {
  name               = "onlytty-mig"
  base_instance_name = "onlytty"
  region             = var.region
  target_size        = var.instance_count

  version {
    instance_template = google_compute_instance_template.default.id
  }

  named_port {
    name = "http"
    port = var.app_port
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.default.id
    initial_delay_sec = 120
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
  }

  depends_on = [google_project_service.apis]
}
