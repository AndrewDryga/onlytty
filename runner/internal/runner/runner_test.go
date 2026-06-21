package runner

import (
	"context"
	"io"
	"os"
	"testing"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/protocol"
	"github.com/AndrewDryga/onlytty/runner/internal/ptysession"
	"github.com/AndrewDryga/onlytty/runner/internal/relayclient"
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

// Taking and releasing control both notify the host, and each notice carries the
// current screen-busy state: idle → the renderer shows it; while the child draws its
// own UI → busy, so the renderer stays silent.
func TestControlNotifiesHostWithScreenState(t *testing.T) {
	o, v2r, _ := newTestOrch(t, ControlAsk)

	var busy []bool
	o.notify = func(_ string, b bool) { busy = append(busy, b) }

	o.handleBinary(seal(t, v2r, 1, protocol.KindCtrlReq, nil)) // take
	o.handleBinary(seal(t, v2r, 2, protocol.KindCtrlRel, nil)) // release
	if len(busy) != 2 || busy[0] || busy[1] {
		t.Fatalf("idle screen: take+release should each notify as not-busy, got %+v", busy)
	}

	// Once the child is drawing its own UI, the next control notice reports busy.
	o.markScreenActivity([]byte("\x1b[2J\x1b[H"))
	o.handleBinary(seal(t, v2r, 3, protocol.KindCtrlReq, nil))
	if len(busy) != 3 || !busy[2] {
		t.Fatalf("busy screen: control notice should report screen busy, got %+v", busy)
	}
}

// screenBusy must stay false for plain/colored scrolling output (safe to draw a notice
// after) and flip true while the child draws its own UI — a bare CR line rewrite, cursor
// or erase moves, or the alternate screen — so notices don't corrupt it.
func TestScreenBusyDetection(t *testing.T) {
	o, _, _ := newTestOrch(t, ControlAsk)

	// Plain text + SGR color is not screen-owning.
	o.markScreenActivity([]byte("hello \x1b[31mred\x1b[0m world\n"))
	if o.screenBusy() {
		t.Fatal("plain/colored output should not mark the screen busy")
	}

	// A bare CR (in-place line rewrite, e.g. a progress bar) is screen-owning.
	o.markScreenActivity([]byte("downloading 50%\r"))
	if !o.screenBusy() {
		t.Fatal("bare CR should mark the screen busy")
	}

	// Once the drawing stops for longer than the window, it is safe again.
	o.lastCtl.Store(time.Now().Add(-2 * screenBusyWindow).UnixNano())
	if o.screenBusy() {
		t.Fatal("after the busy window with no drawing, should be safe")
	}

	// Cursor movement / erase is screen-owning.
	o.markScreenActivity([]byte("\x1b[3A\x1b[2Kredraw"))
	if !o.screenBusy() {
		t.Fatal("cursor/erase output should mark the screen busy")
	}

	// The alternate screen stays busy regardless of the timer, until it is left.
	o.markScreenActivity([]byte("\x1b[?1049h"))
	o.lastCtl.Store(time.Now().Add(-2 * screenBusyWindow).UnixNano())
	if !o.screenBusy() {
		t.Fatal("alternate screen should stay busy regardless of the timer")
	}
	o.markScreenActivity([]byte("\x1b[?1049l"))
	o.lastCtl.Store(time.Now().Add(-2 * screenBusyWindow).UnixNano())
	if o.screenBusy() {
		t.Fatal("after leaving the alternate screen and idling, should be safe")
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

// On command exit the runner emits the encrypted EXIT frame AND a plaintext `bye`
// text frame, so a viewer that missed EXIT still transitions to a terminal state
// instead of hanging on "runner disconnected".
func TestExitSignalsByeTextFrame(t *testing.T) {
	o, _, _ := newTestOrch(t, ControlAsk)
	c := withConn(o)

	o.signalExit()

	select {
	case m := <-c.send:
		if m.text || m.kind != protocol.KindExit {
			t.Fatalf("first frame: got text=%v kind=%d, want a sealed EXIT", m.text, m.kind)
		}
	default:
		t.Fatal("no EXIT frame emitted on exit")
	}

	select {
	case m := <-c.send:
		if !m.text || string(m.payload) != `{"t":"bye","reason":"ended"}` {
			t.Fatalf("second frame: got text=%v payload=%q, want the bye text frame", m.text, m.payload)
		}
	default:
		t.Fatal("no plaintext bye frame emitted on exit")
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

// runOrch builds an Orchestrator over argv with a client pointed at an unreachable
// relay (so connectLoop just backs off) and runs it; returns a channel of the exit code.
func runOrch(t *testing.T, ctx context.Context, argv []string) (*ptysession.Session, <-chan int) {
	t.Helper()
	ps, err := ptysession.Start(argv, os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	_ = ps.SetSize(80, 24)

	keys, err := protocol.DeriveKeys(make([]byte, protocol.SecretLen), "sess", "")
	if err != nil {
		t.Fatal(err)
	}
	client, err := relayclient.New("http://127.0.0.1:1", true) // refused → transient, backs off
	if err != nil {
		t.Fatal(err)
	}
	pr, _ := io.Pipe() // localIn: blocks like an idle stdin (never written/closed)
	o, err := New(Config{
		Session: ps, Keys: keys, SessionID: "sess", Client: client,
		LocalIn: pr, LocalOut: io.Discard,
	})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	go func() { done <- o.Run(ctx) }()
	return ps, done
}

// A parent cancel (SIGTERM/SIGHUP) must tear down the PTY so Run returns promptly,
// even with a long-running child that won't exit on its own — otherwise pumpOutput
// blocks on the PTY read forever and wg.Wait hangs.
func TestRunReturnsOnCancelWithLongChild(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	_, done := runOrch(t, ctx, []string{"sleep", "60"})

	time.Sleep(150 * time.Millisecond) // let Run spin up its goroutines
	cancel()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return within 5s of cancel — PTY teardown hung")
	}
}

// Normal command-exit teardown still works: a child that exits on its own ends Run.
func TestRunReturnsOnChildExit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_, done := runOrch(t, ctx, []string{"true"})

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after the child exited")
	}
}
