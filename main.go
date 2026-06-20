// Command relay shares a command (or your shell) running in a local PTY to a
// browser, end-to-end encrypted, through an untrusted relay. See README.md.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/AndrewDryga/relay/internal/protocol"
	"github.com/AndrewDryga/relay/internal/ptysession"
	"github.com/AndrewDryga/relay/internal/relayclient"
	"github.com/AndrewDryga/relay/internal/runner"
	"github.com/creack/pty"
	"github.com/mdp/qrterminal/v3"
	"golang.org/x/term"
)

var version = "dev"

// resolveVersion prefers the ldflags-injected version (Makefile builds). For a
// plain `go install …@ref` / `go build`, which never runs the Makefile, it falls
// back to the module version from the build info (resolved tag/pseudo-version, or
// "(devel)" for an untagged local build) instead of the bare "dev" sentinel.
func resolveVersion() string {
	if version != "dev" {
		return version
	}
	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" {
		return info.Main.Version
	}
	return version
}

func main() { os.Exit(run()) }

func run() int {
	server := flag.String("server", os.Getenv("RELAY_SERVER"), "relay server origin, e.g. https://relay.example.com (or set RELAY_SERVER)")
	readOnly := flag.Bool("read-only", false, "viewers may watch but never type or resize")
	ttl := flag.Duration("ttl", 12*time.Hour, "session lifetime before the link expires")
	withPass := flag.Bool("passphrase", false, "prompt for a passphrase to mix into the keys (shared out-of-band; the link alone won't decrypt)")
	noQR := flag.Bool("no-qr", false, "print the link without a QR code")
	showVer := flag.Bool("version", false, "print version and exit")
	flag.Usage = usage
	flag.Parse()

	if *showVer {
		fmt.Println("relay", resolveVersion())
		return 0
	}
	if *server == "" {
		fmt.Fprintln(os.Stderr, "relay: set --server or RELAY_SERVER (e.g. https://relay.example.com)")
		return 2
	}

	argv := resolveCommand(flag.Args())
	client, err := relayclient.New(*server)
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		return 1
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP)
	defer stop()

	// Optional passphrase, read before we touch the terminal mode.
	passphrase := ""
	if *withPass {
		passphrase, err = promptPassphrase()
		if err != nil {
			fmt.Fprintln(os.Stderr, "relay:", err)
			return 1
		}
	}

	// 1) Create the session (the relay never sees the secret below).
	sess, err := client.CreateSession(ctx, *ttl)
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		return 1
	}

	// 2) Generate the session secret S and derive the E2E keys locally.
	secret := make([]byte, protocol.SecretLen)
	if _, err := rand.Read(secret); err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		return 1
	}
	keys, err := protocol.DeriveKeys(secret, sess.ID, passphrase)
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		return 1
	}
	secretB64 := base64.RawURLEncoding.EncodeToString(secret)
	link := client.ViewerURL(sess.ID, secretB64, passphrase != "")

	printBanner(link, formatFingerprint(keys.Fingerprint), *ttl, *readOnly, passphrase != "", *noQR)

	// 3) Start the command in a PTY and mirror it locally.
	psess, err := ptysession.Start(argv, os.Environ())
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay: failed to start command:", err)
		return 1
	}
	if ws, err := pty.GetsizeFull(os.Stdin); err == nil {
		_ = psess.SetSize(ws.Cols, ws.Rows)
	} else {
		_ = psess.SetSize(80, 24)
	}

	// 4) Raw-mode the local terminal so keystrokes reach the command verbatim.
	// Deferred restore runs on every return path, including a panic.
	stdinFd := int(os.Stdin.Fd())
	if term.IsTerminal(stdinFd) {
		if old, err := term.MakeRaw(stdinFd); err == nil {
			defer func() { _ = term.Restore(stdinFd, old) }()
		}
	}

	orch, err := runner.New(runner.Config{
		Client: client, Session: psess, Keys: keys, SessionID: sess.ID, Token: sess.RunnerToken,
		ReadOnly: *readOnly, LocalIn: os.Stdin, LocalOut: os.Stdout,
		Notify: notifier(), Fingerprint: formatFingerprint(keys.Fingerprint),
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		return 1
	}

	// Forward local terminal resizes to the PTY.
	go watchResize(ctx, orch)

	code := orch.Run(ctx)
	fmt.Fprintf(os.Stderr, "\r\n%s\r\n", dim("relay: session ended (exit "+itoa(code)+")"))
	return code
}

// resolveCommand returns the user's command, or the login shell when none is given.
func resolveCommand(args []string) []string {
	if len(args) > 0 {
		return args
	}
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	return []string{shell}
}

func watchResize(ctx context.Context, orch *runner.Orchestrator) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	defer signal.Stop(ch)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ch:
			if ws, err := pty.GetsizeFull(os.Stdin); err == nil {
				orch.Resize(ws.Cols, ws.Rows)
			}
		}
	}
}

func promptPassphrase() (string, error) {
	// Reading a passphrase is interactive-only; without a TTY, term.ReadPassword
	// fails with a raw ENOTTY. Check first and emit something actionable, and don't
	// print a prompt we can't read the answer to.
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return "", errors.New("--passphrase needs an interactive terminal")
	}
	fmt.Fprint(os.Stderr, "Passphrase (shared out-of-band): ")
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", fmt.Errorf("reading passphrase: %w", err)
	}
	if len(b) == 0 {
		return "", errors.New("empty passphrase")
	}
	return string(b), nil
}

// notifier returns a callback that prints short, dim notices to stderr. In raw mode
// it prefixes a carriage return so the line starts at column 0.
func notifier() func(string) {
	tty := term.IsTerminal(int(os.Stderr.Fd()))
	return func(s string) {
		if tty {
			fmt.Fprintf(os.Stderr, "\r\x1b[2K\x1b[2m%s\x1b[0m\r\n", s)
		} else {
			fmt.Fprintln(os.Stderr, s)
		}
	}
}

func printBanner(link, fingerprint string, ttl time.Duration, readOnly, passphrase, noQR bool) {
	w := os.Stderr
	fmt.Fprintf(w, "\n  %s\n\n", bold("relay — this session is shared, end-to-end encrypted"))
	if !noQR {
		qrterminal.GenerateHalfBlock(link, qrterminal.M, w)
		fmt.Fprintln(w)
	}
	fmt.Fprintf(w, "  Link         %s\n", link)
	fmt.Fprintf(w, "  Fingerprint  %s  %s\n", fingerprint, dim("(must match in the browser)"))
	fmt.Fprintf(w, "  Expires      in %s\n", ttl)
	control := "viewers may request control"
	if readOnly {
		control = "read-only (viewers cannot type or resize)"
	}
	fmt.Fprintf(w, "  Control      %s\n", control)
	if passphrase {
		fmt.Fprintf(w, "  Passphrase   %s\n", dim("required in the browser (the link alone won't decrypt)"))
	}
	fmt.Fprintf(w, "\n  %s\n", dim("Scan the QR or open the link. The relay only ever sees ciphertext."))
	fmt.Fprintf(w, "  %s\n\n", dim("Use the command normally here; exit it to stop sharing."))
}

// formatFingerprint groups the base32 fingerprint into 4-char blocks for eyeballing.
func formatFingerprint(fp string) string {
	var b strings.Builder
	for i, r := range fp {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func usage() {
	fmt.Fprintf(os.Stderr, `relay — share a command or your shell to a browser, end-to-end encrypted.

Usage:
  relay [flags]              share your $SHELL
  relay [flags] -- <cmd>...  share one command

Flags:
`)
	flag.PrintDefaults()
	fmt.Fprintf(os.Stderr, "\nExamples:\n  relay -- claude\n  relay --read-only -- htop\n  relay --passphrase\n")
}

// Small ANSI helpers, gated on stderr being a terminal.
func styled(code, s string) string {
	if term.IsTerminal(int(os.Stderr.Fd())) {
		return "\x1b[" + code + "m" + s + "\x1b[0m"
	}
	return s
}
func bold(s string) string { return styled("1", s) }
func dim(s string) string  { return styled("2", s) }

func itoa(i int) string { return fmt.Sprintf("%d", i) }
