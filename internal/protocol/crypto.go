// Package protocol is the relay wire + crypto contract, shared by the runner and
// (mirrored in JS) the browser viewer. See PROTOCOL.md — it is the source of truth.
//
// All terminal IO is end-to-end encrypted with AES-256-GCM under keys derived from
// a 32-byte session secret S that the relay never sees. Every primitive here is Go
// standard library, so the runner needs no third-party crypto.
package protocol

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// SecretLen is the size of the session secret S.
	SecretLen = 32
	// KeyLen is the size of each derived AES-256 key.
	KeyLen = 32

	nonceLen   = 12
	seqLen     = 8
	tagLen     = 16
	pbkdf2Iter = 600_000

	infoR2V = "relay/v1 runner->viewer"
	infoV2R = "relay/v1 viewer->runner"
	infoFP  = "relay/v1 fingerprint"
)

// Errors returned when opening a frame. They are deliberately coarse: a peer (or
// the relay) must not learn why a frame failed to open.
var (
	ErrFrameShort = errors.New("protocol: frame too short")
	ErrOpen       = errors.New("protocol: open failed")
)

// Keys are the directional AEAD keys plus a short fingerprint, all derived from the
// session secret (and an optional passphrase). The fingerprint is shown at both ends
// so a human can confirm they are looking at the same session.
type Keys struct {
	R2V         []byte // seals runner→viewer
	V2R         []byte // seals viewer→runner
	Fingerprint string
}

// DeriveKeys turns the session secret (and optional passphrase) into directional
// keys. id is the session id, used as the HKDF salt so keys are bound to the session.
// When a passphrase is set it is stretched with PBKDF2 and folded into the key
// material, so knowing the link alone (the secret) is not enough to decrypt.
func DeriveKeys(secret []byte, id, passphrase string) (Keys, error) {
	if len(secret) != SecretLen {
		return Keys{}, fmt.Errorf("protocol: secret must be %d bytes, got %d", SecretLen, len(secret))
	}
	ikm := secret
	if passphrase != "" {
		pw, err := pbkdf2.Key(sha256.New, passphrase, []byte(id), pbkdf2Iter, KeyLen)
		if err != nil {
			return Keys{}, err
		}
		ikm = append(append(make([]byte, 0, len(secret)+len(pw)), secret...), pw...)
	}
	salt := []byte(id)
	r2v, err := hkdf.Key(sha256.New, ikm, salt, infoR2V, KeyLen)
	if err != nil {
		return Keys{}, err
	}
	v2r, err := hkdf.Key(sha256.New, ikm, salt, infoV2R, KeyLen)
	if err != nil {
		return Keys{}, err
	}
	fp, err := hkdf.Key(sha256.New, ikm, salt, infoFP, 10)
	if err != nil {
		return Keys{}, err
	}
	return Keys{
		R2V:         r2v,
		V2R:         v2r,
		Fingerprint: base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(fp),
	}, nil
}

// Cipher seals and opens frames for one direction (one key). aad binds frames to the
// session (it is the session id), preventing cross-session replay.
type Cipher struct {
	aead cipher.AEAD
	aad  []byte
}

// NewCipher builds a Cipher from a 32-byte key and the additional authenticated data.
func NewCipher(key, aad []byte) (*Cipher, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Cipher{aead: aead, aad: aad}, nil
}

// Seal produces a wire frame (nonce ‖ ciphertext) for the message (seq, kind,
// payload). The nonce is fresh random bytes, so reconnects can never reuse a nonce.
func (c *Cipher) Seal(seq uint64, kind byte, payload []byte) ([]byte, error) {
	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return c.sealWithNonce(nonce, seq, kind, payload), nil
}

// sealWithNonce is Seal with a caller-supplied nonce — used only by golden vectors.
func (c *Cipher) sealWithNonce(nonce []byte, seq uint64, kind byte, payload []byte) []byte {
	pt := make([]byte, seqLen+1+len(payload))
	binary.BigEndian.PutUint64(pt[:seqLen], seq)
	pt[seqLen] = kind
	copy(pt[seqLen+1:], payload)
	frame := make([]byte, nonceLen, nonceLen+len(pt)+tagLen)
	copy(frame, nonce)
	return c.aead.Seal(frame, nonce, pt, c.aad)
}

// Open authenticates and decrypts a wire frame, returning (seq, kind, payload). A
// frame that fails authentication (tampered, wrong key, wrong session) returns ErrOpen.
func (c *Cipher) Open(frame []byte) (seq uint64, kind byte, payload []byte, err error) {
	if len(frame) < nonceLen+seqLen+1+tagLen {
		return 0, 0, nil, ErrFrameShort
	}
	nonce := frame[:nonceLen]
	pt, err := c.aead.Open(nil, nonce, frame[nonceLen:], c.aad)
	if err != nil {
		return 0, 0, nil, ErrOpen
	}
	if len(pt) < seqLen+1 {
		return 0, 0, nil, ErrFrameShort
	}
	seq = binary.BigEndian.Uint64(pt[:seqLen])
	kind = pt[seqLen]
	payload = pt[seqLen+1:]
	return seq, kind, payload, nil
}
