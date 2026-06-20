// Real-browser end-to-end: launch headless Chromium, open the actual viewer link a
// runner prints, and drive it — confirm the fingerprint matches, take control, type
// a command, and see its output rendered. This exercises the browser crypto, the
// WebSocket, xterm, and the control path together. Run via `make e2e`.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import http from "node:http";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const base = process.env.ONLYTTY_SERVER || "http://127.0.0.1:4000";

function healthy() {
  return new Promise((res) => {
    const req = http.get(base + "/healthz", (r) => { r.resume(); res(r.statusCode === 200); });
    req.on("error", () => res(false));
    req.setTimeout(2000, () => { req.destroy(); res(false); });
  });
}

// Start the runner and pull the viewer link + fingerprint from its banner (stderr).
function startRunner(args) {
  return new Promise((resolve, reject) => {
    const p = spawn(join(root, "onlytty"), ["--no-qr", ...args], {
      env: { ...process.env, ONLYTTY_SERVER: base, TERM: "xterm-256color" },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let buf = "";
    const timer = setTimeout(() => { p.kill("SIGKILL"); reject(new Error("no link in banner:\n" + buf)); }, 10000);
    p.stderr.on("data", (d) => {
      buf += d.toString();
      const link = buf.match(/Link\s+(\S+)/);
      const fp = buf.match(/Fingerprint\s+(\S+)/);
      if (link && fp) { clearTimeout(timer); resolve({ proc: p, link: link[1], fingerprint: fp[1] }); }
    });
    p.on("exit", () => { clearTimeout(timer); reject(new Error("runner exited early:\n" + buf)); });
  });
}

test("browser viewer: connect, match fingerprint, take control, type, see output", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link, fingerprint } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });

    await page.goto(link);

    // The fingerprint shown in the browser must equal the one in the terminal: proof
    // both sides derived the same keys from the secret in the fragment.
    await page.waitForSelector("#fp");
    const shown = (await page.textContent("#fp")).replace(/-/g, "");
    assert.equal(shown, fingerprint.replace(/-/g, ""), "fingerprint must match");

    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    await page.click("#control");
    await page.waitForFunction(
      () => document.getElementById("control").classList.contains("live"),
      null, { timeout: 8000 },
    );

    // Type a command whose OUTPUT differs from the echoed command line, so a match
    // proves the command actually ran on the host.
    await page.locator(".xterm-helper-textarea").focus();
    await page.keyboard.type("echo MARK_$((21+21))\r");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("MARK_42"),
      null, { timeout: 8000 },
    );

    await page.keyboard.type("exit\r");
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent.startsWith("ended"),
      null, { timeout: 8000 },
    );
    assert.equal(await page.textContent("#control"), "ended");
    assert.equal(await page.locator("#control").isDisabled(), true);

    assert.deepEqual(errors, [], "no page/console errors");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});
