// relay wire codecs — the browser mirror of internal/protocol/wire.go.
// Message-kind numbers are part of the contract (see PROTOCOL.md) and must match Go.

export const Kind = {
  Hello: 0x01,
  Output: 0x02,
  Exit: 0x03,
  Control: 0x04,
  Input: 0x10,
  Resize: 0x11,
  CtrlReq: 0x12,
  CtrlRel: 0x13,
};

export const Control = { ReadOnly: 0, Granted: 1 };

export function decodeHello(b) {
  if (b.length < 12) throw new Error("short hello");
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  // The protocol's sequence numbers are uint64; JS represents them as Number, which
  // is exact only up to 2^53 (Number.MAX_SAFE_INTEGER). A terminal session would
  // need ~9 quadrillion frames to reach that, so the assumption never bites in
  // practice — see PROTOCOL.md. Same conversion in crypto.js seal/open.
  return { baseline: Number(dv.getBigUint64(0)), cols: dv.getUint16(8), rows: dv.getUint16(10) };
}

export function encodeResize(cols, rows) {
  const b = new Uint8Array(4);
  const dv = new DataView(b.buffer);
  dv.setUint16(0, cols);
  dv.setUint16(2, rows);
  return b;
}

export function decodeExit(b) {
  if (b.length < 4) throw new Error("short exit");
  return new DataView(b.buffer, b.byteOffset, b.byteLength).getInt32(0);
}

export function decodeControl(b) {
  return b.length > 0 ? b[0] : 0;
}

// EMPTY is the shared empty payload for control-request/release frames.
export const EMPTY = new Uint8Array(0);
