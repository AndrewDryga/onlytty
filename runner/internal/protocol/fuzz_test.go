package protocol

import "testing"

// The wire decoders and Cipher.Open parse relay-forwarded, attacker-influenceable
// bytes. They must reject malformed input with an error — never panic. The seed
// corpus runs under `go test`; `make fuzz` (or `go test -fuzz`) explores further.

func FuzzDecodeHello(f *testing.F) {
	f.Add(EncodeHello(1, 80, 24))
	f.Add([]byte{})
	f.Add([]byte{0, 1, 2})
	f.Fuzz(func(_ *testing.T, b []byte) {
		_, _, _, _ = DecodeHello(b)
	})
}

func FuzzDecodeResize(f *testing.F) {
	f.Add(EncodeResize(80, 24))
	f.Add([]byte{})
	f.Fuzz(func(_ *testing.T, b []byte) {
		_, _, _ = DecodeResize(b)
	})
}

func FuzzDecodeExit(f *testing.F) {
	f.Add(EncodeExit(0))
	f.Add([]byte{})
	f.Fuzz(func(_ *testing.T, b []byte) {
		_, _ = DecodeExit(b)
	})
}

func FuzzCipherOpen(f *testing.F) {
	c, err := NewCipher(make([]byte, 32), []byte("session-aad"))
	if err != nil {
		f.Fatal(err)
	}
	if frame, err := c.Seal(1, 1, []byte("hi")); err == nil {
		f.Add(frame)
	}
	f.Add([]byte{})
	f.Fuzz(func(_ *testing.T, frame []byte) {
		// Garbage, truncated, or tampered frames must error, never panic.
		_, _, _, _ = c.Open(frame)
	})
}
