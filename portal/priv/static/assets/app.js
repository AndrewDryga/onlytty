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

// Mobile IME / composition / predictive text is delegated entirely to xterm's
// hidden helper textarea (it emits committed text through `onData`). This is a
// deliberate choice: a terminal is a raw byte stream, not a text field, so we do
// NOT add our own `compositionstart/end`/`beforeinput` layer — that would risk
// double-sending composed input or fighting xterm's own handling. Known tradeoff:
// some mobile keyboards' predictive/CJK composition has rough edges inside xterm's
// textarea; if that becomes a real problem, handle composition here rather than in
// xterm. We do nudge the soft keyboard to a terminal-friendly mode (no autocorrect/
// autocapitalize, "send" enter hint) on the helper textarea it just created.
const helper = $("terminal").querySelector(".xterm-helper-textarea");
if (helper) {
  helper.setAttribute("autocorrect", "off");
  helper.setAttribute("autocapitalize", "off");
  helper.setAttribute("spellcheck", "false");
  helper.setAttribute("enterkeyhint", "send");
}

// --- state -------------------------------------------------------------------
let openC, sealC; // r2v (open), v2r (seal)
let ws = null;
let outSeq = 0; // viewer→runner sequence (starts at HELLO baseline)
let lastSeq = 0; // runner→viewer replay floor (monotonic, runner is one process)
let hasControl = false;
let controlPending = false, controlTimer = null; // a "Take control" tap awaiting the host's answer
let expiresAt = null, ttlTimer = null; // session expiry (unix s) from the hello, for the countdown
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
  if (controlPending && !hasControl) { b.textContent = "Requesting…"; b.className = "on"; return; }
  b.textContent = hasControl ? "You have control" : "Take control";
  b.className = hasControl ? "live" : "";
}

// Clear the pending "Take control" state (timer + flag) without changing hasControl.
function clearControlPending() {
  controlPending = false;
  if (controlTimer) { clearTimeout(controlTimer); controlTimer = null; }
}

// --- session-fingerprint verification ----------------------------------------
// On the first load of a session we prompt the user to compare the fingerprint
// with the one in their terminal — proof both ends derived the same keys from the
// same secret, with no one in the middle. The confirmation is remembered per
// session: keyed by the session id and storing the exact fingerprint that was
// confirmed, so a reload doesn't nag, but a *different* session — or keys that no
// longer match (e.g. a different passphrase) — must be verified afresh. Stored
// device-local; never anything from the URL.
const VERIFIED_KEY = "onlytty.verified." + id;
function isVerified(fp) {
  try { return !!fp && localStorage.getItem(VERIFIED_KEY) === fp; } catch { return false; }
}
function showVerify() {
  const fp = $("fp").textContent;
  if (!fp) return;
  const o = $("overlay");
  $("overlay-card").innerHTML =
    "<h1>Verify this session</h1>" +
    "<p>Compare this with the fingerprint shown in your terminal. If they match, the connection is end-to-end encrypted with no one in the middle — confirm once and this browser won't ask again for this session.</p>" +
    `<p><code>${fp}</code></p>` +
    '<div class="verify-actions">' +
      '<button id="fp-match">They match</button>' +
      '<button id="fp-nomatch" class="ghost">They don’t match</button>' +
    "</div>";
  $("fp-match").onclick = () => {
    try { localStorage.setItem(VERIFIED_KEY, fp); } catch {}
    o.hidden = true;
    term.focus();
  };
  $("fp-nomatch").onclick = () => {
    $("overlay-card").innerHTML =
      "<h1>Don't trust this session</h1>" +
      "<p>The fingerprint here doesn't match your terminal, so the keys differ — this may be the wrong link or a tampered session. Don't type anything secret: close this tab and re-open the original link printed by your terminal.</p>" +
      "<button data-dismiss>OK</button>";
    o.querySelectorAll("[data-dismiss]").forEach((b) => b.addEventListener("click", () => { o.hidden = true; }));
  };
  o.hidden = false;
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
  // First load of this session (or keys we haven't confirmed): prompt to verify.
  if (!isVerified($("fp").textContent)) showVerify();
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
    // Three quick tries (~1.5s with the 500ms/1000ms backoff) is a strong signal
    // it's gone, while still riding out a one-off blip on the very first connect.
    if (!everConnected && ++failCount >= 3) {
      noReconnect = true;
      fatal("<h1>Session not found</h1><p>This session is unknown or has expired. Start a new one with <code>onlytty</code> and open the fresh link.</p>");
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
  everDecoded = false; lastSeq = 0; outSeq = 0; hasControl = false; clearControlPending(); updateControlUI();
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
    case Kind.Control: {
      const granted = decodeControl(payload) === Control.Granted;
      const wasPending = controlPending;
      clearControlPending();
      hasControl = granted;
      if (granted) {
        applySize(); term.focus(); // we now drive geometry; keep the keyboard up
        setStatus("connected", "ok");
      } else if (wasPending) {
        // The host answered our request with read-only: it's view-only (or a
        // one-shot already used). Tell the user instead of silently doing nothing.
        setStatus("control not granted — host is view-only", "warn");
      }
      updateControlUI();
      break;
    }
    case Kind.Exit: {
      const code = decodeExit(payload);
      term.write(`\r\n\x1b[2m── command exited (${code}) ──\x1b[0m\r\n`);
      ended = true; noReconnect = true; exitSeen = true; hasControl = false;
      clearControlPending();
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
    case "hello":
      if (typeof m.expires_at === "number") { expiresAt = m.expires_at; startTtl(); }
      break;
    case "peer_join": if (!ended) setStatus("connected", "ok"); break;
    case "peer_left": if (!ended) setStatus("runner disconnected — waiting…", "warn"); break;
    case "busy":
      noReconnect = true;
      fatal("<h1>Session busy</h1><p>Another viewer is already connected. This session allows one viewer at a time.</p>");
      break;
    case "bye":
      ended = true; noReconnect = true; hasControl = false;
      clearControlPending();
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

// Anything past this in a single chunk is a paste, not typing — confirm it even
// without newlines (a giant one-liner is as risky as a multi-line block).
const PASTE_CONFIRM_LEN = 1024;

async function sendInput(data) {
  if (!hasControl) return;
  // Guard accidental pastes: a multi-line block, or a large single-line chunk.
  const multiline = data.length > 2 && /[\n\r]/.test(data.slice(0, -1));
  if (multiline) {
    const lines = data.split(/\r?\n/).length;
    if (!confirm(`Send ${lines} lines to the terminal?`)) return;
  } else if (data.length > PASTE_CONFIRM_LEN) {
    if (!confirm(`Send ${data.length} characters to the terminal?`)) return;
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

// --- expiry countdown --------------------------------------------------------
// The session has a server-side TTL; show the time remaining and, if we reach it,
// fall to a terminal state ourselves so a missed EXIT can never leave the viewer
// hanging at "waiting…" indefinitely.
function startTtl() {
  if (ttlTimer) clearInterval(ttlTimer);
  tickTtl();
  ttlTimer = setInterval(tickTtl, 1000);
}
function stopTtl() {
  if (ttlTimer) { clearInterval(ttlTimer); ttlTimer = null; }
  $("ttl").hidden = true;
}
function tickTtl() {
  if (ended || expiresAt == null) { stopTtl(); return; }
  const rem = expiresAt - Math.floor(Date.now() / 1000);
  if (rem <= 0) { stopTtl(); leave("session expired", "expired"); return; }
  const el = $("ttl");
  el.hidden = false;
  el.textContent = "expires in " + fmtDur(rem);
  el.classList.toggle("soon", rem <= 300);
}
function fmtDur(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60), sec = s % 60;
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${String(sec).padStart(2, "0")}s`;
  return `${sec}s`;
}

// Terminal-state transition shared by Disconnect and expiry: stop reconnecting,
// close the socket (which frees the single-viewer slot), and show why.
function leave(line, status) {
  if (ended) return;
  ended = true; noReconnect = true; hasControl = false;
  clearControlPending();
  stopTtl();
  try { if (ws) { ws.onclose = null; ws.close(); ws = null; } } catch {}
  term.write(`\r\n\x1b[2m── ${line} ──\x1b[0m\r\n`);
  setStatus(status, "warn");
  updateControlUI();
}

// --- controls ----------------------------------------------------------------
$("disconnect").onclick = () => leave("disconnected", "disconnected");
$("control").onclick = () => {
  if (ended) return;
  if (hasControl) {
    send(Kind.CtrlRel, new Uint8Array(0));
    hasControl = false;
    clearControlPending();
    updateControlUI();
    applySize();
    return;
  }
  // Request control: show a pending state and arm a fallback timeout, so a host that
  // never answers (view-only with no reply, or no runner attached) still gets surfaced
  // instead of leaving the button stuck. A Control frame clears this first when it
  // arrives. Focus now, inside the click gesture, so the mobile soft keyboard opens.
  send(Kind.CtrlReq, new Uint8Array(0));
  controlPending = true;
  updateControlUI();
  term.focus();
  if (controlTimer) clearTimeout(controlTimer);
  controlTimer = setTimeout(() => {
    if (controlPending && !hasControl) {
      clearControlPending();
      setStatus("control not granted — host is view-only", "warn");
      updateControlUI();
    }
  }, 3000);
};

// Overflow menu (⋯): the secondary controls live here so the top bar stays uncluttered.
// Tapping it toggles; tapping an item (except the font +/−) or outside closes it.
const menu = $("menu");
$("menu-btn").addEventListener("click", (e) => { e.stopPropagation(); menu.hidden = !menu.hidden; });
menu.addEventListener("click", (e) => { if (e.target.closest("button") && !e.target.closest(".seg")) menu.hidden = true; });
document.addEventListener("click", (e) => {
  if (!menu.hidden && !menu.contains(e.target) && e.target !== $("menu-btn")) menu.hidden = true;
});
$("menu-verify").addEventListener("click", showVerify);
// Open the mobile soft keyboard on demand — focusing inside the click gesture is
// what lets iOS/Android raise it (tapping the terminal isn't always discoverable).
$("kbd").onclick = () => term.focus();

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
