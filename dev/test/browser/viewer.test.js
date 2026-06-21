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

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const base = process.env.ONLYTTY_SERVER || "http://127.0.0.1:4000";

function healthy() {
  return new Promise((res) => {
    const req = http.get(base + "/healthz", (r) => { r.resume(); res(r.statusCode === 200); });
    req.on("error", () => res(false));
    req.setTimeout(2000, () => { req.destroy(); res(false); });
  });
}

// Start the runner and pull the viewer link + fingerprint from its banner (stderr).
function startRunner(args, { wantPass = false } = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(join(root, "onlytty"), ["--no-qr", ...args], {
      env: { ...process.env, ONLYTTY_SERVER: base, TERM: "xterm-256color" },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let buf = "";
    const timer = setTimeout(() => { p.kill("SIGKILL"); reject(new Error("no link in banner:\n" + buf)); }, 10000);
    p.stderr.on("data", (d) => {
      buf += d.toString();
      const clean = buf.replace(/\x1b\[[0-9;]*m/g, ""); // strip ANSI (the passphrase is bold)
      const link = clean.match(/Link\s+(\S+)/);
      const fp = clean.match(/Fingerprint\s+(\S+)/);
      // The generated passphrase is the lone token on the line after its banner header.
      const pass = clean.match(/DIFFERENT channel than the link:\s*\n\s*(\S+)/);
      if (link && fp && (!wantPass || pass)) {
        clearTimeout(timer);
        resolve({ proc: p, link: link[1], fingerprint: fp[1], passphrase: pass ? pass[1] : null });
      }
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

    // Taking control auto-focuses the terminal (so the mobile keyboard opens without a
    // second tap) — assert that, then type without focusing by hand.
    await page.waitForFunction(
      () => document.activeElement === document.querySelector(".xterm-helper-textarea"),
      null, { timeout: 8000 },
    );

    // Type a command whose OUTPUT differs from the echoed command line, so a match
    // proves the command actually ran on the host.
    await page.keyboard.type("echo MARK_$((21+21))\r");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("MARK_42"),
      null, { timeout: 8000 },
    );

    // Sticky Ctrl: reveal the touch key-bar, arm Ctrl, then a normal keystroke is sent
    // as a control char — ^C interrupts a running command and the shell stays usable.
    await page.evaluate(() => document.body.classList.add("touch"));
    await page.keyboard.type("sleep 30\r");
    await page.click("#ctrl");
    await page.keyboard.type("c");
    await page.keyboard.type("echo BACK_$((1+1))\r");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("BACK_2"),
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

test("browser viewer: pin a custom shortcut — it sends, persists across reload, and removes", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));

    await page.goto(link);
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // Take control so the pinned shortcut is allowed to send (it goes through the
    // same control gate as any typed input).
    await page.click("#control");
    await page.waitForFunction(
      () => document.getElementById("control").classList.contains("live"),
      null, { timeout: 8000 },
    );

    // Open the editor (the key bar only shows on touch) and pin a shortcut whose
    // payload uses `^M` (Enter) so tapping it runs a command on the host.
    await page.evaluate(() => document.body.classList.add("touch"));
    await page.click("#keys-edit");
    await page.fill("#sc-label", "ok");
    await page.fill("#sc-payload", "echo SC_OK^M");
    await page.click("#sc-add-btn");
    await page.click("#sc-done");

    await page.waitForSelector("#keys button.user-key");
    assert.equal(await page.textContent("#keys button.user-key"), "ok");

    // Tapping it sends `echo SC_OK\r` (^M → 0x0d) → the host runs it and prints SC_OK.
    await page.click("#keys button.user-key");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("SC_OK"),
      null, { timeout: 8000 },
    );

    // It survives a reload (persisted in localStorage, device-level). Re-assert the
    // touch class — a reload resets the DOM and the desktop test viewport isn't a
    // phone, so the bar would otherwise stay hidden.
    await page.reload();
    await page.evaluate(() => document.body.classList.add("touch"));
    await page.waitForSelector("#keys button.user-key");
    assert.equal(await page.textContent("#keys button.user-key"), "ok");

    // The default keys are untouched.
    assert.ok(await page.locator('#keys button[data-key="ctrlc"]').count() >= 1, "default ^C remains");

    // Remove it via the editor and the user button is gone.
    await page.evaluate(() => document.body.classList.add("touch"));
    await page.click("#keys-edit");
    await page.click('.sc-row [data-act="rm"]');
    await page.click("#sc-done");
    assert.equal(await page.locator("#keys button.user-key").count(), 0);

    assert.deepEqual(errors, [], "no page errors");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: key-bar show/hide toggle persists across reload", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);
    await page.waitForSelector("#keys-toggle");

    // Desktop default (precise pointer + hover): the key bar is hidden.
    assert.equal(await page.locator("#keys").isVisible(), false, "bar hidden by default on desktop");

    // Toggle it on; it shows and the preference persists across a reload.
    await page.click("#keys-toggle");
    assert.equal(await page.locator("#keys").isVisible(), true, "bar shown after toggle");
    await page.reload();
    await page.waitForSelector("#keys-toggle");
    assert.equal(await page.locator("#keys").isVisible(), true, "bar still shown after reload");

    // Toggle it back off.
    await page.click("#keys-toggle");
    assert.equal(await page.locator("#keys").isVisible(), false, "bar hidden after second toggle");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: wrong passphrase shows a recoverable overlay; the right one connects", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link, fingerprint, passphrase } = await startRunner(
    ["--passphrase-generate", "--", "bash", "--norc", "--noprofile", "-i"],
    { wantPass: true },
  );
  assert.ok(passphrase, "runner must print a generated passphrase");
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);

    // A wrong passphrase derives the wrong keys → frames arrive but never decrypt.
    await page.waitForSelector("#pass");
    await page.fill("#pass", "wrong-passphrase");
    await page.click("#pass-go");

    // Instead of hanging at "waiting for runner…", the recoverable overlay appears…
    await page.waitForFunction(
      () => !document.getElementById("overlay").hidden &&
            document.getElementById("overlay-card").textContent.includes("Can't decrypt"),
      null, { timeout: 8000 },
    );
    // …and it surfaces a fingerprint that DIFFERS from the terminal's (the tell).
    const wrong = (await page.textContent("#fp")).replace(/-/g, "");
    assert.notEqual(wrong, fingerprint.replace(/-/g, ""), "wrong passphrase → different fingerprint");

    // Retry with the real passphrase — no reload — and it connects, fingerprint matching.
    await page.fill("#pass-retry", passphrase);
    await page.click("#pass-retry-go");
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );
    const right = (await page.textContent("#fp")).replace(/-/g, "");
    assert.equal(right, fingerprint.replace(/-/g, ""), "right passphrase → fingerprint matches");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});
