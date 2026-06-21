// relay end-to-end crypto — the browser mirror of internal/protocol/crypto.go.
// Pure Web Crypto + standard globals, so it runs unchanged in a browser and under
// `node --test`. Interop with Go is pinned by internal/protocol/testdata/vectors.json.

const enc = new TextEncoder();
const subtle = globalThis.crypto.subtle;

const NONCE_LEN = 12;
const TAG_LEN = 16;
const SEQ_LEN = 8;
const PBKDF2_ITER = 600000;

const INFO_R2V = "relay/v1 runner->viewer";
const INFO_V2R = "relay/v1 viewer->runner";
const INFO_FP = "relay/v1 fingerprint";

// --- encodings ---------------------------------------------------------------

export function bytesToHex(b) {
  let s = "";
  for (const x of b) s += x.toString(16).padStart(2, "0");
  return s;
}

export function hexToBytes(h) {
  const a = new Uint8Array(h.length / 2);
  for (let i = 0; i < a.length; i++) a[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return a;
}

export function b64urlToBytes(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const a = new Uint8Array(bin.length);
  for (let i = 0; i < a.length; i++) a[i] = bin.charCodeAt(i);
  return a;
}

// RFC 4648 base32, no padding — matches Go base32.StdEncoding.WithPadding(NoPadding).
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
function base32nopad(bytes) {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function concat(a, b) {
  const o = new Uint8Array(a.length + b.length);
  o.set(a, 0);
  o.set(b, a.length);
  return o;
}

// --- key derivation ----------------------------------------------------------

async function hkdf(ikm, salt, info, lenBytes) {
  const k = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const bits = await subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info: enc.encode(info) },
    k,
    lenBytes * 8,
  );
  return new Uint8Array(bits);
}

async function pbkdf2(passphrase, salt, iter, lenBytes) {
  const k = await subtle.importKey("raw", enc.encode(passphrase), "PBKDF2", false, ["deriveBits"]);
  const bits = await subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: iter },
    k,
    lenBytes * 8,
  );
  return new Uint8Array(bits);
}

// deriveKeys mirrors protocol.DeriveKeys: directional key material + fingerprint.
export async function deriveKeys(secret, id, passphrase) {
  const salt = enc.encode(id);
  let ikm = secret;
  if (passphrase) ikm = concat(secret, await pbkdf2(passphrase, salt, PBKDF2_ITER, 32));
  const r2v = await hkdf(ikm, salt, INFO_R2V, 32);
  const v2r = await hkdf(ikm, salt, INFO_V2R, 32);
  const fp = await hkdf(ikm, salt, INFO_FP, 10);
  return { r2v, v2r, fingerprint: base32nopad(fp) };
}

// --- AEAD --------------------------------------------------------------------

// newCipher returns { seal, open } for one direction. aad is the session id bytes.
export async function newCipher(keyBytes, aad) {
  const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt", "decrypt"]);

  async function sealWithNonce(nonce, seq, kind, payload) {
    const pt = new Uint8Array(SEQ_LEN + 1 + payload.length);
    // seq is a JS Number; BigInt(seq) is exact up to 2^53 (open() converts back the
    // same way). Unreachable in a terminal session — see PROTOCOL.md.
    new DataView(pt.buffer).setBigUint64(0, BigInt(seq));
    pt[SEQ_LEN] = kind;
    pt.set(payload, SEQ_LEN + 1);
    const ct = new Uint8Array(
      await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 }, key, pt),
    );
    return concat(nonce, ct);
  }

  return {
    async seal(seq, kind, payload) {
      const nonce = globalThis.crypto.getRandomValues(new Uint8Array(NONCE_LEN));
      return sealWithNonce(nonce, seq, kind, payload);
    },
    async open(frame) {
      if (frame.length < NONCE_LEN + SEQ_LEN + 1 + TAG_LEN) throw new Error("frame too short");
      const nonce = frame.subarray(0, NONCE_LEN);
      let pt;
      try {
        pt = new Uint8Array(
          await subtle.decrypt(
            { name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 },
            key,
            frame.subarray(NONCE_LEN),
          ),
        );
      } catch {
        throw new Error("open failed");
      }
      if (pt.length < SEQ_LEN + 1) throw new Error("frame too short");
      const dv = new DataView(pt.buffer, pt.byteOffset, pt.byteLength);
      return { seq: Number(dv.getBigUint64(0)), kind: pt[SEQ_LEN], payload: pt.subarray(SEQ_LEN + 1) };
    },
    // Deterministic seal — for golden-vector tests only.
    _sealWithNonce: sealWithNonce,
  };
}
