// relay browser viewer. Reads the session id from the path and the secret from the
// URL fragment (never sent to the server), derives the E2E keys, and runs an xterm
// terminal over an encrypted WebSocket. See PROTOCOL.md.

import { deriveKeys, newCipher, b64urlToBytes } from "./crypto.js";
import { Kind, Control, decodeHello, encodeResize, decodeExit, decodeControl } from "./wire.js";
import { parsePayload } from "./keys.js";

const enc = new TextEncoder();
const $ = (id) => document.getElementById(id);

// --- session from URL --------------------------------------------------------
const id = decodeURIComponent(location.pathname.split("/").filter(Boolean).pop() || "");
let frag = location.hash.slice(1);
let needPass = false;
if (frag.endsWith(".p")) { needPass = true; frag = frag.slice(0, -2); }

// --- terminal ----------------------------------------------------------------
let fontSize = 14;
const term = new Terminal({
  cursorBlink: true,
  fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
  fontSize,
  scrollback: 5000,
  theme: { background: "#0b0e14", foreground: "#c8d3e0" },
});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open($("terminal"));

// --- state -------------------------------------------------------------------
let openC, sealC; // r2v (open), v2r (seal)
let ws = null;
let outSeq = 0; // viewer→runner sequence (starts at HELLO baseline)
let lastSeq = 0; // runner→viewer replay floor (monotonic, runner is one process)
let hasControl = false;
let ptyCols = 80, ptyRows = 24;
let ended = false, noReconnect = false, exitSeen = false;
let backoff = 500;
let ctrlArmed = false;
let everConnected = false, failCount = 0;
let everDecoded = false, mismatchTimer = null; // wrong-keys (bad passphrase) detection

// --- UI helpers --------------------------------------------------------------
function setStatus(text, cls) {
  $("status-text").textContent = text;
  $("dot").className = cls || "";
}
function fatal(html) {
  const o = $("overlay");
  $("overlay-card").innerHTML = html;
  // Wire any [data-dismiss] button by hand — a strict CSP (script-src 'self')
  // forbids the inline onclick= we'd otherwise inject via innerHTML.
  o.querySelectorAll("[data-dismiss]").forEach((b) => b.addEventListener("click", () => { o.hidden = true; }));
  o.hidden = false;
}
function updateControlUI() {
  const b = $("control");
  if (ended) { b.textContent = "ended"; b.disabled = true; b.className = ""; return; }
  b.textContent = hasControl ? "You have control" : "Take control";
  b.className = hasControl ? "live" : "";
}

// Touch key bar is for phones (coarse pointer, no hover) — not touchscreen
// laptops/2-in-1s, which have a precise pointer and a real keyboard. The phone
// default can be overridden per-device (e.g. an iPad + keyboard opting out, or a
// desktop opting in) by a persisted toggle. Detection is reactive: it re-evaluates
// when the pointer/hover capability changes (docking a keyboard, rotating, etc.).
const KEYBAR_PREF = "onlytty.keybar"; // "show" | "hide" | absent (= auto)
const touchMedia = matchMedia("(pointer: coarse) and (hover: none)");
function keybarVisible() {
  let pref = null;
  try { pref = localStorage.getItem(KEYBAR_PREF); } catch {}
  if (pref === "show") return true;
  if (pref === "hide") return false;
  return touchMedia.matches; // auto: phones get it, desktops don't
}
function applyKeybar() {
  document.body.classList.toggle("touch", keybarVisible());
}
touchMedia.addEventListener?.("change", applyKeybar);
applyKeybar();

// --- crypto setup & connect --------------------------------------------------
async function start(passphrase) {
  let secret;
  try {
    secret = b64urlToBytes(frag);
  } catch {
    secret = new Uint8Array(0);
  }
  if (!id || secret.length !== 32) {
    fatal("<h1>Broken link</h1><p>This link is missing its key (the part after <code>#</code>). Open the original link from the terminal — the key never reaches the server, so it can't be recovered here.</p>");
    return;
  }
  const keys = await deriveKeys(secret, id, passphrase || "");
  openC = await newCipher(keys.r2v, enc.encode(id));
  sealC = await newCipher(keys.v2r, enc.encode(id));
  $("fp").textContent = groupFingerprint(keys.fingerprint);
  $("fp").title = "Confirm this matches the fingerprint shown in the terminal";
  connect();
}

function connect() {
  if (ended || noReconnect) return;
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws/viewer/${encodeURIComponent(id)}`);
  ws.binaryType = "arraybuffer";

  let queue = Promise.resolve(); // serialize async frame handling to preserve order
  ws.onmessage = (ev) => { queue = queue.then(() => onMessage(ev)); };
  ws.onopen = () => { everConnected = true; failCount = 0; setStatus("waiting for runner…", "warn"); backoff = 500; requestWakeLock(); };
  ws.onclose = () => {
    if (ended || noReconnect) return;
    // Browsers can't expose the handshake status, so a session that never
    // connects (404 from an unknown/expired id) looks like repeated failures.
    if (!everConnected && ++failCount >= 5) {
      noReconnect = true;
      fatal("<h1>Session not found</h1><p>This session is unknown or has expired. Start a new one with <code>relay</code> and open the fresh link.</p>");
      return;
    }
    setStatus("reconnecting…", "warn");
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 8000);
  };
  ws.onerror = () => { try { ws.close(); } catch {} };
}

// --- wrong-keys recovery (bad passphrase / fingerprint mismatch) --------------
function showKeyMismatch() {
  const fp = $("fp").textContent;
  let html =
    "<h1>Can't decrypt this session</h1>" +
    "<p>Frames are arriving, but the keys derived in this browser don't match the terminal — so every frame fails to decrypt. Compare the fingerprint here with the one in your terminal:</p>" +
    "<p><code>" + fp + "</code></p>";
  if (needPass) {
    html +=
      "<p>This is almost always a wrong passphrase. Re-enter it to try again — no reload needed:</p>" +
      '<input id="pass-retry" type="password" autocomplete="off" placeholder="Passphrase" autofocus>' +
      '<button id="pass-retry-go">Retry</button>';
  } else {
    html +=
      "<p>The secret in this link doesn't match the session. Open the original link from the terminal — the secret never reaches the server, so it can't be recovered here.</p>";
  }
  $("overlay-card").innerHTML = html;
  $("overlay").hidden = false;
  if (needPass) {
    const retry = () => { const v = $("pass-retry").value; if (v) { $("overlay").hidden = true; retryWithPassphrase(v); } };
    $("pass-retry-go").onclick = retry;
    $("pass-retry").addEventListener("keydown", (e) => { if (e.key === "Enter") retry(); });
  }
}

async function retryWithPassphrase(passphrase) {
  // Re-derive keys with the new passphrase and reconnect, so the runner re-sends its
  // HELLO and we decrypt cleanly. Detach the old socket's onclose so it doesn't race
  // the fresh connect.
  if (ws) { try { ws.onclose = null; ws.close(); } catch {} ws = null; }
  if (mismatchTimer) { clearTimeout(mismatchTimer); mismatchTimer = null; }
  everDecoded = false; lastSeq = 0; outSeq = 0; hasControl = false; updateControlUI();
  setStatus("reconnecting…", "warn");
  await start(passphrase);
}

async function onMessage(ev) {
  if (typeof ev.data === "string") { onControlText(ev.data); return; }
  const frame = new Uint8Array(ev.data);
  let msg;
  try {
    msg = await openC.open(frame);
  } catch {
    // Frames are arriving but none authenticate → the keys are wrong (wrong passphrase,
    // or a link secret that doesn't match this session). Don't hang silently: after a
    // short grace with no successful decrypt, surface a recoverable overlay.
    if (!everDecoded && !mismatchTimer) {
      mismatchTimer = setTimeout(() => { if (!everDecoded) showKeyMismatch(); }, 1200);
    }
    return;
  }
  everDecoded = true;
  if (mismatchTimer) { clearTimeout(mismatchTimer); mismatchTimer = null; }
  if (msg.seq <= lastSeq) return; // replay / stale
  lastSeq = msg.seq;
  dispatch(msg);
}

function dispatch({ kind, payload }) {
  switch (kind) {
    case Kind.Hello: {
      const h = decodeHello(payload);
      outSeq = Math.max(outSeq, h.baseline - 1); // next send() uses >= baseline
      ptyCols = h.cols; ptyRows = h.rows;
      if (!ended) setStatus("connected", "ok");
      applySize();
      break;
    }
    case Kind.Output:
      term.write(payload);
      break;
    case Kind.Control:
      hasControl = decodeControl(payload) === Control.Granted;
      if (hasControl) { applySize(); term.focus(); } // we now drive geometry; keep the keyboard up
      updateControlUI();
      break;
    case Kind.Exit: {
      const code = decodeExit(payload);
      term.write(`\r\n\x1b[2m── command exited (${code}) ──\x1b[0m\r\n`);
      ended = true; noReconnect = true; exitSeen = true; hasControl = false;
      setStatus(`ended (exit ${code})`, "warn");
      updateControlUI();
      break;
    }
  }
}

function onControlText(data) {
  let m;
  try { m = JSON.parse(data); } catch { return; }
  switch (m.t) {
    case "peer_join": if (!ended) setStatus("connected", "ok"); break;
    case "peer_left": if (!ended) setStatus("runner disconnected — waiting…", "warn"); break;
    case "busy":
      noReconnect = true;
      fatal("<h1>Session busy</h1><p>Another viewer is already connected. This session allows one viewer at a time.</p>");
      break;
    case "bye":
      ended = true; noReconnect = true; hasControl = false;
      if (!exitSeen) {
        const reason = m.reason || "closed";
        if (reason === "ended") {
          term.write("\r\n\x1b[2m── session ended ──\x1b[0m\r\n");
          setStatus("ended", "warn");
        } else {
          setStatus(`session closed (${reason})`, "warn");
        }
      }
      updateControlUI();
      break;
  }
}

// --- sizing: host-driven when watching, viewer-driven when in control --------
function applySize() {
  if (hasControl) {
    fit.fit();
    sendResize(term.cols, term.rows);
  } else {
    try { term.resize(ptyCols, ptyRows); } catch {}
  }
}

async function sendResize(cols, rows) {
  if (!hasControl) return;
  await send(Kind.Resize, encodeResize(cols, rows));
}

// --- input -------------------------------------------------------------------
async function send(kind, payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  outSeq++;
  try { ws.send(await sealC.seal(outSeq, kind, payload)); } catch {}
}

async function sendInput(data) {
  if (!hasControl) return;
  // Guard accidental multi-line pastes.
  if (data.length > 2 && /[\n\r]/.test(data.slice(0, -1))) {
    const lines = data.split(/\r?\n/).length;
    if (!confirm(`Send ${lines} lines to the terminal?`)) return;
  }
  await send(Kind.Input, enc.encode(data));
}

term.onData((d) => {
  if (ctrlArmed && d.length === 1) {
    const c = d.toUpperCase().charCodeAt(0);
    if (c >= 64 && c < 128) d = String.fromCharCode(c & 0x1f);
    ctrlArmed = false; $("ctrl").classList.remove("on");
  }
  sendInput(d);
});

// --- controls ----------------------------------------------------------------
$("control").onclick = () => {
  if (ended) return;
  if (hasControl) { send(Kind.CtrlRel, new Uint8Array(0)); hasControl = false; updateControlUI(); applySize(); }
  // Focus now, inside the click (a user gesture), so the mobile soft keyboard opens
  // without a second tap; the grant handler refocuses to keep it up.
  else { send(Kind.CtrlReq, new Uint8Array(0)); term.focus(); }
};

// Tap the (truncated) fingerprint chip to see the full value and compare it with the terminal.
$("fp").addEventListener("click", () => {
  const fp = $("fp").textContent;
  if (fp) fatal(`<h1>Session fingerprint</h1><p>Compare this with the fingerprint shown in your terminal — if they match, both ends derived the same keys from the same secret.</p><p><code>${fp}</code></p><button data-dismiss>OK</button>`);
});

const KEYS = {
  esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", left: "\x1b[D", right: "\x1b[C",
  bksp: "\x7f", enter: "\r", ctrlc: "\x03", ctrld: "\x04",
};
// Sticky Ctrl composes with the touch keys too, not just the soft keyboard: when
// armed, the arrows become the standard Ctrl word-navigation sequences; the other
// keys have no meaningful Ctrl form, so Ctrl just disarms. Either way a touch key
// consumes the armed Ctrl, so it never silently leaks onto the next typed char.
const CTRL_KEYS = { up: "\x1b[1;5A", down: "\x1b[1;5B", left: "\x1b[1;5D", right: "\x1b[1;5C" };
function touchKey(name) {
  term.focus();
  const seq = (ctrlArmed && CTRL_KEYS[name]) || KEYS[name];
  if (ctrlArmed) { ctrlArmed = false; $("ctrl").classList.remove("on"); }
  sendInput(seq);
}
for (const b of document.querySelectorAll("#keys button[data-key]")) {
  b.onclick = () => touchKey(b.dataset.key);
}
$("ctrl").onclick = () => { ctrlArmed = !ctrlArmed; $("ctrl").classList.toggle("on", ctrlArmed); term.focus(); };

// --- pinnable shortcuts (device-local, persisted) ----------------------------
// Users pin their own labeled keys (Ctrl-R, a `|` pipe, a short snippet) without
// bloating the default bar. Stored device-wide in localStorage — never per-session,
// and never anything from the URL (the secret stays out of storage). Sending goes
// through sendInput, so it stays gated by control + the multi-line paste confirm:
// a pinned key grants no capability a controlling viewer doesn't already have.
const SHORTCUTS_KEY = "onlytty.shortcuts";
let shortcuts = loadShortcuts();

function loadShortcuts() {
  try {
    const v = JSON.parse(localStorage.getItem(SHORTCUTS_KEY));
    if (!Array.isArray(v)) return [];
    return v
      .filter((s) => s && typeof s.label === "string" && typeof s.payload === "string")
      .map((s) => ({ label: s.label.slice(0, 16), payload: s.payload }));
  } catch { return []; }
}
function persistShortcuts() {
  try { localStorage.setItem(SHORTCUTS_KEY, JSON.stringify(shortcuts)); } catch {}
  renderShortcuts();
}
function renderShortcuts() {
  const bar = $("keys");
  for (const b of bar.querySelectorAll("button.user-key")) b.remove();
  const edit = $("keys-edit");
  for (const sc of shortcuts) {
    const b = document.createElement("button");
    b.className = "user-key";
    b.textContent = sc.label;
    b.title = sc.payload;
    b.onclick = () => { term.focus(); sendInput(parsePayload(sc.payload)); };
    bar.insertBefore(b, edit);
  }
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function moveShortcut(i, dir) {
  const j = i + dir;
  if (j < 0 || j >= shortcuts.length) return;
  [shortcuts[i], shortcuts[j]] = [shortcuts[j], shortcuts[i]];
  persistShortcuts();
}
function openEditor() {
  const rows = shortcuts.map((sc, i) =>
    `<div class="sc-row" data-i="${i}">` +
      `<span class="sc-label">${escapeHtml(sc.label)}</span>` +
      `<code class="sc-payload">${escapeHtml(sc.payload)}</code>` +
      `<span class="sc-act">` +
        `<button data-act="up" title="Move up" aria-label="Move up">↑</button>` +
        `<button data-act="down" title="Move down" aria-label="Move down">↓</button>` +
        `<button data-act="rm" title="Remove" aria-label="Remove">✕</button>` +
      `</span></div>`).join("");
  $("overlay-card").innerHTML =
    "<h1>Shortcuts</h1>" +
    "<p>Pin keys to the touch bar. Payload supports <code>^X</code> for Ctrl-X " +
      "(e.g. <code>^L</code> clears, <code>^M</code> is Enter) and literal text.</p>" +
    `<div id="sc-list">${rows || '<p class="sc-empty">No custom shortcuts yet.</p>'}</div>` +
    '<div id="sc-add">' +
      '<input id="sc-label" placeholder="Label" maxlength="16" autocomplete="off">' +
      '<input id="sc-payload" placeholder="Payload, e.g. ^L" autocomplete="off">' +
      '<button id="sc-add-btn">Add</button>' +
    "</div>" +
    '<button id="sc-done">Done</button>';
  $("overlay").hidden = false;

  for (const row of $("overlay-card").querySelectorAll(".sc-row")) {
    const i = +row.dataset.i;
    row.querySelector('[data-act="up"]').onclick = () => { moveShortcut(i, -1); openEditor(); };
    row.querySelector('[data-act="down"]').onclick = () => { moveShortcut(i, 1); openEditor(); };
    row.querySelector('[data-act="rm"]').onclick = () => { shortcuts.splice(i, 1); persistShortcuts(); openEditor(); };
  }
  const add = () => {
    const label = $("sc-label").value.trim();
    const payload = $("sc-payload").value;
    if (!label || !payload) return;
    shortcuts.push({ label: label.slice(0, 16), payload });
    persistShortcuts();
    openEditor();
  };
  $("sc-add-btn").onclick = add;
  $("sc-payload").addEventListener("keydown", (e) => { if (e.key === "Enter") add(); });
  $("sc-done").onclick = () => { $("overlay").hidden = true; term.focus(); };
}
$("keys-edit").onclick = openEditor;
renderShortcuts();

$("paste").onclick = async () => {
  try {
    const text = await navigator.clipboard.readText();
    if (text) await sendInput(text);
    term.focus();
  } catch {
    fatal("<h1>Paste blocked</h1><p>The browser denied clipboard access. Long-press the terminal to paste instead.</p><button data-dismiss>OK</button>");
  }
};

// Persisted show/hide toggle for the key bar (device-level; never stores anything
// from the URL). Flips relative to what's currently shown, so one tap always works.
$("keys-toggle").onclick = () => {
  const next = document.body.classList.contains("touch") ? "hide" : "show";
  try { localStorage.setItem(KEYBAR_PREF, next); } catch {}
  applyKeybar();
  term.focus();
};

$("font-inc").onclick = () => setFont(fontSize + 1);
$("font-dec").onclick = () => setFont(fontSize - 1);
function setFont(n) {
  fontSize = Math.max(8, Math.min(28, n));
  term.options.fontSize = fontSize;
  applySize();
}

let resizeTimer;
addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(applySize, 150);
});

// --- wake lock (best effort) -------------------------------------------------
let wakeLock = null;
async function requestWakeLock() {
  try { if ("wakeLock" in navigator) wakeLock = await navigator.wakeLock.request("screen"); } catch {}
}
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !wakeLock) requestWakeLock();
});

// --- helpers -----------------------------------------------------------------
function groupFingerprint(fp) {
  return fp.match(/.{1,4}/g).join("-");
}

// --- boot --------------------------------------------------------------------
function boot() {
  // Web Crypto only exists in a secure context (HTTPS or localhost). Fail clearly
  // rather than throwing an opaque error deep in key derivation.
  if (!window.isSecureContext || !window.crypto?.subtle) {
    fatal("<h1>HTTPS required</h1><p>This page must be served over HTTPS (or localhost). End-to-end encryption uses the Web Crypto API, which browsers only expose in a secure context.</p>");
    return;
  }
  updateControlUI();
  startBoot();
}

function startBoot() {
if (needPass) {
  $("overlay-card").innerHTML =
    "<h1>Passphrase required</h1><p>This session is protected by a passphrase shared with you out-of-band. The link alone cannot decrypt it.</p>" +
    '<input id="pass" type="password" autocomplete="off" placeholder="Passphrase" autofocus>' +
    '<button id="pass-go">Connect</button>';
  $("overlay").hidden = false;
  const go = () => { const v = $("pass").value; if (v) { $("overlay").hidden = true; start(v); } };
  $("pass-go").onclick = go;
  $("pass").addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
} else {
  start("");
}
}

boot();
