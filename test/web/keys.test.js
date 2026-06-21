// Unit tests for the viewer shortcut payload parser (`^X` control-char notation).
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePayload } from "../../portal/priv/static/assets/keys.js";

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
