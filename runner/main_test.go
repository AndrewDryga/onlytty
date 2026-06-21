package main

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/runner"
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

func TestGeneratePassphrase(t *testing.T) {
	p, err := generatePassphrase()
	if err != nil {
		t.Fatal(err)
	}
	// 80 bits → 16 base32 chars grouped into 4s with 3 dashes = 19.
	if len(p) != 19 {
		t.Fatalf("len = %d, want 19 (%q)", len(p), p)
	}
	// Unambiguous charset only: base32 upper A–Z/2–7 plus the grouping dash.
	const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567-"
	for _, r := range p {
		if !strings.ContainsRune(allowed, r) {
			t.Fatalf("ambiguous/invalid char %q in %q", r, p)
		}
	}
	// Distinct each call.
	if p2, _ := generatePassphrase(); p == p2 {
		t.Fatal("two generated passphrases should differ")
	}
}

func TestResolveControl(t *testing.T) {
	cases := []struct {
		name     string
		flag     string
		readOnly bool
		set      bool
		want     runner.ControlMode
		wantErr  bool
	}{
		{"default ask", "ask", false, false, runner.ControlAsk, false},
		{"explicit view-only", "view-only", false, true, runner.ControlViewOnly, false},
		{"once", "once", false, true, runner.ControlOnce, false},
		{"read-only alias maps to view-only", "ask", true, false, runner.ControlViewOnly, false},
		{"read-only with matching view-only is fine", "view-only", true, true, runner.ControlViewOnly, false},
		{"read-only conflicts with once", "once", true, true, 0, true},
		{"unknown mode errors", "bogus", false, true, 0, true},
	}
	for _, c := range cases {
		got, err := resolveControl(c.flag, c.readOnly, c.set)
		if c.wantErr {
			if err == nil {
				t.Errorf("%s: expected an error, got mode %v", c.name, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
		} else if got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
