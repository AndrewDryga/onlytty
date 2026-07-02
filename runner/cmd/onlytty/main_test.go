package main

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/relayclient"
	"github.com/AndrewDryga/onlytty/runner/internal/runner"
)

// envOr resolves the relay default: unset/empty → the hosted relay; set → the env wins.
func TestEnvOr(t *testing.T) {
	const key = "ONLYTTY_TEST_ENVOR"

	if got := envOr(key, defaultPublicRelay); got != defaultPublicRelay {
		t.Errorf("unset: got %q, want the fallback %q", got, defaultPublicRelay)
	}
	t.Setenv(key, "") // an explicitly blank ONLYTTY_SERVER still falls back to the default
	if got := envOr(key, defaultPublicRelay); got != defaultPublicRelay {
		t.Errorf("empty: got %q, want the fallback %q", got, defaultPublicRelay)
	}
	t.Setenv(key, "https://relay.example.com")
	if got := envOr(key, defaultPublicRelay); got != "https://relay.example.com" {
		t.Errorf("set: got %q, want the env value to win", got)
	}
}

// The zero-config default must satisfy the same validation as a user-supplied
// --server (https, has a host), or every default `onlytty -- <cmd>` would fail at
// startup. This guards against a fat-fingered constant breaking the headline flow.
func TestDefaultPublicRelayIsValid(t *testing.T) {
	if _, err := relayclient.New(defaultPublicRelay, false); err != nil {
		t.Fatalf("defaultPublicRelay %q rejected by relayclient.New: %v", defaultPublicRelay, err)
	}
}

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

func TestWriteQRHalfBlock(t *testing.T) {
	var out bytes.Buffer

	writeQRHalfBlock(&out, "https://onlytty.com/s/test#secret")

	got := out.String()
	if got == "" {
		t.Fatal("expected QR output")
	}
	for _, want := range []string{"\u2588", "\u2580", "\u2584"} {
		if !strings.Contains(got, want) {
			t.Fatalf("QR output missing %q", want)
		}
	}
}

func TestResolveControl(t *testing.T) {
	cases := []struct {
		name    string
		flag    string
		want    runner.ControlMode
		wantErr bool
	}{
		{"default auto", "auto", runner.ControlAuto, false},
		{"explicit view-only", "view-only", runner.ControlViewOnly, false},
		{"once", "once", runner.ControlOnce, false},
		{"old ask mode is rejected", "ask", 0, true},
		{"unknown mode errors", "bogus", 0, true},
	}
	for _, c := range cases {
		got, err := resolveControl(c.flag)
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

func TestSessionInstruction(t *testing.T) {
	shell := sessionInstruction(true)
	for _, want := range []string{"shared shell", "Ctrl-D", "exit", "stop sharing"} {
		if !strings.Contains(shell, want) {
			t.Fatalf("shell instruction %q missing %q", shell, want)
		}
	}

	cmd := sessionInstruction(false)
	for _, want := range []string{"command", "exits", "sharing stops"} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("command instruction %q missing %q", cmd, want)
		}
	}
	if strings.Contains(cmd, "shared shell") {
		t.Fatalf("command instruction should not claim shell mode: %q", cmd)
	}
}

func TestSessionActiveAndStoppedText(t *testing.T) {
	shell := sessionActiveText([]string{"/bin/zsh"}, true)
	for _, want := range []string{"ACTIVE", "shell", "shared"} {
		if !strings.Contains(shell, want) {
			t.Fatalf("shell active text %q missing %q", shell, want)
		}
	}

	cmd := sessionActiveText([]string{"top", "-o", "cpu"}, false)
	for _, want := range []string{"ACTIVE", "running: top -o cpu"} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("command active text %q missing %q", cmd, want)
		}
	}

	stopped := sessionStoppedText(7)
	for _, want := range []string{"sharing stopped", "Browser viewers are disconnected", "Exit code: 7"} {
		if !strings.Contains(stopped, want) {
			t.Fatalf("stopped text %q missing %q", stopped, want)
		}
	}
}
