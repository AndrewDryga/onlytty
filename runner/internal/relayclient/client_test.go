package relayclient

import (
	"net/http"
	"strings"
	"testing"
)

func TestViewerURL(t *testing.T) {
	c, err := New("https://relay.example.com", false)
	if err != nil {
		t.Fatal(err)
	}
	// The secret goes in the fragment verbatim (base64url chars are URL-safe and must
	// not be escaped); the relay never sees it.
	if got, want := c.ViewerURL("s7Qb3kZ9", "ab-_CD12xyz", false), "https://relay.example.com/s/s7Qb3kZ9#ab-_CD12xyz"; got != want {
		t.Fatalf("ViewerURL = %q, want %q", got, want)
	}
	// A passphrase is flagged with a trailing ".p".
	if got, want := c.ViewerURL("s7Qb3kZ9", "ab-_CD12xyz", true), "https://relay.example.com/s/s7Qb3kZ9#ab-_CD12xyz.p"; got != want {
		t.Fatalf("ViewerURL(pass) = %q, want %q", got, want)
	}
}

func TestNewValidation(t *testing.T) {
	for _, bad := range []string{"", "ftp://x", "not a url", "https://"} {
		if _, err := New(bad, false); err == nil {
			t.Errorf("New(%q) should error", bad)
		}
	}
	for _, ok := range []string{"http://localhost:4000", "https://relay.example.com"} {
		if _, err := New(ok, false); err != nil {
			t.Errorf("New(%q) unexpected error: %v", ok, err)
		}
	}
}

func TestSchemelessServerError(t *testing.T) {
	_, err := New("localhost:4000", false)
	if err == nil {
		t.Fatal("scheme-less --server should error")
	}
	if !strings.Contains(err.Error(), "localhost:4000") || !strings.Contains(err.Error(), "http://localhost:4000") {
		t.Fatalf("error should name the input and suggest http://: %v", err)
	}
	// Non-http schemes are still rejected (without the http:// suggestion).
	if _, err := New("ftp://x", false); err == nil {
		t.Error("ftp:// should error")
	}
}

func TestNonLocalHTTPGate(t *testing.T) {
	// Loopback http and any https are fine.
	for _, ok := range []string{"http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000", "https://relay.example.com"} {
		if _, err := New(ok, false); err != nil {
			t.Errorf("New(%q, false) unexpected error: %v", ok, err)
		}
	}
	// Plain http to a non-local host is refused by default…
	if _, err := New("http://relay.example.com", false); err == nil {
		t.Error("non-local http should be refused by default")
	}
	// …but allowed with the explicit escape hatch.
	if _, err := New("http://relay.example.com", true); err != nil {
		t.Errorf("non-local http with allowInsecure should pass: %v", err)
	}
}

func TestFatalDialError(t *testing.T) {
	if (&FatalDialError{Status: http.StatusUnauthorized}).Error() == "" {
		t.Fatal("401 error should have a message")
	}
	if (&FatalDialError{Status: http.StatusNotFound}).Error() == "" {
		t.Fatal("404 error should have a message")
	}
}
