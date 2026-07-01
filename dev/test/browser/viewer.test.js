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

// The session-fingerprint popup auto-shows on first load (covered by its own test
// below). The other flows aren't about verification, so accept it to clear the
// overlay — this also records the session as verified, so a later reload won't re-prompt.
async function dismissVerify(page) {
  await page.waitForSelector("#fp-match", { timeout: 10000 });
  await page.click("#fp-match");
  await page.waitForFunction(() => document.getElementById("overlay").hidden, null, { timeout: 4000 });
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
    await dismissVerify(page);

    // The fingerprint shown in the browser must equal the one in the terminal: proof
    // both sides derived the same keys from the secret in the fragment.
    await page.waitForFunction(() => document.getElementById("fp").textContent.length > 0, null, { timeout: 10000 });
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
    await dismissVerify(page);
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
    await dismissVerify(page);
    await page.waitForSelector("#menu-btn");

    // Desktop default (precise pointer + hover): the key bar is hidden.
    assert.equal(await page.locator("#keys").isVisible(), false, "bar hidden by default on desktop");

    // The keys toggle lives in the ⋯ menu. Open it, toggle on; the bar shows and the
    // preference persists across a reload.
    await page.click("#menu-btn");
    await page.click("#keys-toggle");
    assert.equal(await page.locator("#keys").isVisible(), true, "bar shown after toggle");
    await page.reload();
    await page.waitForSelector("#menu-btn");
    assert.equal(await page.locator("#keys").isVisible(), true, "bar still shown after reload");

    // Toggle it back off (reopen the menu).
    await page.click("#menu-btn");
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

test("browser viewer: mobile layout — Take control stays on-screen at 360px; ^C key works", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    // A small phone-width viewport with the key bar forced on. The top bar holds only
    // status + Take control + ⋯, so the primary action stays fully on-screen.
    const page = await browser.newPage({ viewport: { width: 360, height: 780 } });
    await page.addInitScript(() => { try { localStorage.setItem("onlytty.keybar", "show"); } catch {} });
    await page.goto(link);
    await dismissVerify(page);
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // The bug we fixed: Take control used to be pushed off the right edge. Its box
    // must be fully within the 360px viewport.
    const box = await page.locator("#control").boundingBox();
    assert.ok(box, "#control present");
    assert.ok(box.x >= 0 && box.x + box.width <= 361,
      `#control must be on-screen at 360px (x=${box.x}, w=${box.width})`);

    // Secondary controls are reachable via the ⋯ menu (not crammed into the bar).
    await page.click("#menu-btn");
    assert.ok(await page.locator("#kbd").isVisible(), "Open keyboard in the ⋯ menu");
    assert.ok(await page.locator("#menu-verify").isVisible(), "Verify in the ⋯ menu");
    assert.ok(await page.locator("#paste").isVisible(), "Paste in the ⋯ menu");
    // Blur the terminal first, then "Open keyboard" must focus it (that's what raises
    // the mobile soft keyboard) and close the menu.
    await page.evaluate(() => document.querySelector(".xterm-helper-textarea")?.blur());
    await page.click("#kbd");
    assert.equal(await page.locator("#menu").isVisible(), false, "⋯ menu closes after a pick");
    await page.waitForFunction(
      () => document.activeElement === document.querySelector(".xterm-helper-textarea"),
      null, { timeout: 4000 },
    );

    // Key bar visible (pref forced) and its keys are ≥44px tap targets.
    assert.equal(await page.locator("#keys").isVisible(), true, "key bar visible on the phone");
    const keyBox = await page.locator('#keys button[data-key="ctrlc"]').boundingBox();
    assert.ok(keyBox && keyBox.height >= 44, `key tap target ≥44px (got ${keyBox && keyBox.height})`);

    // The keys overflow 360px, so the bar must signal there's more to scroll (a hidden
    // scrollbar would otherwise leave ^C undiscoverable): the right edge fades at rest,
    // and scrolling to the end flips the fade to the left edge.
    assert.ok(
      await page.evaluate(() => {
        const k = document.getElementById("keys");
        return k.scrollWidth > k.clientWidth && k.classList.contains("of-r") && !k.classList.contains("of-l");
      }),
      "keys bar fades its right edge when more keys are off-screen",
    );
    await page.evaluate(() => {
      const k = document.getElementById("keys");
      k.scrollLeft = k.scrollWidth;
      k.dispatchEvent(new Event("scroll"));
    });
    assert.ok(
      await page.evaluate(() => {
        const k = document.getElementById("keys");
        return k.classList.contains("of-l") && !k.classList.contains("of-r");
      }),
      "scrolled to the end, the fade moves to the left edge",
    );

    // Take control, then the ^C *button* interrupts a running command.
    await page.click("#control");
    await page.waitForFunction(
      () => document.getElementById("control").classList.contains("live"),
      null, { timeout: 8000 },
    );
    await page.keyboard.type("sleep 30\r");
    await page.click('#keys button[data-key="ctrlc"]');
    await page.keyboard.type("echo MOB_$((3+4))\r");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("MOB_7"),
      null, { timeout: 8000 },
    );
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: a frame whose handler throws doesn't wedge the stream", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);
    // Make xterm's write throw exactly once — simulating a handler error on one frame.
    // The queue must recover so later frames still render (without the .catch it wedges).
    await page.evaluate(() => {
      const proto = window.Terminal.prototype;
      const real = proto.write;
      let armed = true;
      proto.write = function (...a) {
        if (armed) { armed = false; throw new Error("synthetic write failure"); }
        return real.apply(this, a);
      };
    });
    await dismissVerify(page);
    await page.click("#control");
    await page.waitForFunction(
      () => document.getElementById("control").classList.contains("live"),
      null, { timeout: 8000 },
    );

    // The first write throws (caught); a later command's output must still render.
    await page.keyboard.type("echo WEDGE_$((6+7))\r");
    await page.waitForFunction(
      () => document.querySelector(".xterm-rows")?.innerText.includes("WEDGE_13"),
      null, { timeout: 8000 },
    );
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: shows an expiry countdown and Disconnect frees the viewer slot", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  // Sessions have no expiry by default now, so set an explicit --ttl to exercise the countdown.
  const { proc, link } = await startRunner(["--ttl", "1h", "--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);
    await dismissVerify(page);
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // The countdown is visible and shows time remaining.
    await page.waitForFunction(() => {
      const el = document.getElementById("ttl");
      return el && !el.hidden && /expires in/.test(el.textContent);
    }, null, { timeout: 5000 });

    // Disconnect (via the ⋯ menu) → terminal state.
    await page.click("#menu-btn");
    await page.click("#disconnect");
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "disconnected",
      null, { timeout: 5000 },
    );

    // The single-viewer slot is freed: a fresh viewer can now connect (it would get
    // "busy" if the disconnected one still held the lock).
    const page2 = await browser.newPage();
    await page2.goto(link);
    await dismissVerify(page2);
    await page2.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: a large single-line paste is confirmed and only sent on accept", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();

    let dialogMsg = null, accept = false;
    page.on("dialog", async (d) => { dialogMsg = d.message(); accept ? await d.accept() : await d.dismiss(); });

    await page.goto(link);
    await dismissVerify(page);
    await page.click("#control");
    await page.waitForFunction(
      () => document.getElementById("control").classList.contains("live"),
      null, { timeout: 8000 },
    );

    // A big one-liner (no newline) — pasted into xterm's textarea.
    const marker = "PASTEMARK", big = marker + "y".repeat(1200);
    const paste = (text) => page.evaluate((t) => {
      const ta = document.querySelector(".xterm-helper-textarea");
      const dt = new DataTransfer(); dt.setData("text/plain", t);
      ta.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    }, text);
    const onScreen = () => page.evaluate((m) => document.querySelector(".xterm-rows")?.innerText.includes(m), marker);

    // Dismissed → the guard fired (message mentions characters) and nothing was sent.
    accept = false; dialogMsg = null;
    await paste(big);
    await page.waitForFunction(() => true, null, { timeout: 600 }).catch(() => {});
    assert.match(dialogMsg || "", /characters/, "large single-line paste prompts a character-count confirm");
    assert.equal(await onScreen(), false, "a dismissed paste is not sent");

    // Accepted → it reaches the terminal.
    accept = true; dialogMsg = null;
    await paste(big);
    await page.waitForFunction((m) => document.querySelector(".xterm-rows")?.innerText.includes(m),
      marker, { timeout: 5000 });

    // Small input types straight through (no confirm).
    dialogMsg = null;
    await page.keyboard.type("ok");
    assert.equal(dialogMsg, null, "small input is not gated by a confirm");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: a denied control request shows feedback (host view-only)", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link } = await startRunner(["--control", "view-only", "--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);
    await dismissVerify(page);
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // Request control. The host is view-only, so it replies read-only — the viewer
    // must surface that, not silently leave the button unchanged.
    await page.click("#control");
    await page.waitForFunction(
      () => /not granted/.test(document.getElementById("status-text").textContent),
      null, { timeout: 5000 },
    );
    // The button reverts (no longer "Requesting…", and never "You have control").
    const label = await page.locator("#control").textContent();
    assert.equal(label, "Take control", "button reverts after a denied request");
    assert.equal(
      await page.locator("#control.live").count(), 0,
      "denied request must not show the controlling (live) state",
    );
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});

test("browser viewer: an unknown session id shows 'Session not found' quickly", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    // A well-formed link (valid 32-byte key fragment) to a session id that doesn't
    // exist — so we pass the "broken link" check and hit the 404/not-found path.
    const frag = "A".repeat(43); // 43 base64url chars = 32 bytes
    const t0 = Date.now();
    await page.goto(`${base}/s/no-such-session-${t0}#${frag}`);

    // The not-found message must appear well within the old ~7.5s (5 retries); the
    // 3-retry backoff resolves in ~1.5s, so 6s is a comfortable, non-flaky bound.
    await page.waitForFunction(
      () => document.getElementById("overlay-card").textContent.includes("Session not found"),
      null, { timeout: 6000 },
    );
    const body = await page.locator("#overlay-card").textContent();
    assert.match(body, /onlytty/, "copy names onlytty, not relay");
    assert.doesNotMatch(body, /with relay\b/, "no stale 'relay' brand in the not-found copy");
  } finally {
    if (browser) await browser.close();
  }
});

test("browser viewer: an already-connected viewer gives up after a run of missing-session handshakes", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  let browser, proc;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    // Shrink the post-connect missing-session budget so this doesn't take ~2 minutes.
    await page.addInitScript(() => { window.__onlyttyReconnectBudget = 3; });

    // First viewer socket is proxied to the real relay so it truly connects; after that
    // the session "goes missing" (relay node crashed, runner never reclaims) and every
    // reconnect handshake fails — a close with no frame delivered.
    let sessionUp = true;
    const opened = [];
    await page.routeWebSocket(/\/ws\/viewer\//, (ws) => {
      if (sessionUp) { opened.push(ws); ws.connectToServer(); } else ws.close();
    });

    const r = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
    proc = r.proc;
    await page.goto(r.link);
    // Reaching "connected" proves relay frames actually flowed (everConnected), which the
    // locally-derived fingerprint alone would not.
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // The session is gone for good: fail future handshakes, then drop the live socket.
    sessionUp = false;
    proc.kill("SIGKILL");
    for (const w of opened) { try { await w.close(); } catch {} }

    // After the (shortened) budget of consecutive failed handshakes it gives up with a
    // clear terminal state instead of reconnecting forever.
    await page.waitForFunction(
      () => document.getElementById("overlay-card").textContent.includes("Session lost"),
      null, { timeout: 15000 },
    );
    // Reconnect stopped and it settled into the dead terminal state.
    assert.equal(await page.locator("#status-text").textContent(), "session lost");
  } finally {
    if (browser) await browser.close();
    if (proc) proc.kill("SIGKILL");
  }
});

test("browser viewer: an already-connected viewer rides out transient closes and recovers", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  let browser, proc;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    // A generous budget so a short burst of failures stays well under it (no give-up).
    await page.addInitScript(() => { window.__onlyttyReconnectBudget = 20; });

    // Toggle: proxy to the real relay when "up", fail the handshake when "down".
    let sessionUp = true;
    const opened = [];
    await page.routeWebSocket(/\/ws\/viewer\//, (ws) => {
      if (sessionUp) { opened.push(ws); ws.connectToServer(); } else ws.close();
    });

    const r = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
    proc = r.proc;
    await page.goto(r.link);
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );

    // A burst of failing handshakes — well below the budget. The session stays alive (the
    // runner keeps running), modelling a deploy / brief node loss. Drop the live socket so
    // the viewer starts reconnecting, and let a couple of attempts fail.
    sessionUp = false;
    for (const w of opened) { try { await w.close(); } catch {} }
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "reconnecting…",
      null, { timeout: 10000 },
    );

    // Relay back: it reconnects to the still-live session rather than having given up.
    sessionUp = true;
    await page.waitForFunction(
      () => ["connected", "waiting for runner…"].includes(document.getElementById("status-text").textContent),
      null, { timeout: 15000 },
    );
    const card = await page.locator("#overlay-card").textContent();
    assert.doesNotMatch(card, /Session lost/, "must not give up on transient closes below the budget");
  } finally {
    if (browser) await browser.close();
    if (proc) proc.kill("SIGKILL");
  }
});

test("browser viewer: session fingerprint is verified once, then remembered per session", async (t) => {
  let chromium;
  try { ({ chromium } = await import("playwright")); } catch { t.skip("playwright not installed"); return; }
  if (!(await healthy())) { t.skip("relay not reachable at " + base); return; }

  const { proc, link, fingerprint } = await startRunner(["--", "bash", "--norc", "--noprofile", "-i"]);
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(link);

    // First load of a session: the verify popup auto-appears, and its fingerprint must
    // equal the terminal's (proof both ends derived the same keys).
    await page.waitForSelector("#fp-match", { timeout: 10000 });
    assert.equal(await page.locator("#overlay").isVisible(), true, "verify popup shows on first load");
    const shown = (await page.locator("#overlay-card code").textContent()).replace(/-/g, "");
    assert.equal(shown, fingerprint.replace(/-/g, ""), "popup fingerprint matches the terminal");

    // Confirm the match → the popup closes and the fact is saved, scoped to THIS
    // session id (a per-session key, not a global flag).
    await page.click("#fp-match");
    await page.waitForFunction(() => document.getElementById("overlay").hidden, null, { timeout: 4000 });
    const key = await page.evaluate(() => {
      const ks = Object.keys(localStorage).filter((k) => k.startsWith("onlytty.verified."));
      return ks.length === 1 ? ks[0] : null;
    });
    assert.ok(key && key.length > "onlytty.verified.".length, "verification stored under a per-session key");

    // Reload the same session: it's remembered, so the popup does NOT show again — it
    // connects straight through with no overlay.
    await page.reload();
    await page.waitForFunction(
      () => document.getElementById("status-text").textContent === "connected",
      null, { timeout: 10000 },
    );
    assert.equal(await page.locator("#overlay").isVisible(), false, "a verified session skips the popup on reload");
  } finally {
    if (browser) await browser.close();
    proc.kill("SIGKILL");
  }
});
