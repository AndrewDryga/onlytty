# ── Global anycast IPs (IPv4 + IPv6) fronting the HTTPS load balancer ────────
resource "google_compute_global_address" "ipv4" {
  name       = "onlytty-ipv4"
  ip_version = "IPV4"
  depends_on = [google_project_service.apis]
}

resource "google_compute_global_address" "ipv6" {
  name       = "onlytty-ipv6"
  ip_version = "IPV6"
  depends_on = [google_project_service.apis]
}

# ── Cloud DNS: the managed zone for the domain ───────────────────────────────
# Delegate the registrar's nameservers to this zone (see the `nameservers`
# output). The A/AAAA records and the cert DNS-authorization CNAME live here.
resource "google_dns_managed_zone" "onlytty" {
  name        = "onlytty"
  dns_name    = var.dns_name
  description = "OnlyTTY public zone"
  depends_on  = [google_project_service.apis]
}

resource "google_dns_record_set" "a" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ipv4.address]
}

resource "google_dns_record_set" "aaaa" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ipv6.address]
}

# ── Google-managed TLS via Certificate Manager + DNS authorization ───────────
resource "google_certificate_manager_dns_authorization" "onlytty" {
  name        = "onlytty-dnsauth"
  domain      = var.domain
  description = "DNS authorization for the OnlyTTY managed cert"
  depends_on  = [google_project_service.apis]
}

# The CNAME that proves domain control, published into our own managed zone.
resource "google_dns_record_set" "cert_auth" {
  name         = google_certificate_manager_dns_authorization.onlytty.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = google_certificate_manager_dns_authorization.onlytty.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.onlytty.dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "onlytty" {
  name = "onlytty-cert"
  managed {
    domains            = [var.domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.onlytty.id]
  }
  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map" "onlytty" {
  name       = "onlytty-certmap"
  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map_entry" "onlytty" {
  name         = "onlytty-certmap-entry"
  map          = google_certificate_manager_certificate_map.onlytty.name
  certificates = [google_certificate_manager_certificate.onlytty.id]
  hostname     = var.domain
}

# ── Backend: the MIG behind an HTTP backend service + health check ───────────
resource "google_compute_backend_service" "app" {
  name                            = "onlytty-backend"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = var.backend_timeout_sec
  connection_draining_timeout_sec = 120
  # Different clients (runner vs viewer) must reach the same instance; with a
  # single instance affinity is moot, and it can't help cross-client anyway.
  session_affinity = "NONE"
  health_checks    = [google_compute_health_check.app.id]

  backend {
    group           = google_compute_region_instance_group_manager.onlytty.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# ── TLS policy: modern ciphers, TLS 1.2+ ─────────────────────────────────────
resource "google_compute_ssl_policy" "restricted" {
  name            = "onlytty-ssl"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
}

# ── HTTPS front end ──────────────────────────────────────────────────────────
resource "google_compute_url_map" "https" {
  name            = "onlytty-https"
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_target_https_proxy" "https" {
  name            = "onlytty-https-proxy"
  url_map         = google_compute_url_map.https.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.onlytty.id}"
  ssl_policy      = google_compute_ssl_policy.restricted.id
}

resource "google_compute_global_forwarding_rule" "https_v4" {
  name                  = "onlytty-https-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

resource "google_compute_global_forwarding_rule" "https_v6" {
  name                  = "onlytty-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

# ── HTTP → HTTPS redirect front end ──────────────────────────────────────────
resource "google_compute_url_map" "redirect" {
  name = "onlytty-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "onlytty-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v4" {
  name                  = "onlytty-http-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v6" {
  name                  = "onlytty-http-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

# ── Firewall: only the Google LB + health-check ranges reach the app port ────
resource "google_compute_firewall" "lb_to_app" {
  name      = "onlytty-allow-lb"
  network   = google_compute_network.onlytty.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = [tostring(var.app_port)]
  }
  # Google global LB proxies + health checkers.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["onlytty"]
}

# SSH only via Identity-Aware Proxy (no 0.0.0.0/0). Reach a box with:
#   gcloud compute ssh <instance> --tunnel-through-iap
resource "google_compute_firewall" "iap_ssh" {
  name      = "onlytty-allow-iap-ssh"
  network   = google_compute_network.onlytty.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["onlytty"]
}

# Erlang distribution between relay instances: epmd (4369) + the pinned distribution
# port range (rel/vm.args.eex) so the nodes form one BEAM cluster and share the :global
# session registry. Scoped to the relay's own instances (tag → tag); nothing else can
# reach these ports.
resource "google_compute_firewall" "cluster_dist" {
  name      = "onlytty-allow-cluster"
  network   = google_compute_network.onlytty.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["4369", "9100-9105"]
  }
  source_tags = ["onlytty"]
  target_tags = ["onlytty"]
}
