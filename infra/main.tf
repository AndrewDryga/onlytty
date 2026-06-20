provider "google" {
  project = var.project_id
  region  = var.region
}

# ── APIs ────────────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── Image registry (CI pushes the onlytty image here) ───────────────────────
resource "google_artifact_registry_repository" "onlytty" {
  location      = var.region
  repository_id = "onlytty"
  format        = "DOCKER"
  description   = "OnlyTTY relay server images"
  depends_on    = [google_project_service.apis]
}

# ── SECRET_KEY_BASE — created here, value added out-of-band (never in state) ─
resource "google_secret_manager_secret" "secret_key_base" {
  secret_id = "onlytty-secret-key-base"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

# ── Least-privilege service account for the VM ──────────────────────────────
resource "google_service_account" "vm" {
  account_id   = "onlytty-vm"
  display_name = "OnlyTTY relay VM"
}

resource "google_secret_manager_secret_iam_member" "vm_reads_secret" {
  secret_id = google_secret_manager_secret.secret_key_base.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_pulls_images" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_writes_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# ── Network: static IP + firewall (Caddy 80/443, SSH 22) ────────────────────
resource "google_compute_address" "onlytty" {
  name       = "onlytty-ip"
  region     = var.region
  depends_on = [google_project_service.apis]
}

resource "google_compute_firewall" "web" {
  name      = "onlytty-allow-web"
  network   = "default"
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["onlytty"]
}

resource "google_compute_firewall" "ssh" {
  name      = "onlytty-allow-ssh"
  network   = "default"
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = var.ssh_source_ranges
  target_tags   = ["onlytty"]
}

# ── The VM: Container-Optimized OS running onlytty + Caddy via cloud-init ────
data "google_compute_image" "cos" {
  project = "cos-cloud"
  family  = "cos-stable"
}

locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml", {
    domain          = var.domain
    acme_email      = var.acme_email
    container_image = var.container_image
    registry_domain = "${var.region}-docker.pkg.dev"
    project_id      = var.project_id
    secret_name     = google_secret_manager_secret.secret_key_base.secret_id
  })
}

resource "google_compute_instance" "onlytty" {
  name         = "onlytty-relay"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["onlytty"]

  boot_disk {
    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.onlytty.address
    }
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

  allow_stopping_for_update = true

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.vm_reads_secret,
  ]
}
