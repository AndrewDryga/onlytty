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

// Snapshot returns a copy of the retained bytes.
func (r *Ring) Snapshot() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]byte, len(r.buf))
	copy(out, r.buf)
	return out
}
