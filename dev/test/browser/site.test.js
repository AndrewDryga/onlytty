// Marketing-site browser checks (served by the same relay at /). Run via `make e2e`.
// Confirms the inline JSON-LD structured data renders without tripping the CSP — it's
// a non-executed data block, so script-src 'self' does not apply to it — and locks
// that with a regression assertion.

import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";

const base = process.env.ONLYTTY_SERVER || "http://127.0.0.1:4000";

function healthy() {
  return new Promise((res) => {
    const req = http.get(base + "/healthz", (r) => { r.resume(); res(r.statusCode === 200); });
    req.on("error", () => res(false));
    req.setTimeout(2000, () => { req.destroy(); res(false); });
  });
}

test("home page: inline JSON-LD renders with no CSP violation", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    // Capture CSP violations two ways: the DOM event and console errors.
    await page.addInitScript(() => {
      window.__csp = [];
      document.addEventListener("securitypolicyviolation", (e) =>
        window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
    });
    const consoleCsp = [];
    page.on("console", (m) => {
      if (m.type() === "error" && /content security policy/i.test(m.text())) consoleCsp.push(m.text());
    });

    await page.goto(base + "/", { waitUntil: "networkidle" });

    const domCsp = await page.evaluate(() => window.__csp || []);
    assert.deepEqual(domCsp, [], "no securitypolicyviolation events on /");
    assert.deepEqual(consoleCsp, [], "no CSP console errors on /");

    // The structured-data block is actually in the DOM (and non-empty JSON).
    const blocks = await page.locator('script[type="application/ld+json"]').count();
    assert.ok(blocks >= 1, "at least one application/ld+json block present");
    const first = await page.locator('script[type="application/ld+json"]').first().textContent();
    assert.ok(JSON.parse(first)["@context"], "JSON-LD parses and has @context");
  } finally {
    if (browser) await browser.close();
  }
});
