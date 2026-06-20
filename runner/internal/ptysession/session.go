// Package ptysession runs a command in a pseudo-terminal and exposes its IO plus a
// resume ring buffer. It is the local half of relay: the command runs and is
// mirrored to the user's terminal regardless of whether anyone is viewing.
package ptysession

import (
	"errors"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

// Session is a command running in a PTY.
type Session struct {
	ptmx *os.File
	cmd  *exec.Cmd

	mu         sync.Mutex
	cols, rows uint16
}

// Start launches argv in a new PTY with the given environment. The child begins
// running immediately; read its output with Read and send input with Write.
func Start(argv, env []string) (*Session, error) {
	if len(argv) == 0 {
		return nil, errors.New("ptysession: empty command")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	return &Session{ptmx: ptmx, cmd: cmd}, nil
}

// Read reads PTY output (the command's stdout/stderr).
func (s *Session) Read(p []byte) (int, error) { return s.ptmx.Read(p) }

// Write sends input (keystrokes) to the command.
func (s *Session) Write(p []byte) (int, error) { return s.ptmx.Write(p) }

// SetSize resizes the PTY. A zero dimension is ignored (treated as "unknown").
func (s *Session) SetSize(cols, rows uint16) error {
	if cols == 0 || rows == 0 {
		return nil
	}
	s.mu.Lock()
	s.cols, s.rows = cols, rows
	s.mu.Unlock()
	return pty.Setsize(s.ptmx, &pty.Winsize{Rows: rows, Cols: cols})
}

// Size returns the last size set on the PTY.
func (s *Session) Size() (cols, rows uint16) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cols, s.rows
}

// Wait blocks until the command exits.
func (s *Session) Wait() error { return s.cmd.Wait() }

// ExitCode returns the command's exit code, or -1 if it has not finished.
func (s *Session) ExitCode() int {
	if s.cmd.ProcessState == nil {
		return -1
	}
	return s.cmd.ProcessState.ExitCode()
}

// Close releases the PTY. The child receives EOF on its controlling terminal.
func (s *Session) Close() error { return s.ptmx.Close() }
