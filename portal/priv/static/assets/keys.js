// Pure helpers for the viewer's pinnable touch shortcuts. Kept out of app.js so the
// payload parsing is unit-testable in node (app.js touches the DOM on import).

// Expand `^X` control-char notation to the actual control byte, leaving other text
// literal. `^L` → 0x0c (Ctrl-L), `^M` → 0x0d (Enter), `^[` → 0x1b (Esc). A trailing
// `^` with nothing after it, or `^` before a non-control char, stays literal.
export function parsePayload(s) {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "^" && i + 1 < s.length) {
      const ch = s[++i];
      const c = ch.toUpperCase().charCodeAt(0);
      out += c >= 64 && c < 128 ? String.fromCharCode(c & 0x1f) : "^" + ch;
    } else {
      out += s[i];
    }
  }
  return out;
}
