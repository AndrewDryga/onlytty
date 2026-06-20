package relayclient

import (
	"net/http"
	"strings"
	"testing"
)

func TestViewerURL(t *testing.T) {
	c, err := New("https://relay.example.com")
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
		if _, err := New(bad); err == nil {
			t.Errorf("New(%q) should error", bad)
		}
	}
	for _, ok := range []string{"http://localhost:4000", "https://relay.example.com"} {
		if _, err := New(ok); err != nil {
			t.Errorf("New(%q) unexpected error: %v", ok, err)
		}
	}
}

func TestSchemelessServerError(t *testing.T) {
	_, err := New("localhost:4000")
	if err == nil {
		t.Fatal("scheme-less --server should error")
	}
	if !strings.Contains(err.Error(), "localhost:4000") || !strings.Contains(err.Error(), "http://localhost:4000") {
		t.Fatalf("error should name the input and suggest http://: %v", err)
	}
	// Non-http schemes are still rejected (without the http:// suggestion).
	if _, err := New("ftp://x"); err == nil {
		t.Error("ftp:// should error")
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
