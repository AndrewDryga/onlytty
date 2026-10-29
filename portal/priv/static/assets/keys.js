// Pure helpers for the viewer's input: pinnable shortcuts and xterm's own reports.
// Kept out of app.js so they're unit-testable in node (app.js touches the DOM on import).

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

// What xterm sends on its own, unasked by the person at the keyboard: mouse reports
// while the program tracks the mouse, focus in/out, and answers to the program's
// terminal queries. No key xterm encodes has these shapes, except that Shift+F3
// shares the cursor-position report's.
const REPORTS = [
  /^\x1b\[[<>?][\d;]*\$?[A-Za-z]$/, // SGR mouse; device attributes, DEC mode and cursor reports
  /^\x1b\[M[\s\S]{3}$/, // X10 / UTF-8 mouse
  /^\x1b\[\d+;\d+;\d+[Mt]$/, // urxvt mouse; window size reports
  /^\x1b\[[IO]$/, // focus in / out
  /^\x1b\[\d*n$/, // device status
  /^\x1b\[\d+;\d+R$/, // cursor position
  /^\x1b\[\d+;\d+\$y$/, // ANSI mode report
  /^\x1b[P\]][\s\S]*(\x1b\\|\x07)$/, // DCS and OSC replies (settings, colours)
];

export function isTerminalReport(data) {
  return REPORTS.some((re) => re.test(data));
}
