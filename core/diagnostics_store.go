package main

// Evidence is separate from mihomo.log: no successful traffic/request payloads.
// Each process owns one lane; immutable previous-session files survive restart.
import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const diagnosticJournalLimit = 192 * 1024
const diagnosticEventLimit = 256
const diagnosticBundleLimit = 1024 * 1024

type diagnosticError struct {
	Kind            string            `json:"kind"`
	Code            string            `json:"code,omitempty"`
	Message         string            `json:"message"`
	Causes          []diagnosticError `json:"causes,omitempty"`
	CausesTruncated bool              `json:"causesTruncated,omitempty"`
}
type diagnosticEvent struct {
	Sequence   uint64           `json:"sequence"`
	At         string           `json:"at"`
	Operation  string           `json:"operation"`
	Stage      string           `json:"stage"`
	Outcome    string           `json:"outcome"`
	Object     string           `json:"object,omitempty"`
	DurationMS int64            `json:"durationMs,omitempty"`
	Reason     string           `json:"reason,omitempty"`
	Error      *diagnosticError `json:"error,omitempty"`
	Details    map[string]any   `json:"details,omitempty"`
}
type diagnosticJournal struct {
	Schema        int               `json:"schema"`
	Session       string            `json:"session"`
	StartedAt     string            `json:"startedAt"`
	UpdatedAt     string            `json:"updatedAt"`
	Lane          string            `json:"lane"`
	Dropped       uint64            `json:"dropped"`
	WriteFailures uint64            `json:"writeFailures"`
	LogSuppressed uint64            `json:"logSuppressed"`
	Events        []diagnosticEvent `json:"events"`
}
type diagnosticSource struct {
	Name              string             `json:"name"`
	Status            string             `json:"status"`
	Reason            string             `json:"reason,omitempty"`
	Journal           *diagnosticJournal `json:"journal,omitempty"`
	ExportOmitted     uint64             `json:"exportOmitted"`
	LiveWriteFailures uint64             `json:"liveWriteFailures"`
	UnpersistedEvents uint64             `json:"unpersistedEvents"`
}
type diagnosticStore struct {
	mu            sync.Mutex
	privacyMu     sync.RWMutex
	privateValues *strings.Replacer
	logWindow     time.Time
	logCount      int
	root          string
	lane          string
	key           []byte
	journal       diagnosticJournal
}

var diagnosticStoresMu sync.Mutex
var diagnosticStores = map[string]*diagnosticStore{}

// Never overwrite a previous journal before the old current has been safely
// moved. Rotation at boot retains last boot plus a tail of the one before it.
func newDiagnosticStore(home, lane string) (*diagnosticStore, error) {
	root := filepath.Join(home, "diagnostics")
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	st, err := os.Lstat(root)
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("DIAGNOSTICS_DIRECTORY_INVALID")
	}
	keyPath := filepath.Join(root, "correlation-key")
	key, err := os.ReadFile(keyPath)
	if os.IsNotExist(err) {
		generated := make([]byte, 32)
		if _, err = rand.Read(generated); err != nil {
			return nil, err
		}
		f, e := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e == nil {
			_, e = f.Write(generated)
			if e == nil {
				e = f.Sync()
			}
			closeErr := f.Close()
			if e == nil {
				e = closeErr
			}
			if e != nil {
				return nil, e
			}
		} else if !os.IsExist(e) {
			return nil, e
		}
		// Another lane can win creation. A short/incomplete key fails closed.
		key, err = os.ReadFile(keyPath)
	}
	if err != nil || len(key) != 32 {
		return nil, errors.New("DIAGNOSTICS_KEY_UNAVAILABLE")
	}
	current := filepath.Join(root, lane+"-current.json")
	previous := filepath.Join(root, lane+"-previous.json")
	older := filepath.Join(root, lane+"-older.json")
	if _, err := os.Stat(current); err == nil {
		if _, err := os.Stat(previous); err == nil {
			if err = os.Rename(previous, older); err != nil {
				return nil, err
			}
		}
		if err = os.Rename(current, previous); err != nil {
			return nil, err
		}
	}
	identity := make([]byte, 16)
	if _, err := rand.Read(identity); err != nil {
		return nil, err
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	s := &diagnosticStore{root: root, lane: lane, key: key, journal: diagnosticJournal{
		Schema: 1, Session: hex.EncodeToString(identity), Lane: lane, StartedAt: now, UpdatedAt: now, Events: []diagnosticEvent{}}}
	if err := s.persist(); err != nil {
		return nil, err
	}
	return s, nil
}
func getDiagnosticStore(home, lane string) (*diagnosticStore, error) {
	if !filepath.IsAbs(home) || (lane != "host" && lane != "kernel") {
		return nil, errors.New("DIAGNOSTICS_INVALID")
	}
	diagnosticStoresMu.Lock()
	defer diagnosticStoresMu.Unlock()
	key := home + "/" + lane
	if s := diagnosticStores[key]; s != nil {
		return s, nil
	}
	s, err := newDiagnosticStore(home, lane)
	if err == nil {
		diagnosticStores[key] = s
	}
	return s, err
}
func (s *diagnosticStore) object(value string) string {
	if value == "" {
		return ""
	}
	h := hmac.New(sha256.New, s.key)
	h.Write([]byte(value))
	return "object-" + hex.EncodeToString(h.Sum(nil))[:16]
}

var diagnosticURL = regexp.MustCompile(`(?i)[a-z][a-z0-9+.-]*://[^\s<>"']+`)
var diagnosticCredentials = regexp.MustCompile(`(?i)(authorization|proxy-authorization|password|passwd|token|secret|uuid|credential|api[-_]?key)\s*[:=]\s*[^\s,;]+`)
var diagnosticHost = regexp.MustCompile(`(?i)(?:[a-z0-9_-]+\.)+[a-z][a-z0-9-]*|(?:\d{1,3}\.){3}\d{1,3}|\[[a-f0-9:]+\]`)
var diagnosticPath = regexp.MustCompile(`(?:[A-Za-z]:[\\/]|/)[^\s,;()]+`)
var diagnosticHex = regexp.MustCompile(`(?i)\b[0-9a-f]{32,}\b`)
var diagnosticBearer = regexp.MustCompile(`(?i)\bBearer\s+[^\s,;]+`)

func (s *diagnosticStore) text(input string) string {
	// Raw URLs (including userinfo/path/query/fragment) are removed before any
	// truncation. No credential can survive at a clipped boundary.
	s.privacyMu.RLock()
	if s.privateValues != nil {
		input = s.privateValues.Replace(input)
	}
	s.privacyMu.RUnlock()
	input = redactControllerSecret(input)
	input = diagnosticURL.ReplaceAllStringFunc(input, func(v string) string { return "url-" + s.object(v) })
	input = diagnosticBearer.ReplaceAllString(input, "Bearer [redacted]")
	input = diagnosticCredentials.ReplaceAllString(input, "credential=[redacted]")
	input = diagnosticHex.ReplaceAllString(input, "[redacted-id]")
	input = diagnosticHost.ReplaceAllStringFunc(input, s.object)
	input = diagnosticPath.ReplaceAllStringFunc(input, func(v string) string { return "path-" + s.object(v) })
	// Arbitrary quoted node labels and user-controlled config fragments are private.
	input = regexp.MustCompile(`"[^"\n]*"|'[^'\n]*'`).ReplaceAllStringFunc(input, func(v string) string { return s.object(strings.Trim(v, "\"'")) })
	if len(input) > 2048 {
		input = string([]rune(input)[:min(len([]rune(input)), 512)]) + " [message-truncated]"
	}
	return input
}
func (s *diagnosticStore) failure(err error, depth int) *diagnosticError {
	if err == nil {
		return nil
	}
	out := &diagnosticError{Kind: fmt.Sprintf("%T", err), Message: s.text(err.Error())}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		out.Code = fmt.Sprintf("errno:%d", int(errno))
	}
	if errors.Is(err, context.Canceled) {
		out.Code = "cancelled"
	}
	if errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
		out.Code = "deadline_exceeded"
	}
	if depth == 4 && errors.Unwrap(err) != nil {
		out.CausesTruncated = true
	}
	if depth < 4 {
		if cause := errors.Unwrap(err); cause != nil {
			out.Causes = []diagnosticError{*s.failure(cause, depth+1)}
		}
	}
	return out
}

var diagnosticCode = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,80}$`)

func diagnosticLabel(v string) string {
	if diagnosticCode.MatchString(v) {
		return v
	}
	return "unknown"
}
func (s *diagnosticStore) record(e diagnosticEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e.Sequence = 1
	if n := len(s.journal.Events); n > 0 {
		e.Sequence = s.journal.Events[n-1].Sequence + 1
	}
	e.At = time.Now().UTC().Format(time.RFC3339Nano)
	e.Operation = diagnosticLabel(e.Operation)
	e.Stage = diagnosticLabel(e.Stage)
	e.Outcome = diagnosticLabel(e.Outcome)
	if e.Reason != "" {
		e.Reason = diagnosticLabel(e.Reason)
	}
	e.Object = s.object(e.Object)
	s.journal.UpdatedAt = e.At
	s.journal.Events = append(s.journal.Events, e)
	for {
		data, _ := json.Marshal(s.journal)
		if len(data) <= diagnosticJournalLimit && len(s.journal.Events) <= diagnosticEventLimit {
			break
		}
		s.journal.Events = s.journal.Events[1:]
		s.journal.Dropped++
	}
	if err := s.persist(); err != nil {
		s.journal.WriteFailures++
		return err
	}
	return nil
}
func (s *diagnosticStore) persist() error {
	data, err := json.Marshal(s.journal)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.root, "."+s.lane+"-pending-")
	if err != nil {
		return err
	}
	temp := f.Name()
	defer os.Remove(temp)
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(temp, filepath.Join(s.root, s.lane+"-current.json")); err != nil {
		return err
	}
	dir, err := os.Open(s.root)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
func readDiagnosticSource(root, name string) diagnosticSource {
	source := diagnosticSource{Name: name, Status: "missing", Reason: "no_retained_session"}
	path := filepath.Join(root, name+".json")
	st, err := os.Lstat(path)
	if err == nil && !st.Mode().IsRegular() {
		source.Status = "invalid"
		source.Reason = "not_regular_file"
		return source
	}
	f, err := os.Open(path)
	if err != nil {
		if !os.IsNotExist(err) {
			source.Status = "unreadable"
			source.Reason = "read_failed"
		}
		return source
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, diagnosticJournalLimit+1))
	if err != nil {
		source.Status = "unreadable"
		source.Reason = "read_failed"
		return source
	}
	var journal diagnosticJournal
	if len(data) > diagnosticJournalLimit || json.Unmarshal(data, &journal) != nil || journal.Schema != 1 || len(journal.Events) > diagnosticEventLimit {
		source.Status = "invalid"
		source.Reason = "journal_invalid_or_oversize"
		return source
	}
	source.Status = "available"
	source.Reason = ""
	source.Journal = &journal
	return source
}
func diagnosticBundle(home string) (string, error) { return diagnosticBundleForContext(home, nil) }
func diagnosticBundleForContext(home string, contextCollected *bool) (string, error) {
	sources := []diagnosticSource{}
	for _, lane := range []string{"host", "kernel"} {
		for _, generation := range []string{"older", "previous", "current"} {
			source := readDiagnosticSource(filepath.Join(home, "diagnostics"), lane+"-"+generation)
			if generation == "current" {
				diagnosticStoresMu.Lock()
				live := diagnosticStores[home+"/"+lane]
				diagnosticStoresMu.Unlock()
				if live != nil {
					live.mu.Lock()
					source.LiveWriteFailures = live.journal.WriteFailures
					persisted := uint64(0)
					if source.Journal != nil && len(source.Journal.Events) > 0 {
						persisted = source.Journal.Events[len(source.Journal.Events)-1].Sequence
					}
					if len(live.journal.Events) > 0 {
						source.UnpersistedEvents = live.journal.Events[len(live.journal.Events)-1].Sequence - persisted
					}
					live.mu.Unlock()
				}
			}
			sources = append(sources, source)
		}
	}
	bundle := map[string]any{"schema": "cexing-support-bundle/1", "exportedAt": time.Now().UTC().Format(time.RFC3339Nano),
		"limits": map[string]int{"journalBytes": diagnosticJournalLimit, "eventsPerJournal": diagnosticEventLimit, "sessionsPerLane": 3, "bundleBytes": diagnosticBundleLimit},
		"policy": map[string]any{"upload": false, "rawConfiguration": false, "requestBodies": false, "successfulTrafficHistory": false, "objectIdentity": "installation-keyed-hmac-at-rest; independently-salted-per-export; keys never exported", "retention": "current and two previous process sessions; oldest evicted at next process boot", "missingEvidence": "before first instrumented boot, absent lanes and dropped/write-failed events are unknown; not healthy", "failedLogRateLimit": "8 per second; suppressed counter persisted at next write; last second can be missing after hard kill", "bandwidthTest": "not_executed: requires explicit user action; probes do not measure bandwidth"}, "sources": sources, "exportContextCollected": contextCollected, "selectedVersion": diagnosticReadVersion(home), "checkCoverage": diagnosticCheckCoverage(sources)}
	data, err := json.MarshalIndent(bundle, "", "  ")
	if err != nil {
		return "", err
	}
	for len(data) > diagnosticBundleLimit {
		removed := false
		for i := range sources {
			if sources[i].Journal != nil && len(sources[i].Journal.Events) > 0 {
				sources[i].Journal.Events = sources[i].Journal.Events[1:]
				sources[i].ExportOmitted++
				removed = true
				break
			}
		}
		if !removed {
			return "", errors.New("DIAGNOSTICS_BUNDLE_LIMIT")
		}
		bundle["sources"] = sources
		data, err = json.MarshalIndent(bundle, "", "  ")
		if err != nil {
			return "", err
		}
	}
	exportKey := make([]byte, 32)
	if _, err = rand.Read(exportKey); err != nil {
		return "", errors.New("DIAGNOSTICS_EXPORT_RANDOM_FAILED")
	}
	objects := regexp.MustCompile(`object-[0-9a-f]{16}`)
	text := objects.ReplaceAllStringFunc(string(data), func(value string) string {
		h := hmac.New(sha256.New, exportKey)
		h.Write([]byte(value))
		return "object-" + hex.EncodeToString(h.Sum(nil))[:16]
	})
	return text, nil
}
func kernelDiagnostic(stage, outcome string, err error, details map[string]any) {
	s, e := getDiagnosticStore(homeDir, "kernel")
	if e != nil {
		return
	}
	_ = s.record(diagnosticEvent{Operation: "vpn", Stage: stage, Outcome: outcome, Error: s.failure(err, 0), Details: details})
}

// Persist operational and failed dial/DNS logs only. Successful traffic and
// general upstream logs never enter the support evidence stream.
func kernelDiagnosticLog(level, payload string) {
	eligible := strings.HasPrefix(payload, "[OHOS]") || strings.HasPrefix(payload, "[TCP] dial ") || strings.HasPrefix(payload, "[UDP] dial ") || strings.HasPrefix(payload, "[UDP] Resolve Ip error:") || strings.HasPrefix(payload, "Start DNS server") || strings.HasPrefix(payload, "[DNS]")
	if !eligible || (level != "warning" && level != "error") {
		return
	}
	s, err := getDiagnosticStore(homeDir, "kernel")
	if err != nil {
		return
	}
	s.mu.Lock()
	now := time.Now()
	if now.Sub(s.logWindow) >= time.Second {
		s.logWindow = now
		s.logCount = 0
	}
	if s.logCount >= 8 {
		s.journal.LogSuppressed++
		s.mu.Unlock()
		return
	}
	s.logCount++
	s.mu.Unlock()
	_ = s.record(diagnosticEvent{Operation: "core", Stage: "runtime_error", Outcome: level, Error: &diagnosticError{Kind: "core_log", Message: s.text(payload)}})
}

// Values from the runtime input are used in memory only to redact bare node
// labels and credentials in upstream causes. Never persist this mapping.
func (s *diagnosticStore) registerPrivateConfig(input map[string]any) {
	values := map[string]string{}
	var walk func(any, bool, string)
	walk = func(value any, sensitive bool, key string) {
		switch v := value.(type) {
		case map[string]any:
			for k, item := range v {
				lower := strings.ToLower(k)
				private := sensitive || strings.Contains(lower, "password") || strings.Contains(lower, "secret") || strings.Contains(lower, "token") || strings.Contains(lower, "uuid") || strings.Contains(lower, "auth") || strings.Contains(lower, "key") || strings.Contains(lower, "headers") || lower == "username" || lower == "private-key"
				walk(item, private, lower)
			}
		case []any:
			for _, item := range v {
				walk(item, sensitive, key)
			}
		case string:
			if len(v) == 0 {
				return
			}
			if sensitive {
				values[v] = "[redacted]"
			} else if key == "name" || key == "server" || key == "dialer-proxy" {
				if values[v] != "[redacted]" {
					values[v] = s.object(v)
				}
			}
		}
	}
	walk(input, false, "")
	keys := []string{}
	for key := range values {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool { return len(keys[i]) > len(keys[j]) })
	pairs := []string{}
	for _, key := range keys {
		pairs = append(pairs, key, values[key])
	}
	s.privacyMu.Lock()
	s.privateValues = strings.NewReplacer(pairs...)
	s.privacyMu.Unlock()
}

func diagnosticCheckCoverage(sources []diagnosticSource) map[string]any {
	coverage := map[string]any{}
	for _, kind := range []string{"controller", "dns", "connection", "delay", "bandwidth"} {
		evidence := []map[string]any{}
		for _, source := range sources {
			if source.Journal == nil {
				continue
			}
			for _, event := range source.Journal.Events {
				if event.Operation == "check_"+kind {
					evidence = append(evidence, map[string]any{"source": source.Name, "at": event.At, "stage": event.Stage, "outcome": event.Outcome, "reason": event.Reason})
				}
			}
		}
		if len(evidence) == 0 {
			coverage[kind] = map[string]any{"outcome": "unknown", "reason": "no_retained_result; not proof check was never executed"}
		} else {
			coverage[kind] = evidence
		}
	}
	return coverage
}
