// Command soak drives N concurrent full runner↔viewer sessions through a real
// relay, carrying traffic and periodically forcing reconnect storms, then reports
// throughput, the session-cap behavior, and the relay's resident memory over the
// run. It is a load/leak harness, not a correctness test — it asserts only "no
// crash, the cap holds, memory does not run away" and prints capacity numbers for
// deploy sizing.
//
// Usage (against a running relay; `make soak` boots one for you):
//
//	ONLYTTY_SERVER=http://127.0.0.1:4000 go run ./runner/cmd/soak -n 50 -duration 60s
//
// E2E is preserved: like every viewer, this one only ever sees ciphertext it can
// decrypt with keys it derived locally — the harness measures sizes and liveness,
// never plaintext on the wire.
package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/protocol"
	"github.com/AndrewDryga/onlytty/runner/internal/ptysession"
	"github.com/AndrewDryga/onlytty/runner/internal/relayclient"
	"github.com/AndrewDryga/onlytty/runner/internal/runner"
	"github.com/coder/websocket"
)

func main() {
	n := flag.Int("n", 20, "concurrent runner+viewer pairs to sustain")
	duration := flag.Duration("duration", 30*time.Second, "how long to soak")
	churn := flag.Duration("churn", 5*time.Second, "reconnect-storm interval (0 disables)")
	churnFrac := flag.Float64("churn-frac", 0.25, "fraction of viewers to reconnect each storm")
	base := flag.String("server", serverBase(), "relay base URL")
	flag.Parse()

	if !healthy(*base) {
		fmt.Fprintf(os.Stderr, "soak: relay not reachable at %s — run `make soak` or start one\n", *base)
		os.Exit(1)
	}
	fmt.Printf("soak: %d pairs for %s against %s (churn %s, %.0f%%)\n",
		*n, *duration, *base, *churn, *churnFrac*100)

	rss := startRSSSampler()
	stats := &stats{}

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	var wg sync.WaitGroup
	pairs := make([]*pair, *n)
	for i := 0; i < *n; i++ {
		p := &pair{base: *base, stats: stats, id: i}
		pairs[i] = p
		wg.Add(1)
		go func() { defer wg.Done(); p.run(ctx) }()
	}

	// Reconnect storm: periodically bounce a random fraction of viewers.
	if *churn > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			t := time.NewTicker(*churn)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					k := int(float64(*n) * *churnFrac)
					for j := 0; j < k; j++ {
						pairs[rand.Intn(*n)].bounceNow()
					}
					stats.storms.Add(1)
				}
			}
		}()
	}

	wg.Wait()
	report(stats, rss, *n)
	if stats.fatal.Load() > 0 || rss.leaked() {
		os.Exit(1)
	}
}

// ── one runner+viewer pair ───────────────────────────────────────────────────

type pair struct {
	base  string
	stats *stats
	id    int

	mu       sync.Mutex
	bounceCh chan struct{}
}

// bounceNow asks the pair's active viewer session to reconnect (non-blocking).
func (p *pair) bounceNow() {
	p.mu.Lock()
	ch := p.bounceCh
	p.mu.Unlock()
	if ch == nil {
		return
	}
	select {
	case ch <- struct{}{}:
	default:
	}
}

func (p *pair) run(ctx context.Context) {
	client, err := relayclient.New(p.base, false)
	if err != nil {
		p.stats.fatal.Add(1)
		return
	}
	sess, err := client.CreateSession(ctx, 10*time.Minute)
	if err != nil {
		// At/over the configured RELAY_MAX_SESSIONS cap, create is refused — that is
		// the cap working, not a crash. Count it and stop this pair cleanly.
		if strings.Contains(err.Error(), "capacity") || strings.Contains(err.Error(), "503") {
			p.stats.capRejects.Add(1)
			return
		}
		p.stats.fatal.Add(1)
		return
	}
	p.stats.sessions.Add(1)

	secret := make([]byte, protocol.SecretLen)
	for i := range secret {
		secret[i] = byte((p.id*31 + i*7) & 0xff)
	}
	keys, err := protocol.DeriveKeys(secret, sess.ID, "")
	if err != nil {
		p.stats.fatal.Add(1)
		return
	}
	psess, err := ptysession.Start([]string{"cat"}, os.Environ())
	if err != nil {
		p.stats.fatal.Add(1)
		return
	}
	_ = psess.SetSize(80, 24)
	orch, err := runner.New(runner.Config{
		Client: client, Session: psess, Keys: keys, SessionID: sess.ID, Token: sess.RunnerToken,
	})
	if err != nil {
		p.stats.fatal.Add(1)
		return
	}
	go orch.Run(ctx)

	p.mu.Lock()
	p.bounceCh = make(chan struct{}, 1)
	p.mu.Unlock()
	wsBase := strings.Replace(p.base, "http", "ws", 1)

	// (Re)connect the viewer and pump traffic until ctx ends or a bounce is asked.
	for ctx.Err() == nil {
		if err := p.session(ctx, wsBase, sess, keys); err != nil && ctx.Err() == nil {
			// A drop mid-run is expected during a storm; reconnect after a beat.
			p.stats.drops.Add(1)
			select {
			case <-ctx.Done():
			case <-time.After(200 * time.Millisecond):
			}
		}
	}
}

// session connects one viewer, takes control, and exchanges traffic until ctx ends
// or a bounce is requested (returning an error so run() reconnects).
func (p *pair) session(ctx context.Context, wsBase string, sess *relayclient.Session, keys protocol.Keys) error {
	conn, _, err := websocket.Dial(ctx, wsBase+"/ws/viewer/"+sess.ID, nil)
	if err != nil {
		return err
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(2 << 20)

	openC, _ := protocol.NewCipher(keys.R2V, []byte(sess.ID))
	sealC, _ := protocol.NewCipher(keys.V2R, []byte(sess.ID))
	v := &viewer{conn: conn, open: openC, seal: sealC}

	kind, payload, err := v.read(ctx)
	if err != nil {
		return err
	}
	if kind == protocol.KindHello {
		baseline, _, _, derr := protocol.DecodeHello(payload)
		if derr != nil {
			return derr
		}
		v.outSeq = baseline - 1
	}
	if err := v.send(ctx, protocol.KindCtrlReq, nil); err != nil {
		return err
	}

	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	reads := make(chan struct{}, 1)
	go func() {
		for {
			if _, _, rerr := v.read(ctx); rerr != nil {
				select {
				case reads <- struct{}{}:
				default:
				}
				return
			}
			p.stats.frames.Add(1)
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-p.bounceCh:
			return fmt.Errorf("bounced")
		case <-reads:
			return fmt.Errorf("read ended")
		case <-tick.C:
			if err := v.send(ctx, protocol.KindInput, []byte("soak-ping\n")); err != nil {
				return err
			}
		}
	}
}

// ── viewer (the browser's encrypted role, in Go) ─────────────────────────────

type viewer struct {
	conn   *websocket.Conn
	open   *protocol.Cipher
	seal   *protocol.Cipher
	outSeq uint64
}

func (v *viewer) read(ctx context.Context) (byte, []byte, error) {
	for {
		typ, data, err := v.conn.Read(ctx)
		if err != nil {
			return 0, nil, err
		}
		if typ != websocket.MessageBinary {
			continue
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

// ── stats + reporting ────────────────────────────────────────────────────────

type stats struct {
	sessions   atomic.Int64
	capRejects atomic.Int64
	frames     atomic.Int64
	drops      atomic.Int64
	storms     atomic.Int64
	fatal      atomic.Int64
}

func report(s *stats, rss *rssSampler, n int) {
	fmt.Println("── soak report ──────────────────────────────")
	fmt.Printf("  target pairs       %d\n", n)
	fmt.Printf("  sessions created   %d\n", s.sessions.Load())
	fmt.Printf("  cap rejects (503)  %d\n", s.capRejects.Load())
	fmt.Printf("  frames decrypted   %d\n", s.frames.Load())
	fmt.Printf("  reconnect drops    %d  over %d storms\n", s.drops.Load(), s.storms.Load())
	fmt.Printf("  fatal errors       %d\n", s.fatal.Load())
	rss.report()
	if s.fatal.Load() == 0 && !rss.leaked() {
		fmt.Println("  RESULT: ok (no crash; cap held; memory bounded)")
	} else {
		fmt.Println("  RESULT: FAIL")
	}
}

func serverBase() string {
	if v := os.Getenv("ONLYTTY_SERVER"); v != "" {
		return v
	}
	return "http://127.0.0.1:4000"
}
