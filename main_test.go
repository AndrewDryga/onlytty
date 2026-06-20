package main

import (
	"testing"
	"time"
)

// The banner must show the relay's assigned expiry (Session.ExpiresAt), not the
// raw --ttl flag, since the server clamps the TTL to [60s, 24h].
func TestRemainingDerivesFromExpiresAt(t *testing.T) {
	now := time.Unix(1_000_000, 0)

	// --ttl 100000h gets clamped to 24h; the banner reflects the clamp.
	if got := remaining(now.Add(24*time.Hour).Unix(), now); got != 24*time.Hour {
		t.Fatalf("remaining = %s, want 24h0m0s", got)
	}
	// --ttl 1s gets clamped up to 60s.
	if got := remaining(now.Add(60*time.Second).Unix(), now); got != 60*time.Second {
		t.Fatalf("remaining = %s, want 1m0s", got)
	}
}
