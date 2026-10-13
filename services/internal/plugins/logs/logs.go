// Package logs provides a small thread-safe ring buffer of recent log lines
// used by the admin namespace to expose live system logs.
package logs

import (
	"sync"
	"time"
)

// Entry is a single captured log line.
type Entry struct {
	Time    time.Time `json:"time"`
	Level   string    `json:"level"`
	Logger  string    `json:"logger"`
	Message string    `json:"message"`
}

// Ring is a bounded ring buffer.
type Ring struct {
	mu      sync.RWMutex
	entries []Entry
	size    int
	next    int
	count   int
}

// NewRing creates a ring buffer holding up to size entries.
func NewRing(size int) *Ring {
	if size <= 0 {
		size = 1000
	}
	return &Ring{entries: make([]Entry, size), size: size}
}

// Add appends an entry.
func (r *Ring) Add(e Entry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entries[r.next] = e
	r.next = (r.next + 1) % r.size
	if r.count < r.size {
		r.count++
	}
}

// Recent returns the most recent n entries, oldest first.
func (r *Ring) Recent(n int) []Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if n <= 0 || n > r.count {
		n = r.count
	}
	out := make([]Entry, 0, n)
	start := (r.next - n + r.size) % r.size
	for i := 0; i < n; i++ {
		out = append(out, r.entries[(start+i)%r.size])
	}
	return out
}
