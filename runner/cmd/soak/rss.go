package main

import (
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// healthy returns true if the relay answers GET /healthz with 200.
func healthy(base string) bool {
	resp, err := http.Get(base + "/healthz")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// rssSampler samples the local relay's resident memory (VmRSS) once a second, so
// the soak can show whether memory plateaus or runs away. If the relay is remote
// (no local beam.smp), it samples nothing and the report says so.
type rssSampler struct {
	pid       int
	mu        sync.Mutex
	samplesKB []int
}

func startRSSSampler() *rssSampler {
	s := &rssSampler{pid: findRelayPID()}
	if s.pid == 0 {
		return s
	}
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for range t.C {
			kb := rssKB(s.pid)
			if kb == 0 {
				return // process gone
			}
			s.mu.Lock()
			s.samplesKB = append(s.samplesKB, kb)
			s.mu.Unlock()
		}
	}()
	return s
}

// leaked is a soft leak check: true only when there is enough data AND the final
// RSS more than doubled versus the post-warmup (25%) sample. Conservative so the
// soak does not fail on normal BEAM growth/GC sawtooth.
func (s *rssSampler) leaked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.samplesKB) < 8 {
		return false
	}
	warm := s.samplesKB[len(s.samplesKB)/4]
	last := s.samplesKB[len(s.samplesKB)-1]
	return warm > 0 && last > warm*2
}

func (s *rssSampler) report() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pid == 0 || len(s.samplesKB) == 0 {
		fmt.Println("  relay RSS          not sampled (relay not local)")
		return
	}
	min, max := s.samplesKB[0], s.samplesKB[0]
	for _, v := range s.samplesKB {
		if v < min {
			min = v
		}
		if v > max {
			max = v
		}
	}
	final := s.samplesKB[len(s.samplesKB)-1]
	fmt.Printf("  relay RSS (pid %d) min %d MB  max %d MB  final %d MB  (%d samples)\n",
		s.pid, min/1024, max/1024, final/1024, len(s.samplesKB))
}

// findRelayPID scans /proc for a local beam.smp (the Elixir relay) and returns the
// one with the largest RSS — the live VM, skipping defunct/zombie beams (RSS 0)
// that linger after a kill.
func findRelayPID() int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	best, bestKB := 0, 0
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		comm, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
		if err != nil || strings.TrimSpace(string(comm)) != "beam.smp" {
			continue
		}
		if kb := rssKB(pid); kb > bestKB {
			best, bestKB = pid, kb
		}
	}
	return best
}

// rssKB reads VmRSS (in KB) from /proc/<pid>/status, or 0 if unavailable.
func rssKB(pid int) int {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				kb, _ := strconv.Atoi(fields[1])
				return kb
			}
		}
	}
	return 0
}
