package protocol

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
)

var update = flag.Bool("update", false, "regenerate testdata/vectors.json")

// The golden vectors pin the exact bytes the crypto layer produces so the Go runner
// and the JS viewer provably interoperate. Run `go test ./internal/protocol -update`
// to regenerate after an intentional protocol change; the JS suite verifies the same
// file (test/web/crypto.test.mjs).

type kdfVector struct {
	Secret      string `json:"secret"`
	ID          string `json:"id"`
	Passphrase  string `json:"passphrase"`
	KR2V        string `json:"k_r2v"`
	KV2R        string `json:"k_v2r"`
	Fingerprint string `json:"fingerprint"`
}

type frameVector struct {
	Key     string `json:"key"`
	AAD     string `json:"aad"`
	Nonce   string `json:"nonce"`
	Seq     uint64 `json:"seq"`
	Kind    byte   `json:"kind"`
	Payload string `json:"payload"`
	Frame   string `json:"frame"`
}

type vectors struct {
	KDF    []kdfVector   `json:"kdf"`
	Frames []frameVector `json:"frames"`
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func buildVectors(t *testing.T) vectors {
	t.Helper()
	secret := mustHex(t, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	id := "s7Qb3kZ9xR2mN1pT"

	plain, err := DeriveKeys(secret, id, "")
	if err != nil {
		t.Fatal(err)
	}
	withPass, err := DeriveKeys(secret, id, "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}

	nonce := mustHex(t, "0a0b0c0d0e0f101112131415")
	payload := []byte("hello, world\n")
	c, err := NewCipher(plain.R2V, []byte(id))
	if err != nil {
		t.Fatal(err)
	}
	frame := c.sealWithNonce(nonce, 7, KindOutput, payload)

	return vectors{
		KDF: []kdfVector{
			{hex.EncodeToString(secret), id, "", hex.EncodeToString(plain.R2V), hex.EncodeToString(plain.V2R), plain.Fingerprint},
			{hex.EncodeToString(secret), id, "correct horse battery staple", hex.EncodeToString(withPass.R2V), hex.EncodeToString(withPass.V2R), withPass.Fingerprint},
		},
		Frames: []frameVector{
			{hex.EncodeToString(plain.R2V), id, hex.EncodeToString(nonce), 7, KindOutput, hex.EncodeToString(payload), hex.EncodeToString(frame)},
		},
	}
}

func TestVectors(t *testing.T) {
	path := filepath.Join("testdata", "vectors.json")
	if *update {
		v := buildVectors(t)
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", path)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read vectors (run with -update to generate): %v", err)
	}
	var want vectors
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	got := buildVectors(t)
	gb, _ := json.Marshal(got)
	wb, _ := json.Marshal(want)
	if !bytes.Equal(gb, wb) {
		t.Fatalf("vectors drifted from testdata/vectors.json\n got: %s\nwant: %s", gb, wb)
	}

	// The committed frame must open to its payload — proves the wire format too.
	fv := want.Frames[0]
	c, err := NewCipher(mustHex(t, fv.Key), []byte(fv.AAD))
	if err != nil {
		t.Fatal(err)
	}
	seq, kind, payload, err := c.Open(mustHex(t, fv.Frame))
	if err != nil {
		t.Fatalf("open golden frame: %v", err)
	}
	if seq != fv.Seq || kind != fv.Kind || !bytes.Equal(payload, mustHex(t, fv.Payload)) {
		t.Fatalf("golden frame mismatch: seq=%d kind=%d payload=%q", seq, kind, payload)
	}
}

func TestSealOpenRoundTrip(t *testing.T) {
	keys, err := DeriveKeys(bytes.Repeat([]byte{0xab}, SecretLen), "sess-xyz", "")
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewCipher(keys.R2V, []byte("sess-xyz"))
	if err != nil {
		t.Fatal(err)
	}
	for _, payload := range [][]byte{[]byte(""), []byte("a"), []byte("multi\nline\toutput \x1b[31mred\x1b[0m"), bytes.Repeat([]byte{0xff}, 70000)} {
		frame, err := c.Seal(42, KindOutput, payload)
		if err != nil {
			t.Fatal(err)
		}
		seq, kind, got, err := c.Open(frame)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		if seq != 42 || kind != KindOutput || !bytes.Equal(got, payload) {
			t.Fatalf("round-trip mismatch seq=%d kind=%d", seq, kind)
		}
	}
}

func TestOpenRejectsTampering(t *testing.T) {
	keys, _ := DeriveKeys(bytes.Repeat([]byte{0x01}, SecretLen), "id1", "")
	c, _ := NewCipher(keys.R2V, []byte("id1"))
	frame, _ := c.Seal(1, KindOutput, []byte("secret output"))

	// Flip one byte in the ciphertext body.
	bad := append([]byte(nil), frame...)
	bad[len(bad)-1] ^= 0x01
	if _, _, _, err := c.Open(bad); err != ErrOpen {
		t.Fatalf("tampered frame: want ErrOpen, got %v", err)
	}

	// A truncated frame is rejected.
	if _, _, _, err := c.Open(frame[:10]); err != ErrFrameShort {
		t.Fatalf("short frame: want ErrFrameShort, got %v", err)
	}
}

func TestOpenRejectsWrongSessionAndKey(t *testing.T) {
	keys, _ := DeriveKeys(bytes.Repeat([]byte{0x02}, SecretLen), "right", "")
	good, _ := NewCipher(keys.R2V, []byte("right"))
	frame, _ := good.Seal(1, KindOutput, []byte("hi"))

	// Same key, wrong AAD (different session) → fails (cross-session replay defense).
	wrongAAD, _ := NewCipher(keys.R2V, []byte("wrong"))
	if _, _, _, err := wrongAAD.Open(frame); err != ErrOpen {
		t.Fatalf("wrong aad: want ErrOpen, got %v", err)
	}
	// Wrong key (e.g. the other direction) → fails.
	wrongKey, _ := NewCipher(keys.V2R, []byte("right"))
	if _, _, _, err := wrongKey.Open(frame); err != ErrOpen {
		t.Fatalf("wrong key: want ErrOpen, got %v", err)
	}
}

func TestDeriveKeysProperties(t *testing.T) {
	secret := bytes.Repeat([]byte{0x07}, SecretLen)
	a, _ := DeriveKeys(secret, "sess", "")
	b, _ := DeriveKeys(secret, "sess", "")
	if !bytes.Equal(a.R2V, b.R2V) || !bytes.Equal(a.V2R, b.V2R) || a.Fingerprint != b.Fingerprint {
		t.Fatal("derivation must be deterministic")
	}
	if bytes.Equal(a.R2V, a.V2R) {
		t.Fatal("directional keys must differ")
	}
	// Passphrase changes everything.
	p, _ := DeriveKeys(secret, "sess", "pw")
	if bytes.Equal(a.R2V, p.R2V) || a.Fingerprint == p.Fingerprint {
		t.Fatal("passphrase must change keys + fingerprint")
	}
	// Different session id changes everything.
	d, _ := DeriveKeys(secret, "other", "")
	if bytes.Equal(a.R2V, d.R2V) {
		t.Fatal("session id must change keys")
	}
	if _, err := DeriveKeys(secret[:10], "sess", ""); err == nil {
		t.Fatal("short secret must error")
	}
}

func TestCodecsRoundTrip(t *testing.T) {
	baseline, cols, rows, err := DecodeHello(EncodeHello(99, 120, 40))
	if err != nil || baseline != 99 || cols != 120 || rows != 40 {
		t.Fatalf("hello: %d %d %d %v", baseline, cols, rows, err)
	}
	c, r, err := DecodeResize(EncodeResize(200, 50))
	if err != nil || c != 200 || r != 50 {
		t.Fatalf("resize: %d %d %v", c, r, err)
	}
	code, err := DecodeExit(EncodeExit(-1))
	if err != nil || code != -1 {
		t.Fatalf("exit: %d %v", code, err)
	}
	if _, _, _, err := DecodeHello([]byte{1, 2}); err == nil {
		t.Fatal("short hello must error")
	}
}
