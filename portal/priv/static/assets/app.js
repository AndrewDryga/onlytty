// relay browser viewer. Reads the session id from the path and the secret from the
// URL fragment (never sent to the server), derives the E2E keys, and runs an xterm
// terminal over an encrypted WebSocket. See PROTOCOL.md.

import { deriveKeys, newCipher, b64urlToBytes } from "./crypto.js";
import { Kind, Control, decodeHello, encodeResize, decodeExit, decodeControl } from "./wire.js";

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
  allowProposedApi: true,
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
// laptops/2-in-1s, which have a precise pointer available and a real keyboard.
if (matchMedia("(pointer: coarse) and (hover: none)").matches) document.body.classList.add("touch");

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

async function onMessage(ev) {
  if (typeof ev.data === "string") { onControlText(ev.data); return; }
  const frame = new Uint8Array(ev.data);
  let msg;
  try { msg = await openC.open(frame); } catch { return; } // drop unauthenticated
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
      if (hasControl) applySize(); // we now drive geometry
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
  else send(Kind.CtrlReq, new Uint8Array(0));
};

const KEYS = {
  esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", left: "\x1b[D", right: "\x1b[C",
  ctrlc: "\x03", ctrld: "\x04",
};
for (const b of document.querySelectorAll("#keys button[data-key]")) {
  b.onclick = () => { term.focus(); sendInput(KEYS[b.dataset.key]); };
}
$("ctrl").onclick = () => { ctrlArmed = !ctrlArmed; $("ctrl").classList.toggle("on", ctrlArmed); term.focus(); };

$("paste").onclick = async () => {
  try {
    const text = await navigator.clipboard.readText();
    if (text) await sendInput(text);
    term.focus();
  } catch {
    fatal("<h1>Paste blocked</h1><p>The browser denied clipboard access. Long-press the terminal to paste instead.</p><button data-dismiss>OK</button>");
  }
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
