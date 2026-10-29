package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/AndrewDryga/onlytty/runner/internal/relayclient"
	"github.com/AndrewDryga/onlytty/runner/internal/runner"
	"github.com/creack/pty"
)

// TestMain lets a test run the real CLI in its own process: with
// ONLYTTY_TEST_MAIN=1 this test binary is onlytty, so the test controls its
// stdin, controlling terminal and termios.
func TestMain(m *testing.M) {
	if os.Getenv("ONLYTTY_TEST_MAIN") == "1" {
		os.Exit(run())
	}
	os.Exit(m.Run())
}

// envOr resolves the relay default: unset/empty → the hosted relay; set → the env wins.
func TestEnvOr(t *testing.T) {
	const key = "ONLYTTY_TEST_ENVOR"

	if got := envOr(key, defaultPublicRelay); got != defaultPublicRelay {
		t.Errorf("unset: got %q, want the fallback %q", got, defaultPublicRelay)
	}
	t.Setenv(key, "") // an explicitly blank ONLYTTY_SERVER still falls back to the default
	if got := envOr(key, defaultPublicRelay); got != defaultPublicRelay {
		t.Errorf("empty: got %q, want the fallback %q", got, defaultPublicRelay)
	}
	t.Setenv(key, "https://relay.example.com")
	if got := envOr(key, defaultPublicRelay); got != "https://relay.example.com" {
		t.Errorf("set: got %q, want the env value to win", got)
	}
}

// The zero-config default must satisfy the same validation as a user-supplied
// --server (https, has a host), or every default `onlytty -- <cmd>` would fail at
// startup. This guards against a fat-fingered constant breaking the headline flow.
func TestDefaultPublicRelayIsValid(t *testing.T) {
	if _, err := relayclient.New(defaultPublicRelay, false); err != nil {
		t.Fatalf("defaultPublicRelay %q rejected by relayclient.New: %v", defaultPublicRelay, err)
	}
}

// The banner must show the relay's assigned expiry (Session.ExpiresAt), not the
// raw --ttl flag, since the server clamps the TTL to [60s, 24h].
func TestRemainingDerivesFromExpiresAt(t *testing.T) {
	now := time.Unix(1_000_000, 0)

	// --ttl 100000h gets clamped to 24h; the banner reflects the clamp.
	if got := remaining(now.Add(24*time.Hour).Unix(), now); got != 24*time.Hour {
		t.Fatalf("remaining = %s, want 24h0m0s", got)
	}
	// --ttl 1s gets clamped up to 60s.
	if got := remaining(now.Add(60*time.Second).Unix(), now); got != 60*time.Second {
		t.Fatalf("remaining = %s, want 1m0s", got)
	}
}

func TestGeneratePassphrase(t *testing.T) {
	p, err := generatePassphrase()
	if err != nil {
		t.Fatal(err)
	}
	// 80 bits → 16 base32 chars grouped into 4s with 3 dashes = 19.
	if len(p) != 19 {
		t.Fatalf("len = %d, want 19 (%q)", len(p), p)
	}
	// Unambiguous charset only: base32 upper A–Z/2–7 plus the grouping dash.
	const allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567-"
	for _, r := range p {
		if !strings.ContainsRune(allowed, r) {
			t.Fatalf("ambiguous/invalid char %q in %q", r, p)
		}
	}
	// Distinct each call.
	if p2, _ := generatePassphrase(); p == p2 {
		t.Fatal("two generated passphrases should differ")
	}
}

func TestWriteQRHalfBlock(t *testing.T) {
	var out bytes.Buffer

	writeQRHalfBlock(&out, "https://onlytty.com/s/test#secret")

	got := out.String()
	if got == "" {
		t.Fatal("expected QR output")
	}
	for _, want := range []string{"\u2588", "\u2580", "\u2584"} {
		if !strings.Contains(got, want) {
			t.Fatalf("QR output missing %q", want)
		}
	}
}

func TestResolveControl(t *testing.T) {
	cases := []struct {
		name    string
		flag    string
		want    runner.ControlMode
		wantErr bool
	}{
		{"default auto", "auto", runner.ControlAuto, false},
		{"explicit view-only", "view-only", runner.ControlViewOnly, false},
		{"once", "once", runner.ControlOnce, false},
		{"old ask mode is rejected", "ask", 0, true},
		{"unknown mode errors", "bogus", 0, true},
	}
	for _, c := range cases {
		got, err := resolveControl(c.flag)
		if c.wantErr {
			if err == nil {
				t.Errorf("%s: expected an error, got mode %v", c.name, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error: %v", c.name, err)
		} else if got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

// The launch gate must never arm for a shared shell (the prompt does not clear
// the banner, so gating would be pure friction). The armed case runs on a real
// PTY in TestPipedStdinTakesKeysFromTerminal, and the browser e2e suite spawns
// the binary over pipes, where it would hang if the gate misfired.
func TestGateLaunchShellMode(t *testing.T) {
	if gateLaunch(true, os.Stdin) {
		t.Fatal("shell mode must not gate the launch")
	}
}

// waitForStart holds the child launch (so a full-screen app cannot wipe the
// QR/link banner) until the host presses Enter — and must not hang forever on
// a terminal that closes instead.
func TestWaitForStart(t *testing.T) {
	done := make(chan struct{})
	pr, pw := io.Pipe()
	go func() {
		waitForStart(pr, []string{"claude"})
		close(done)
	}()

	if _, err := pw.Write([]byte("abc")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
		t.Fatal("returned before Enter was pressed")
	case <-time.After(50 * time.Millisecond):
	}

	if _, err := pw.Write([]byte("\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("did not return after Enter")
	}

	// EOF (e.g. the terminal went away) releases the gate rather than hanging.
	eofDone := make(chan struct{})
	go func() {
		waitForStart(strings.NewReader("no newline at all"), []string{"claude"})
		close(eofDone)
	}()
	select {
	case <-eofDone:
	case <-time.After(2 * time.Second):
		t.Fatal("did not return on EOF")
	}
}

// `curl … | sh -s -- claude` starts onlytty with the installer's pipe as stdin,
// and bash (macOS /bin/sh) leaves the script's unread tail in it. The command
// must get the host's keys from the controlling terminal and never that tail; the
// terminal must be raw, or the kernel echoes each key over the command's screen;
// and the PTY must take the terminal's size rather than fall back to 80x24.
func TestPipedStdinTakesKeysFromTerminal(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusServiceUnavailable) // runner socket: retry until the command exits
			return
		}
		var s relayclient.Session // echo the runner-chosen id + token back
		_ = json.NewDecoder(r.Body).Decode(&s)
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(s)
	}))
	defer relay.Close()

	ptmx, tty, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer ptmx.Close()
	if err := pty.Setsize(ptmx, &pty.Winsize{Rows: 33, Cols: 101}); err != nil {
		t.Fatal(err)
	}
	pipeR, pipeW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pipeW.WriteString("installer-tail\n"); err != nil {
		t.Fatal(err)
	}
	_ = pipeW.Close()

	// The command reports its size and the first line it reads. Its own echo is
	// off, so an echo of the typed keys could only come from the host terminal.
	// printf builds the markers so they never match the command line, which the
	// banner and the launch prompt print verbatim.
	cmd := exec.Command(os.Args[0], "--server", relay.URL, "--no-qr", "--",
		"sh", "-c", `stty -echo; printf '<%s %s>\n' size "$(stty size)"; IFS= read -r line; printf '<%s %s>\n' got "$line"`)
	cmd.Env = append(os.Environ(), "ONLYTTY_TEST_MAIN=1")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = pipeR, tty, tty
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 1} // tty is its /dev/tty
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill() }() // no-op once it has exited
	_ = pipeR.Close()
	_ = tty.Close()

	chunks := make(chan []byte)
	go func() {
		defer close(chunks)
		for {
			buf := make([]byte, 4096)
			n, err := ptmx.Read(buf)
			if n > 0 {
				chunks <- buf[:n]
			}
			if err != nil {
				return
			}
		}
	}()
	var screen []byte
	// readUntil collects the terminal's output until want shows up, or (want == "")
	// until it closes. Draining to the end also matters on macOS, where an exiting
	// process blocks until its terminal output has been read.
	readUntil := func(want string) {
		t.Helper()
		timeout := time.After(10 * time.Second)
		for want == "" || !bytes.Contains(screen, []byte(want)) {
			select {
			case b, ok := <-chunks:
				if !ok {
					if want == "" {
						return
					}
					t.Fatalf("terminal closed before %q:\n%q", want, screen)
				}
				screen = append(screen, b...)
			case <-timeout:
				t.Fatalf("timed out waiting for %q:\n%q", want, screen)
			}
		}
	}
	typeKeys := func(s string) {
		t.Helper()
		if _, err := ptmx.Write([]byte(s)); err != nil {
			t.Fatal(err)
		}
	}

	readUntil("Press Enter") // the launch gate
	typeKeys("\r")
	readUntil("<size ")
	typeKeys("host-keys\r")
	readUntil("")
	if err := cmd.Wait(); err != nil {
		t.Fatalf("onlytty: %v\n%q", err, screen)
	}

	for _, want := range []string{"<size 33 101>", "<got host-keys>"} {
		if !bytes.Contains(screen, []byte(want)) {
			t.Errorf("missing %q", want)
		}
	}
	if bytes.Contains(screen, []byte("installer-tail")) {
		t.Error("the pipe's contents reached the command")
	}
	if n := bytes.Count(screen, []byte("host-keys")); n != 1 {
		t.Errorf("host-keys appears %d times, want once (the command's report); more means the host terminal echoed it", n)
	}
	if t.Failed() {
		t.Logf("terminal output:\n%q", screen)
	}
}

func TestStartPrompt(t *testing.T) {
	p := startPrompt([]string{"claude", "--continue"})
	for _, want := range []string{"Press Enter", "claude --continue"} {
		if !strings.Contains(p, want) {
			t.Fatalf("start prompt %q missing %q", p, want)
		}
	}
}

func TestSessionInstruction(t *testing.T) {
	shell := sessionInstruction(true)
	for _, want := range []string{"shared shell", "Ctrl-D", "exit", "stop sharing"} {
		if !strings.Contains(shell, want) {
			t.Fatalf("shell instruction %q missing %q", shell, want)
		}
	}

	cmd := sessionInstruction(false)
	for _, want := range []string{"command", "exits", "sharing stops"} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("command instruction %q missing %q", cmd, want)
		}
	}
	if strings.Contains(cmd, "shared shell") {
		t.Fatalf("command instruction should not claim shell mode: %q", cmd)
	}
}

func TestSessionActiveAndStoppedText(t *testing.T) {
	shell := sessionActiveText([]string{"/bin/zsh"}, true)
	for _, want := range []string{"ACTIVE", "shell", "shared"} {
		if !strings.Contains(shell, want) {
			t.Fatalf("shell active text %q missing %q", shell, want)
		}
	}

	cmd := sessionActiveText([]string{"top", "-o", "cpu"}, false)
	for _, want := range []string{"ACTIVE", "running: top -o cpu"} {
		if !strings.Contains(cmd, want) {
			t.Fatalf("command active text %q missing %q", cmd, want)
		}
	}

	stopped := sessionStoppedText(7)
	for _, want := range []string{"sharing stopped", "Browser viewers are disconnected", "Exit code: 7"} {
		if !strings.Contains(stopped, want) {
			t.Fatalf("stopped text %q missing %q", stopped, want)
		}
	}
}
