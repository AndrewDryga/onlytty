//go:build e2e

// End-to-end test: a programmatic viewer drives a real session through the real
// relay. It exercises pairing, the encrypted output/input loop, take-control, and
// exit. Run with `make e2e` (which boots the relay), or against a running relay:
//
//	RELAY_SERVER=http://127.0.0.1:4000 go test -tags e2e ./test/e2e/ -v
//
// The viewer here uses the Go protocol package, which is pinned byte-for-byte to the
// browser's web/crypto.js by the golden vectors — so it is a faithful stand-in.
package e2e

import (
	"context"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/relay/internal/protocol"
	"github.com/AndrewDryga/relay/internal/ptysession"
	"github.com/AndrewDryga/relay/internal/relayclient"
	"github.com/AndrewDryga/relay/internal/runner"
	"github.com/coder/websocket"
)

func serverBase() string {
	if v := os.Getenv("RELAY_SERVER"); v != "" {
		return v
	}
	return "http://127.0.0.1:4000"
}

// viewer is the browser's role, in Go: it decrypts runner→viewer frames and seals
// viewer→runner frames, starting its sequence at the baseline from HELLO.
type viewer struct {
	conn   *websocket.Conn
	open   *protocol.Cipher // r2v
	seal   *protocol.Cipher // v2r
	outSeq uint64
	out    strings.Builder
}

func (v *viewer) read(ctx context.Context) (byte, []byte, error) {
	for {
		typ, data, err := v.conn.Read(ctx)
		if err != nil {
			return 0, nil, err
		}
		if typ != websocket.MessageBinary {
			continue // skip relay control text
		}
		_, kind, payload, err := v.open.Open(data)
		if err != nil {
			return 0, nil, err
		}
		return kind, payload, nil
	}
}

func (v *viewer) send(ctx context.Context, kind byte, payload []byte) error {
	v.outSeq++
	frame, err := v.seal.Seal(v.outSeq, kind, payload)
	if err != nil {
		return err
	}
	return v.conn.Write(ctx, websocket.MessageBinary, frame)
}

func TestEndToEnd(t *testing.T) {
	base := serverBase()
	if _, err := http.Get(base + "/healthz"); err != nil {
		t.Skipf("relay not reachable at %s (%v) — run `make e2e`", base, err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	client, err := relayclient.New(base)
	if err != nil {
		t.Fatal(err)
	}
	sess, err := client.CreateSession(ctx, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	// Runner side: keys derived from a fresh secret, a PTY running `cat` (echoes input).
	secret := make([]byte, protocol.SecretLen)
	for i := range secret {
		secret[i] = byte(i * 7)
	}
	keys, err := protocol.DeriveKeys(secret, sess.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	psess, err := ptysession.Start([]string{"cat"}, os.Environ())
	if err != nil {
		t.Fatal(err)
	}
	_ = psess.SetSize(80, 24)
	orch, err := runner.New(runner.Config{
		Client: client, Session: psess, Keys: keys, SessionID: sess.ID, Token: sess.RunnerToken,
		LocalOut: nil, LocalIn: nil, // headless: the viewer drives everything
	})
	if err != nil {
		t.Fatal(err)
	}
	runDone := make(chan int, 1)
	go func() { runDone <- orch.Run(ctx) }()

	// Viewer side: connect to the relay as a browser would.
	wsBase := strings.Replace(base, "http", "ws", 1)
	conn, _, err := websocket.Dial(ctx, wsBase+"/ws/viewer/"+sess.ID, nil)
	if err != nil {
		t.Fatalf("viewer dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(2 << 20)

	openC, _ := protocol.NewCipher(keys.R2V, []byte(sess.ID))
	sealC, _ := protocol.NewCipher(keys.V2R, []byte(sess.ID))
	v := &viewer{conn: conn, open: openC, seal: sealC}

	// 1) Expect HELLO first; adopt the seq baseline.
	kind, payload, err := v.read(ctx)
	if err != nil {
		t.Fatalf("read hello: %v", err)
	}
	if kind != protocol.KindHello {
		t.Fatalf("first frame kind = %d, want HELLO", kind)
	}
	baseline, cols, rows, err := protocol.DecodeHello(payload)
	if err != nil {
		t.Fatal(err)
	}
	if cols != 80 || rows != 24 {
		t.Fatalf("hello size = %dx%d, want 80x24", cols, rows)
	}
	v.outSeq = baseline - 1 // next send() will use `baseline`

	// 2) Take control, then wait for the grant.
	if err := v.send(ctx, protocol.KindCtrlReq, nil); err != nil {
		t.Fatal(err)
	}
	if !waitFor(ctx, t, v, func() bool { return false }, protocol.KindControl, "control grant") {
		t.Fatal("never granted control")
	}

	// 3) Type a line; `cat` (and the tty echo) must reflect it back, decrypted.
	if err := v.send(ctx, protocol.KindInput, []byte("ping-123\n")); err != nil {
		t.Fatal(err)
	}
	if !waitFor(ctx, t, v, func() bool { return strings.Contains(v.out.String(), "ping-123") }, 0, "echo of typed line") {
		t.Fatalf("did not see echoed input; output so far: %q", v.out.String())
	}

	// 4) Send EOF; cat exits 0 and the runner reports EXIT.
	if err := v.send(ctx, protocol.KindInput, []byte{0x04}); err != nil {
		t.Fatal(err)
	}
	gotExit := false
	for !gotExit {
		kind, payload, err := v.read(ctx)
		if err != nil {
			t.Fatalf("waiting for EXIT: %v", err)
		}
		if kind == protocol.KindExit {
			code, _ := protocol.DecodeExit(payload)
			if code != 0 {
				t.Fatalf("exit code = %d, want 0", code)
			}
			gotExit = true
		}
	}

	select {
	case code := <-runDone:
		if code != 0 {
			t.Fatalf("orchestrator exit = %d, want 0", code)
		}
	case <-ctx.Done():
		t.Fatal("orchestrator did not finish")
	}
}

// waitFor reads frames until cond() is true, or (when cond is the trivial false) until
// a frame of wantKind arrives. Output frames are accumulated into v.out.
func waitFor(ctx context.Context, t *testing.T, v *viewer, cond func() bool, wantKind byte, what string) bool {
	t.Helper()
	for {
		if cond() {
			return true
		}
		kind, payload, err := v.read(ctx)
		if err != nil {
			t.Fatalf("waiting for %s: %v", what, err)
		}
		switch kind {
		case protocol.KindOutput:
			v.out.Write(payload)
		case wantKind:
			if wantKind == protocol.KindControl {
				if len(payload) > 0 && payload[0] == protocol.ControlGranted {
					return true
				}
			} else {
				return true
			}
		}
	}
}
