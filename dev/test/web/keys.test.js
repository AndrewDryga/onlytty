// Unit tests for the viewer shortcut payload parser (`^X` control-char notation).
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePayload, isTerminalReport } from "../../../portal/priv/static/assets/keys.js";

test("^L expands to byte 0x0c (Ctrl-L, clear)", () => {
  assert.equal(parsePayload("^L"), "\x0c");
  assert.equal(parsePayload("^L").charCodeAt(0), 0x0c);
});

test("^M is carriage return (Enter) and ^[ is Esc", () => {
  assert.equal(parsePayload("^M"), "\r");
  assert.equal(parsePayload("^["), "\x1b");
});

test("control notation is lowercase-insensitive", () => {
  assert.equal(parsePayload("^c"), "\x03");
  assert.equal(parsePayload("^C"), "\x03");
});

test("literal text passes through unchanged", () => {
  assert.equal(parsePayload("git status"), "git status");
});

test("a snippet ending in ^M runs as a command line", () => {
  assert.equal(parsePayload("echo hi^M"), "echo hi\r");
});

test("a trailing caret with nothing after it stays literal", () => {
  assert.equal(parsePayload("a^"), "a^");
});

test("a caret before a non-control char stays literal", () => {
  // space is 0x20, below the control range, so it is left as `^ `.
  assert.equal(parsePayload("^ "), "^ ");
});

// xterm's own reports must never read as a read-only viewer asking for control.
// Every shape the vendored xterm emits, plus the mouse encodings a program can pick.
test("xterm's own reports are recognised", () => {
  for (const report of [
    "\x1b[<35;69;27M", "\x1b[<0;1;1m", "\x1b[<64;5;5M", // SGR mouse: motion, release, wheel
    "\x1b[M #!", "\x1b[32;10;5M", // X10 / UTF-8 and urxvt mouse
    "\x1b[I", "\x1b[O", // focus in / out
    "\x1b[?1;2c", "\x1b[>0;276;0c", // device attributes
    "\x1b[0n", "\x1b[12;40R", "\x1b[?12;40R", // status, cursor position
    "\x1b[?2026;2$y", "\x1b[4;2$y", // mode reports
    "\x1b[8;24;80t", // window size
    "\x1bP1$r0m\x1b\\", "\x1b]11;rgb:0b0b/0e0e/1414\x1b\\", "\x1b]10;rgb:c8c8/d3d3/e0e0\x07", // DCS / OSC
  ]) {
    assert.equal(isTerminalReport(report), true, JSON.stringify(report));
  }
});

test("typing, keys and pastes are not reports", () => {
  for (const input of [
    "a", "hello", "\r", "\x03", "\x7f", "\x1b", // text, Enter, Ctrl-C, Backspace, Esc
    "\x1b[A", "\x1bOA", "\x1b[1;5A", "\x1b[H", "\x1b[Z", // arrows, Ctrl-arrow, Home, Shift-Tab
    "\x1b[3~", "\x1b[15;2~", "\x1bOR", // Delete, Shift-F5, F3
    "\x1bp", "\x1bP", "\x1b]", "\x1b[", // Alt+p, Alt+P, Alt+], Alt+[
    "\x1b[99;5u", // a CSI u key
    "\x1b[200~ls -la\x1b[201~", // bracketed paste
  ]) {
    assert.equal(isTerminalReport(input), false, JSON.stringify(input));
  }
});
