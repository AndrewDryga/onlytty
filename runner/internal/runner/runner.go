// Package runner wires a PTY session to the relay: it mirrors the command to the
// local terminal, streams an end-to-end-encrypted copy to a viewer, pumps the
// viewer's input back, and survives reconnects. The relay only ever sees ciphertext.
package runner

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/protocol"
	"github.com/AndrewDryga/onlytty/runner/internal/ptysession"
	"github.com/AndrewDryga/onlytty/runner/internal/relayclient"
	"github.com/coder/websocket"
)

const (
	ringBytes      = 256 * 1024
	sendQueue      = 256
	writeTimeout   = 10 * time.Second
	keepalivePulse = 30 * time.Second
	exitFlush      = 250 * time.Millisecond
	maxBackoff     = 15 * time.Second
)

// Config wires an Orchestrator. LocalIn/LocalOut are the user's terminal; Notify
// receives short human notices (viewer connect/disconnect/control): alert marks a
// security-relevant one (a viewer took control), and screenBusy is true when the child
// is drawing its own UI, so the terminal layer can stay quiet (or just bell) instead of
// corrupting it; both LocalOut and Notify may be nil.
// ControlMode is the host's policy for viewer control requests.
type ControlMode int

const (
	// ControlAsk grants control on every request — the default, for the
	// "my phone drives my own shell" case.
	ControlAsk ControlMode = iota
	// ControlViewOnly never grants control; viewers may only watch.
	ControlViewOnly
	// ControlOnce grants the first request, then denies later ones once that grant
	// has been released or the viewer disconnected.
	ControlOnce
)

type Config struct {
	Client      *relayclient.Client
	Session     *ptysession.Session
	Keys        protocol.Keys
	SessionID   string
	Token       string
	Control     ControlMode
	LocalIn     io.Reader
	LocalOut    io.Writer
	Notify      func(msg string, alert, screenBusy bool)
	Fingerprint string
}

// Orchestrator runs the relay side of a session for the life of the command.
type Orchestrator struct {
	client   *relayclient.Client
	sess     *ptysession.Session
	id, tok  string
	control  ControlMode
	r2v, v2r *protocol.Cipher
	ring     *ptysession.Ring
	localIn  io.Reader
	localOut io.Writer
	notify   func(string, bool, bool)
	fp       string

	sendMu sync.Mutex // serializes outSeq + seal
	outSeq uint64
	inSeq  atomic.Uint64 // viewer→runner replay floor, session-long

	granted  atomic.Bool
	onceUsed atomic.Bool // ControlOnce: the one-time grant has been consumed
	viewers  atomic.Int32

	altScreen atomic.Bool  // child is in the alternate screen buffer (vim/htop/less/…)
	lastCtl   atomic.Int64 // unixnano of the child's last cursor/line-control output

	connMu sync.Mutex
	conn   *connState
}

type outMsg struct {
	kind    byte
	payload []byte
}

type connState struct {
	ws      *websocket.Conn
	send    chan outMsg
	join    chan struct{}
	done    chan struct{}
	once    sync.Once
	dropped atomic.Bool
}

func (c *connState) fail() { c.once.Do(func() { close(c.done) }) }

// New builds an Orchestrator, deriving the directional ciphers from the keys.
func New(cfg Config) (*Orchestrator, error) {
	r2v, err := protocol.NewCipher(cfg.Keys.R2V, []byte(cfg.SessionID))
	if err != nil {
		return nil, err
	}
	v2r, err := protocol.NewCipher(cfg.Keys.V2R, []byte(cfg.SessionID))
	if err != nil {
		return nil, err
	}
	return &Orchestrator{
		client: cfg.Client, sess: cfg.Session, id: cfg.SessionID, tok: cfg.Token,
		control: cfg.Control, r2v: r2v, v2r: v2r,
		ring:     ptysession.NewRing(ringBytes),
		localIn:  cfg.LocalIn,
		localOut: cfg.LocalOut,
		notify:   cfg.Notify,
		fp:       cfg.Fingerprint,
	}, nil
}

// Run executes the session until the command exits (or parent is cancelled) and
// returns the command's exit code. The command runs and mirrors locally even if the
// relay is unreachable.
func (o *Orchestrator) Run(parent context.Context) int {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	// Exit watcher: when the command exits, tell the viewer, then tear down. EXIT is
	// queued unconditionally (emit no-ops if no viewer is connected) and given a brief
	// flush window before teardown — best-effort, since the relay/TTL ends it anyway.
	go func() {
		_ = o.sess.Wait()
		o.emit(protocol.KindExit, protocol.EncodeExit(int32(o.sess.ExitCode())))
		time.Sleep(exitFlush)
		cancel()
		_ = o.sess.Close() // unblocks pumpOutput
	}()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); o.pumpOutput() }()
	go o.pumpInput() // blocks on stdin; the process exits regardless
	go o.keepalive(ctx)

	o.connectLoop(ctx)
	wg.Wait()
	return o.sess.ExitCode()
}

// Resize applies a local terminal resize and tells the viewer the new size.
func (o *Orchestrator) Resize(cols, rows uint16) {
	_ = o.sess.SetSize(cols, rows)
	if o.viewers.Load() > 0 {
		c, r := o.sess.Size()
		o.emit(protocol.KindHello, protocol.EncodeHello(o.inSeq.Load()+1, c, r))
	}
}

// pumpOutput fans PTY output to the local terminal, the resume ring, and (when a
// viewer is present) the relay. Local mirroring never waits on the network.
func (o *Orchestrator) pumpOutput() {
	buf := make([]byte, 32*1024)
	for {
		n, err := o.sess.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			o.markScreenActivity(chunk)
			if o.localOut != nil {
				_, _ = o.localOut.Write(chunk)
			}
			_, _ = o.ring.Write(chunk)
			if o.viewers.Load() > 0 {
				o.emit(protocol.KindOutput, chunk)
			}
		}
		if err != nil {
			return
		}
	}
}

// pumpInput copies local keystrokes into the command. The local terminal always has
// control; the viewer's input is merged separately in handleBinary.
func (o *Orchestrator) pumpInput() {
	if o.localIn == nil {
		return
	}
	buf := make([]byte, 32*1024)
	for {
		n, err := o.localIn.Read(buf)
		if n > 0 {
			_, _ = o.sess.Write(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

// keepalive pulses a HELLO so the relay's idle timer sees a live runner. A dead
// runner sends nothing and is reaped; the TTL still bounds total lifetime.
func (o *Orchestrator) keepalive(ctx context.Context) {
	t := time.NewTicker(keepalivePulse)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c, r := o.sess.Size()
			o.emit(protocol.KindHello, protocol.EncodeHello(o.inSeq.Load()+1, c, r))
		}
	}
}

// emit queues a message for the current viewer connection. It never blocks the
// caller: if the queue is full the frame is dropped and a repaint is scheduled, so
// local mirroring is never held up by a slow viewer.
func (o *Orchestrator) emit(kind byte, payload []byte) {
	o.connMu.Lock()
	c := o.conn
	o.connMu.Unlock()
	if c == nil {
		return
	}
	cp := append([]byte(nil), payload...)
	select {
	case c.send <- outMsg{kind, cp}:
	case <-c.done:
	default:
		c.dropped.Store(true)
	}
}

// connectLoop keeps a runner WebSocket up, reconnecting with backoff. A fatal
// rejection (expired session / bad token) stops relaying but leaves the command
// running locally.
func (o *Orchestrator) connectLoop(ctx context.Context) {
	backoff := 500 * time.Millisecond
	for ctx.Err() == nil {
		conn, err := o.client.DialRunner(ctx, o.id, o.tok)
		if err != nil {
			var fatal *relayclient.FatalDialError
			if errors.As(err, &fatal) {
				o.note("onlytty: " + fatal.Error() + " — sharing stopped (command still running locally)")
				return
			}
			if ctx.Err() != nil {
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, maxBackoff)
			continue
		}
		backoff = 500 * time.Millisecond
		o.serveConn(ctx, conn)
	}
}

// serveConn runs one WebSocket connection: a reader and a sender, with the
// single-sender invariant preserved across reconnects.
func (o *Orchestrator) serveConn(ctx context.Context, conn *websocket.Conn) {
	c := &connState{
		ws:   conn,
		send: make(chan outMsg, sendQueue),
		join: make(chan struct{}, 1),
		done: make(chan struct{}),
	}
	o.connMu.Lock()
	o.conn = c
	o.connMu.Unlock()

	var swg sync.WaitGroup
	swg.Add(1)
	go func() { defer swg.Done(); o.sender(ctx, c) }()

	o.reader(ctx, c) // blocks until the connection fails or ctx is done
	c.fail()

	o.connMu.Lock()
	if o.conn == c {
		o.conn = nil
	}
	o.connMu.Unlock()
	conn.CloseNow()
	swg.Wait()
	o.viewers.Store(0)
	o.granted.Store(false)
}

// reader consumes relay control (text) and viewer payload (binary) frames.
func (o *Orchestrator) reader(ctx context.Context, c *connState) {
	for {
		typ, data, err := c.ws.Read(ctx)
		if err != nil {
			return
		}
		switch typ {
		case websocket.MessageText:
			o.handleControl(c, data)
		case websocket.MessageBinary:
			o.handleBinary(data)
		}
	}
}

// sender owns all writes to one connection, so the output sequence is monotonic.
func (o *Orchestrator) sender(ctx context.Context, c *connState) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.done:
			return
		case <-c.join:
			if o.sendRepaint(ctx, c) != nil {
				c.fail()
				return
			}
		case m := <-c.send:
			if c.dropped.Swap(false) {
				if o.sendRepaint(ctx, c) != nil {
					c.fail()
					return
				}
			}
			if o.writeMsg(ctx, c, m.kind, m.payload) != nil {
				c.fail()
				return
			}
		}
	}
}

// sendRepaint brings a joining or resynced viewer up to date: size + seq baseline,
// a terminal reset, the recent output, and the current control state.
func (o *Orchestrator) sendRepaint(ctx context.Context, c *connState) error {
	cols, rows := o.sess.Size()
	if err := o.writeMsg(ctx, c, protocol.KindHello, protocol.EncodeHello(o.inSeq.Load()+1, cols, rows)); err != nil {
		return err
	}
	repaint := append([]byte("\x1bc"), o.ring.Snapshot()...) // RIS reset, then replay
	if err := o.writeMsg(ctx, c, protocol.KindOutput, repaint); err != nil {
		return err
	}
	state := protocol.ControlReadOnly
	if o.granted.Load() {
		state = protocol.ControlGranted
	}
	return o.writeMsg(ctx, c, protocol.KindControl, []byte{state})
}

// writeMsg seals one message and writes it. Only the sender goroutine calls this, so
// outSeq is monotonic; sendMu is defensive.
func (o *Orchestrator) writeMsg(ctx context.Context, c *connState, kind byte, payload []byte) error {
	o.sendMu.Lock()
	o.outSeq++
	seq := o.outSeq
	o.sendMu.Unlock()
	frame, err := o.r2v.Seal(seq, kind, payload)
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return c.ws.Write(wctx, websocket.MessageBinary, frame)
}

func (o *Orchestrator) handleControl(c *connState, data []byte) {
	var m struct {
		T       string `json:"t"`
		Viewers int    `json:"viewers"`
	}
	if json.Unmarshal(data, &m) != nil {
		return
	}
	switch m.T {
	case "hello":
		o.viewers.Store(int32(m.Viewers))
		if m.Viewers > 0 {
			signal(c.join)
		}
	case "peer_join":
		o.viewers.Store(1)
		o.note("onlytty: viewer connected · fingerprint " + o.fp)
		signal(c.join)
	case "peer_left":
		o.viewers.Store(0)
		o.granted.Store(false)
		o.note("onlytty: viewer disconnected")
	case "busy":
		o.note("onlytty: a viewer is already connected (single-viewer lock)")
	case "bye":
		o.note("onlytty: session closed by the relay")
	}
}

func (o *Orchestrator) handleBinary(frame []byte) {
	seq, kind, payload, err := o.v2r.Open(frame)
	if err != nil {
		return // unauthenticated — drop
	}
	for { // replay protection: strictly increasing seq, session-long
		cur := o.inSeq.Load()
		if seq <= cur {
			return
		}
		if o.inSeq.CompareAndSwap(cur, seq) {
			break
		}
	}
	switch kind {
	case protocol.KindInput:
		if o.granted.Load() {
			_, _ = o.sess.Write(payload)
		}
	case protocol.KindResize:
		// Resizing the host PTY is a write-side effect (it SIGWINCHes the command),
		// so it is gated exactly like input: only a viewer that holds control may do
		// it. A read-only viewer sizes its own xterm to the host instead.
		if o.granted.Load() {
			if cols, rows, err := protocol.DecodeResize(payload); err == nil {
				_ = o.sess.SetSize(cols, rows)
			}
		}
	case protocol.KindCtrlReq:
		if o.control == ControlViewOnly || (o.control == ControlOnce && o.onceUsed.Load()) {
			o.emit(protocol.KindControl, []byte{protocol.ControlReadOnly})
		} else {
			if o.control == ControlOnce {
				o.onceUsed.Store(true)
			}
			o.granted.Store(true)
			o.emit(protocol.KindControl, []byte{protocol.ControlGranted})
			o.alert("onlytty: viewer took control")
		}
	case protocol.KindCtrlRel:
		o.granted.Store(false)
		o.emit(protocol.KindControl, []byte{protocol.ControlReadOnly})
		o.note("onlytty: viewer released control")
	}
}

// note delivers a routine notice; alert marks a security-relevant one (a viewer took
// control). screenBusy tells the terminal layer whether the child is currently drawing
// its own UI, so it can stay quiet (or just bell) instead of corrupting it. All are
// no-ops when no notifier is wired.
func (o *Orchestrator) note(s string)  { o.emitNote(s, false) }
func (o *Orchestrator) alert(s string) { o.emitNote(s, true) }

func (o *Orchestrator) emitNote(s string, alert bool) {
	if o.notify != nil {
		o.notify(s, alert, o.screenBusy())
	}
}

// screenBusyWindow is how long after the child's last cursor/line-drawing output we
// keep treating the screen as "busy" — unsafe to inject host notices into.
const screenBusyWindow = 1500 * time.Millisecond

// markScreenActivity scans a chunk of the child's output for terminal control meaning
// the program is drawing its own UI: alternate-screen toggles and cursor/erase moves
// (NOT color/SGR or plain text). It tracks the alt-screen state and the time of the
// last such control, so notices can avoid corrupting an app that owns the screen —
// including normal-buffer apps like Claude Code that repaint with cursor moves.
func (o *Orchestrator) markScreenActivity(p []byte) {
	ctl := false
	for i := 0; i < len(p); i++ {
		b := p[i]
		if b == '\r' { // a bare CR rewrites the line in place; CRLF is just a newline
			if i+1 >= len(p) || p[i+1] != '\n' {
				ctl = true
			}
			continue
		}
		if b != 0x1b || i+1 >= len(p) || p[i+1] != '[' { // only CSI (ESC [ …) interests us
			continue
		}
		j := i + 2
		priv := j < len(p) && (p[j] == '?' || p[j] == '>' || p[j] == '!')
		if priv {
			j++
		}
		start := j
		for j < len(p) && (p[j] >= '0' && p[j] <= '9' || p[j] == ';') {
			j++
		}
		if j >= len(p) {
			break // sequence crosses the chunk boundary — ignore (re-asserted next chunk)
		}
		switch final := p[j]; {
		case priv && (final == 'h' || final == 'l'):
			switch string(p[start:j]) { // alternate-screen enter/leave
			case "1049", "47", "1047":
				o.altScreen.Store(final == 'h')
			}
			ctl = true // any private-mode toggle (incl. cursor hide/show) means active UI
		case !priv && isCursorControl(final):
			ctl = true
		}
		i = j
	}
	if ctl {
		o.lastCtl.Store(time.Now().UnixNano())
	}
}

// isCursorControl reports whether a CSI final byte moves the cursor or erases — the
// screen-owning operations. SGR/color ('m') and the rest are deliberately excluded.
func isCursorControl(final byte) bool {
	switch final {
	case 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'f', 'd', 'J', 'K', 'S', 'T', 's', 'u':
		return true
	}
	return false
}

// screenBusy reports whether the child likely owns the screen right now: it is in the
// alternate buffer, or it drew with the cursor within screenBusyWindow. When busy, host
// notices stay quiet (a bell still flags a control grant) rather than corrupt the UI.
func (o *Orchestrator) screenBusy() bool {
	if o.altScreen.Load() {
		return true
	}
	last := o.lastCtl.Load()
	return last != 0 && time.Since(time.Unix(0, last)) < screenBusyWindow
}

// Revoke takes control back from the viewer: it clears the grant, tells the viewer
// it is read-only again, and notes it. Safe to call from any goroutine (e.g. a signal
// handler); a no-op when no viewer currently holds control.
func (o *Orchestrator) Revoke() {
	if o.granted.CompareAndSwap(true, false) {
		o.emit(protocol.KindControl, []byte{protocol.ControlReadOnly})
		o.note("onlytty: host revoked control")
	}
}

func signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}
