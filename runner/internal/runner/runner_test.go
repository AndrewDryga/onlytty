package runner

import (
	"os"
	"testing"

	"github.com/AndrewDryga/onlytty/runner/internal/protocol"
	"github.com/AndrewDryga/onlytty/runner/internal/ptysession"
)

// newTestOrch builds an Orchestrator over a real PTY running `cat`, plus the viewer's
// v2r cipher to seal frames as a viewer (or the relay) would.
func newTestOrch(t *testing.T, mode ControlMode) (*Orchestrator, *protocol.Cipher, *ptysession.Session) {
	t.Helper()
	ps, err := ptysession.Start([]string{"cat"}, os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ps.Close() })
	_ = ps.SetSize(80, 24)

	keys, err := protocol.DeriveKeys(make([]byte, protocol.SecretLen), "sess", "")
	if err != nil {
		t.Fatal(err)
	}
	o, err := New(Config{Session: ps, Keys: keys, SessionID: "sess", Control: mode})
	if err != nil {
		t.Fatal(err)
	}
	v2r, err := protocol.NewCipher(keys.V2R, []byte("sess"))
	if err != nil {
		t.Fatal(err)
	}
	return o, v2r, ps
}

func seal(t *testing.T, c *protocol.Cipher, seq uint64, kind byte, payload []byte) []byte {
	t.Helper()
	f, err := c.Seal(seq, kind, payload)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

// A resize from a viewer that does not hold control must be ignored (it would
// otherwise SIGWINCH the host — a write-side effect a read-only viewer must not have).
func TestResizeRequiresControl(t *testing.T) {
	o, v2r, ps := newTestOrch(t, ControlAsk)

	o.handleBinary(seal(t, v2r, 1, protocol.KindResize, protocol.EncodeResize(120, 40)))
	if c, r := ps.Size(); c == 120 || r == 40 {
		t.Fatalf("resize applied without control: %dx%d", c, r)
	}

	o.granted.Store(true)
	o.handleBinary(seal(t, v2r, 2, protocol.KindResize, protocol.EncodeResize(120, 40)))
	if c, r := ps.Size(); c != 120 || r != 40 {
		t.Fatalf("resize not applied with control: %dx%d", c, r)
	}
}

// A read-only session must never grant control, even when asked.
func TestReadOnlyNeverGrantsControl(t *testing.T) {
	ro, v2r, _ := newTestOrch(t, ControlViewOnly)
	ro.handleBinary(seal(t, v2r, 1, protocol.KindCtrlReq, nil))
	if ro.granted.Load() {
		t.Fatal("read-only session granted control")
	}

	rw, v2r2, _ := newTestOrch(t, ControlAsk)
	rw.handleBinary(seal(t, v2r2, 1, protocol.KindCtrlReq, nil))
	if !rw.granted.Load() {
		t.Fatal("writable session did not grant control on request")
	}
}

// The session-long seq floor must reject a replayed (or stale) frame — the defense
// against a relay re-running a viewer's past keystrokes.
func TestReplayRejected(t *testing.T) {
	o, v2r, ps := newTestOrch(t, ControlAsk)
	o.granted.Store(true)

	o.handleBinary(seal(t, v2r, 5, protocol.KindResize, protocol.EncodeResize(100, 30)))
	if c, _ := ps.Size(); c != 100 {
		t.Fatalf("first resize not applied: %d", c)
	}
	// Replaying seq 5 (and any seq <= the floor) must be dropped.
	o.handleBinary(seal(t, v2r, 5, protocol.KindResize, protocol.EncodeResize(150, 50)))
	o.handleBinary(seal(t, v2r, 4, protocol.KindResize, protocol.EncodeResize(160, 60)))
	if c, _ := ps.Size(); c != 100 {
		t.Fatalf("replayed/stale resize was applied: %d", c)
	}
	// A higher seq is still accepted.
	o.handleBinary(seal(t, v2r, 6, protocol.KindResize, protocol.EncodeResize(200, 50)))
	if c, _ := ps.Size(); c != 200 {
		t.Fatalf("fresh resize not applied: %d", c)
	}
}

// withConn attaches a buffered viewer connection so emitted control frames are observable.
func withConn(o *Orchestrator) *connState {
	c := &connState{send: make(chan outMsg, 8), done: make(chan struct{})}
	o.connMu.Lock()
	o.conn = c
	o.connMu.Unlock()
	return c
}

// assertControl reads the next queued control frame and checks its state byte.
func assertControl(t *testing.T, c *connState, want byte) {
	t.Helper()
	select {
	case m := <-c.send:
		if m.kind != protocol.KindControl || len(m.payload) != 1 || m.payload[0] != want {
			t.Fatalf("got kind=%d payload=%v, want control state %d", m.kind, m.payload, want)
		}
	default:
		t.Fatal("no control frame emitted")
	}
}

// ControlOnce grants the first request, then denies every later one — even after the
// viewer releases (or, by the same onceUsed latch, reconnects).
func TestControlOnceGrantsThenDenies(t *testing.T) {
	o, v2r, _ := newTestOrch(t, ControlOnce)
	c := withConn(o)

	o.handleBinary(seal(t, v2r, 1, protocol.KindCtrlReq, nil))
	if !o.granted.Load() {
		t.Fatal("once: first request was not granted")
	}
	assertControl(t, c, protocol.ControlGranted)

	o.handleBinary(seal(t, v2r, 2, protocol.KindCtrlRel, nil))
	if o.granted.Load() {
		t.Fatal("once: still granted after release")
	}
	assertControl(t, c, protocol.ControlReadOnly)

	o.handleBinary(seal(t, v2r, 3, protocol.KindCtrlReq, nil))
	if o.granted.Load() {
		t.Fatal("once: re-granted after the one-time grant was used")
	}
	assertControl(t, c, protocol.ControlReadOnly)
}

// Revoke takes control back: it clears the grant and tells the viewer it is read-only;
// a second revoke with nobody in control is a silent no-op.
func TestRevokeTakesControlBack(t *testing.T) {
	o, _, _ := newTestOrch(t, ControlAsk)
	c := withConn(o)
	o.granted.Store(true)

	o.Revoke()
	if o.granted.Load() {
		t.Fatal("revoke did not clear the grant")
	}
	assertControl(t, c, protocol.ControlReadOnly)

	o.Revoke()
	select {
	case m := <-c.send:
		t.Fatalf("revoke with no grant still emitted %v", m)
	default:
	}
}
