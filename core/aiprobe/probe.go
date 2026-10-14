package aiprobe

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

type Identity struct {
	Profile   string
	Revision  string
	Group     string
	Selection string // private identity of the user's current choices; never exported
}
type Result struct {
	Service string     `json:"service"`
	State   string     `json:"state"`
	At      time.Time  `json:"at"`
	RetryAt *time.Time `json:"retryAt,omitempty"`
}
type endpoint struct{ id, url, marker string }

var official = []endpoint{
	{"chatgpt", "https://chatgpt.com/", "chatgpt"},
	{"claude", "https://claude.ai/", "claude"},
	{"gemini", "https://gemini.google.com/", "gemini"},
}
var officialHosts = map[string]bool{"chatgpt.com": true, "claude.ai": true, "gemini.google.com": true}

type cacheEntry struct {
	results []Result
	expires time.Time
}

// Manager has a single bounded lease and a small per-process cache. Its owner
// must invalidate the identity on profile/revision/selection changes and cancel
// ctx on leaving the UI, disconnecting or ending the Controller session.
type Manager struct {
	clientFactory func(*session) (*http.Client, *http.Transport) // package-private test trust roots only
	busy          sync.Mutex
	mu            sync.Mutex
	cache         map[Identity]cacheEntry
}

func (m *Manager) Check(ctx context.Context, id Identity, tunnel C.Tunnel, current func() bool, retry bool) ([]Result, error) {
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if current == nil || id.Profile == "" || id.Revision == "" || id.Group == "" || !current() {
		return nil, errors.New("PROBE_NOT_CURRENT")
	}
	if !m.busy.TryLock() {
		return nil, errors.New("PROBE_BUSY")
	}
	defer m.busy.Unlock()
	m.mu.Lock()
	entry, ok := m.cache[id]
	m.mu.Unlock()
	if ok && time.Now().Before(entry.expires) {
		// Explicit retry bypasses the normal short cache, but not server throttling.
		limited := false
		for _, r := range entry.results {
			if r.RetryAt != nil && time.Now().Before(*r.RetryAt) {
				limited = true
			}
		}
		if !retry || limited {
			if ctx.Err() != nil || !current() {
				return nil, errors.New("PROBE_NOT_CURRENT")
			}
			return append([]Result(nil), entry.results...), nil
		}
	}
	return m.check(ctx, id, tunnel, current, official, officialHosts)
}

func (m *Manager) check(parent context.Context, id Identity, tunnel C.Tunnel, current func() bool, endpoints []endpoint, hosts map[string]bool) ([]Result, error) {
	ctx, cancel := context.WithTimeout(parent, 18*time.Second)
	defer cancel()
	lease, err := newSession(id.Group, tunnel, hosts)
	if err != nil {
		return nil, err
	}
	defer lease.close()
	client, transport := lease.client()
	if m.clientFactory != nil {
		client, transport = m.clientFactory(lease)
	}
	defer transport.CloseIdleConnections()
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				lease.mu.Lock()
				for c := range lease.connections {
					c.Close()
				}
				lease.mu.Unlock()
				return
			case <-done:
				return
			case <-ticker.C:
				if !current() {
					cancel()
				}
			}
		}
	}()
	defer close(done)
	results := make([]Result, len(endpoints))
	var workers sync.WaitGroup
	semaphore := make(chan struct{}, 2)
	for index, e := range endpoints {
		workers.Add(1)
		go func() {
			defer workers.Done()
			select {
			case semaphore <- struct{}{}:
				defer func() { <-semaphore }()
			case <-ctx.Done():
				return
			}
			results[index] = probe(ctx, client, e)
			results[index].At = time.Now().UTC()
		}()
	}
	workers.Wait()
	if parent.Err() != nil {
		return nil, parent.Err()
	}
	if ctx.Err() != nil || !current() {
		return nil, errors.New("PROBE_CANCELLED")
	}
	expires := time.Now().Add(2 * time.Minute)
	for _, r := range results {
		if r.RetryAt != nil && r.RetryAt.After(expires) {
			expires = *r.RetryAt
		}
	}
	m.mu.Lock()
	if len(m.cache) >= 16 {
		m.cache = nil
	}
	if m.cache == nil {
		m.cache = map[Identity]cacheEntry{}
	}
	m.cache[id] = cacheEntry{append([]Result(nil), results...), expires}
	m.mu.Unlock()
	return results, nil
}

func probe(ctx context.Context, client *http.Client, e endpoint) Result {
	result := Result{Service: e.id, State: "unknown", At: time.Now().UTC()}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, e.url, nil)
	if err != nil {
		return result
	}
	// No Cookie jar, Authorization, API key, user input or inherited proxy env.
	req.Header.Set("Accept", "text/html,application/json")
	response, err := client.Do(req)
	if err != nil {
		var n net.Error
		if errors.As(err, &n) && n.Timeout() {
			result.State = "timeout"
		} else {
			result.State = "network_failed"
		}
		return result
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil {
		return result
	}
	if response.StatusCode == 429 {
		result.State = "limited"
		wait := 5 * time.Minute
		if seconds, err := strconv.Atoi(response.Header.Get("Retry-After")); err == nil {
			if seconds < 60 {
				seconds = 60
			}
			if seconds > 600 {
				seconds = 600
			}
			wait = time.Duration(seconds) * time.Second
		} else if until, err := http.ParseTime(response.Header.Get("Retry-After")); err == nil {
			wait = time.Until(until)
		}
		if wait < time.Minute {
			wait = time.Minute
		}
		if wait > 10*time.Minute {
			wait = 10 * time.Minute
		}
		at := time.Now().Add(wait).UTC()
		result.RetryAt = &at
		return result
	}
	if len(body) > 64*1024 {
		return result
	}
	text := strings.ToLower(string(body))
	if (response.StatusCode == 403 || response.StatusCode == 451) && (strings.Contains(text, "unsupported_country") || strings.Contains(text, "not available in your country") || strings.Contains(text, "not available in your region")) {
		result.State = "region_restricted"
		return result
	}
	if response.StatusCode >= 200 && response.StatusCode < 300 && strings.Contains(text, e.marker) {
		result.State = "reachable"
	}
	return result
}
