package ptysession

import "sync"

// Ring keeps the most recent bytes written to it, bounded to a fixed capacity. The
// runner feeds PTY output through it so a viewer that joins (or reconnects) can be
// repainted from recent history without the relay ever storing anything.
type Ring struct {
	mu  sync.Mutex
	buf []byte
	max int
}

// NewRing returns a Ring that retains at most max bytes.
func NewRing(max int) *Ring {
	if max < 1 {
		max = 1
	}
	return &Ring{max: max}
}

// Write appends p, dropping the oldest bytes beyond the capacity. It never errors
// and never blocks the caller for long: at most one in-place compaction per call.
func (r *Ring) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buf = append(r.buf, p...)
	if over := len(r.buf) - r.max; over > 0 {
		// Shift the retained tail to the front, reusing the backing array.
		r.buf = append(r.buf[:0], r.buf[over:]...)
	}
	return len(p), nil
}

// Snapshot returns a copy of the retained bytes, aligned to a UTF-8 rune boundary.
// The ring trims the oldest bytes at an arbitrary offset, so the retained head can
// begin in the middle of a multi-byte rune; a repaint that replayed those orphaned
// continuation bytes would show garbage glyphs at the top of the first screen. Skip
// any leading continuation bytes (0x80–0xBF) so the snapshot starts on a rune start.
func (r *Ring) Snapshot() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	start := 0
	for start < len(r.buf) && r.buf[start]&0xC0 == 0x80 {
		start++
	}
	out := make([]byte, len(r.buf)-start)
	copy(out, r.buf[start:])
	return out
}
