package ptysession

import (
	"bytes"
	"testing"
	"unicode/utf8"
)

func TestRingUnderCapacity(t *testing.T) {
	r := NewRing(100)
	r.Write([]byte("hello "))
	r.Write([]byte("world"))
	if got := r.Snapshot(); !bytes.Equal(got, []byte("hello world")) {
		t.Fatalf("got %q", got)
	}
}

func TestRingDropsOldest(t *testing.T) {
	r := NewRing(5)
	r.Write([]byte("abc"))
	r.Write([]byte("defgh")) // total "abcdefgh" -> keep last 5 "defgh"
	if got := r.Snapshot(); !bytes.Equal(got, []byte("defgh")) {
		t.Fatalf("got %q, want defgh", got)
	}
	r.Write([]byte("ij")) // "defghij" -> "ghij"... last 5 = "fghij"? "defgh"+"ij"="defghij" keep last5 "fghij"
	if got := r.Snapshot(); !bytes.Equal(got, []byte("fghij")) {
		t.Fatalf("got %q, want fghij", got)
	}
}

func TestRingWriteLargerThanCapacity(t *testing.T) {
	r := NewRing(4)
	r.Write([]byte("abcdefghij")) // keep last 4 "ghij"
	if got := r.Snapshot(); !bytes.Equal(got, []byte("ghij")) {
		t.Fatalf("got %q, want ghij", got)
	}
}

func TestRingSnapshotAlignsRuneBoundary(t *testing.T) {
	// "€" is 3 bytes (0xE2 0x82 0xAC). Capacity 4 trims "ab€cd" (7 bytes) to the
	// last 4 = [0x82 0xAC 'c' 'd'], slicing into the € rune. The snapshot must skip
	// the orphaned continuation bytes so a repaint starts on a rune boundary.
	r := NewRing(4)
	r.Write([]byte("ab€cd"))
	got := r.Snapshot()
	if !bytes.Equal(got, []byte("cd")) {
		t.Fatalf("got %q, want cd", got)
	}
	if !utf8.Valid(got) {
		t.Fatalf("snapshot is not valid UTF-8: %x", got)
	}
}

func TestRingSnapshotKeepsWholeRune(t *testing.T) {
	// When the trim lands exactly on a rune boundary, the whole rune is retained.
	r := NewRing(5)
	r.Write([]byte("ab€cd")) // keep last 5 = "€cd"
	if got := r.Snapshot(); !bytes.Equal(got, []byte("€cd")) {
		t.Fatalf("got %q, want €cd", got)
	}
}

func TestRingSnapshotIsCopy(t *testing.T) {
	r := NewRing(10)
	r.Write([]byte("data"))
	s := r.Snapshot()
	s[0] = 'X'
	if got := r.Snapshot(); !bytes.Equal(got, []byte("data")) {
		t.Fatalf("snapshot must be a copy; ring mutated to %q", got)
	}
}
