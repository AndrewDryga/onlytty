// Wire-codec tests. In particular, pin the uint64 sequence-number → JS Number
// precision assumption: decode is exact for any seq up to 2^53 (far beyond any
// real session). See PROTOCOL.md "JS precision note".
import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeHello, encodeViewerPayload, decodeViewerPayload } from "../../../portal/priv/static/assets/wire.js";

// Build a 12-byte HELLO body: baseline:uint64 BE, cols:uint16 BE, rows:uint16 BE.
function hello(baseline, cols, rows) {
  const b = new Uint8Array(12);
  const dv = new DataView(b.buffer);
  dv.setBigUint64(0, BigInt(baseline));
  dv.setUint16(8, cols);
  dv.setUint16(10, rows);
  return b;
}

test("decodeHello round-trips a typical baseline + size", () => {
  const got = decodeHello(hello(1, 80, 24));
  assert.deepEqual(got, { baseline: 1, cols: 80, rows: 24 });
});

test("decodeHello is exact at baseline 0 and a large mid-session value", () => {
  assert.equal(decodeHello(hello(0, 1, 1)).baseline, 0);
  assert.equal(decodeHello(hello(1_000_000_000, 100, 40)).baseline, 1_000_000_000);
});

test("decodeHello is exact up to Number.MAX_SAFE_INTEGER (2^53 - 1)", () => {
  const max = Number.MAX_SAFE_INTEGER; // 9007199254740991
  assert.equal(decodeHello(hello(max, 200, 50)).baseline, max);
  // sanity: the test's own encoder preserved it (no silent BigInt truncation)
  assert.equal(BigInt(max), 9007199254740991n);
});

test("decodeHello rejects a short body", () => {
  assert.throws(() => decodeHello(new Uint8Array(11)), /short hello/);
});

test("viewer payload wrapper round-trips and leaves legacy payloads alone", () => {
  const wrapped = encodeViewerPayload("viewer-a", new Uint8Array([1, 2, 3]));
  const got = decodeViewerPayload(wrapped);
  assert.equal(got.viewerId, "viewer-a");
  assert.deepEqual([...got.payload], [1, 2, 3]);

  const legacy = new Uint8Array([9, 8, 7]);
  const plain = decodeViewerPayload(legacy);
  assert.equal(plain.viewerId, "");
  assert.equal(plain.payload, legacy);
});
