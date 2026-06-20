package ptysession

import (
	"bytes"
	"testing"
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

func TestRingSnapshotIsCopy(t *testing.T) {
	r := NewRing(10)
	r.Write([]byte("data"))
	s := r.Snapshot()
	s[0] = 'X'
	if got := r.Snapshot(); !bytes.Equal(got, []byte("data")) {
		t.Fatalf("snapshot must be a copy; ring mutated to %q", got)
	}
}
