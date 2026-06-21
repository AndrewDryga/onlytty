# ── Pre-existing email + domain-verification records ─────────────────────────
# Delegating the registrar's nameservers to this Cloud DNS zone makes it authoritative,
# so ONLY the records defined here resolve. These replicate the email (MX / SPF / DMARC)
# and Google site-verification records the previous DNS host served — without them, mail
# and domain verification break at the nameserver cutover.
#
# IMPORTANT: this is only what the old zone had at migration time. Replicate EVERY record
# from the old host before switching nameservers — in particular a Google Workspace DKIM
# TXT at `google._domainkey` (add it here if present) and any `www` / other subdomains.

# Google Workspace inbound mail.
resource "google_dns_record_set" "mx" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "MX"
  ttl          = 3600
  rrdatas = [
    "1 aspmx.l.google.com.",
    "5 alt1.aspmx.l.google.com.",
    "5 alt2.aspmx.l.google.com.",
    "10 alt3.aspmx.l.google.com.",
    "10 alt4.aspmx.l.google.com.",
  ]
}

# Apex TXT: SPF + Google site verification (multiple values in one TXT record set).
resource "google_dns_record_set" "txt_apex" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "TXT"
  ttl          = 3600
  rrdatas = [
    "\"v=spf1 include:dc-aa8e722993._spfm.${var.domain} ~all\"",
    "\"google-site-verification=BfuUT5_XLOMfuosIR92JaYKZ4QAo3xrdtYbu7i1ZSaI\"",
  ]
}

# The SPF-flattening include the apex SPF points at (kept verbatim from the old host;
# could later be simplified to a direct `v=spf1 include:_spf.google.com ~all` at the apex).
resource "google_dns_record_set" "txt_spf_include" {
  name         = "dc-aa8e722993._spfm.${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=spf1 include:_spf.google.com ~all\""]
}

# DMARC policy.
resource "google_dns_record_set" "dmarc" {
  name         = "_dmarc.${var.domain}."
  managed_zone = google_dns_managed_zone.onlytty.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;\""]
}
