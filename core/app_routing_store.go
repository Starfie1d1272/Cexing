package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/tunnel"
)

var errAppRouteCommitUncertain = errors.New("source route durability uncertain")

const appRouteLimit = 2048
const appRouteFileLimit = 3 * 1024 * 1024

type savedAppRoute struct {
	UID    int64  `json:"uid"`
	Target string `json:"target"`
}
type appRouteFile struct {
	Version int             `json:"version"`
	Rules   []savedAppRoute `json:"rules"`
}
type appRouteStore struct {
	mu       sync.Mutex
	path     string
	policies map[int64]string
	status   string
	blocked  bool
}

var durableAppRoutes = appRouteStore{policies: make(map[int64]string), status: "readError", blocked: true}

func cloneAppPolicies(source map[int64]string) map[int64]string {
	result := make(map[int64]string, len(source))
	for uid, target := range source {
		result[uid] = target
	}
	return result
}
func appPolicyEntries(policies map[int64]string) []savedAppRoute {
	result := make([]savedAppRoute, 0, len(policies))
	for uid, target := range policies {
		result = append(result, savedAppRoute{uid, target})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].UID < result[j].UID })
	return result
}
func validAppRouteTarget(target string) bool {
	return len(target) > 0 && len(target) <= 256 && !strings.ContainsAny(target, "\x00\r\n")
}
func (store *appRouteStore) loadLocked() {
	input, err := os.Open(store.path)
	var data []byte
	if err == nil {
		data, err = io.ReadAll(io.LimitReader(input, appRouteFileLimit+1))
		input.Close()
	}
	if errors.Is(err, os.ErrNotExist) {
		store.policies = make(map[int64]string)
		store.status = "ready"
		store.blocked = false
		return
	}
	if err != nil {
		store.status = "readError"
		store.blocked = true
		return
	}
	var file struct {
		Version int `json:"version"`
		Rules   []struct {
			UID    *int64 `json:"uid"`
			Target string `json:"target"`
		} `json:"rules"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if len(data) > appRouteFileLimit || decoder.Decode(&file) != nil || decoder.Decode(new(any)) != io.EOF || file.Version != 1 || file.Rules == nil || len(file.Rules) > appRouteLimit {
		store.status = "corrupt"
		store.blocked = true
		return
	}
	next := make(map[int64]string, len(file.Rules))
	for _, rule := range file.Rules {
		if rule.UID == nil || *rule.UID < 0 || *rule.UID > 2147483647 || !validAppRouteTarget(rule.Target) || next[*rule.UID] != "" {
			store.status = "corrupt"
			store.blocked = true
			return
		}
		next[*rule.UID] = rule.Target
	}
	store.policies = next
	store.status = "ready"
	store.blocked = false
}
func initAppRouteStore(home string) {
	durableAppRoutes.mu.Lock()
	defer durableAppRoutes.mu.Unlock()
	path := filepath.Join(home, "uid-routes-v1.json")
	if path != durableAppRoutes.path {
		durableAppRoutes.policies = make(map[int64]string)
	}
	durableAppRoutes.path = path
	durableAppRoutes.loadLocked()
}
func appRouteStoreSnapshot() (map[int64]string, bool) {
	durableAppRoutes.mu.Lock()
	defer durableAppRoutes.mu.Unlock()
	return cloneAppPolicies(durableAppRoutes.policies), durableAppRoutes.blocked
}

// The rename is the commit point. Before it, errors leave both disk and active policies intact.
func writeAppRouteFile(path string, policies map[int64]string) error {
	data, err := json.Marshal(appRouteFile{Version: 1, Rules: appPolicyEntries(policies)})
	if err != nil {
		return err
	}
	if len(data) > appRouteFileLimit {
		return errors.New("source route file capacity reached")
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".uid-routes-*")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if _, err = temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err = temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err = temp.Close(); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	// Probe directory sync before changing the authoritative file.
	if err = dir.Sync(); err != nil {
		return err
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	if err = dir.Sync(); err != nil {
		return errAppRouteCommitUncertain
	}
	return nil
}
func (store *appRouteStore) saveLocked(policies map[int64]string) error {
	if store.blocked || store.path == "" {
		return errors.New("source route storage unavailable")
	}
	if len(policies) > appRouteLimit {
		return errors.New("source route capacity reached")
	}
	if err := writeAppRouteFile(store.path, policies); err != nil {
		store.status = "writeError"
		if errors.Is(err, errAppRouteCommitUncertain) {
			store.blocked = true
		}
		return err
	}
	store.policies = cloneAppPolicies(policies)
	store.status = "ready"
	return nil
}
func appRouteAvailable(target string) bool {
	if target == "" || target == "DIRECT" {
		return true
	}
	for _, candidate := range tunnel.HostRouteTargets() {
		if candidate == target {
			return true
		}
	}
	return false
}
func getAppRoutes(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	type visibleRule struct {
		UID       int64  `json:"uid"`
		Target    string `json:"target"`
		Available bool   `json:"available"`
	}
	response := struct {
		SchemaVersion int           `json:"schemaVersion"`
		Session       string        `json:"session"`
		State         string        `json:"state"`
		Storage       string        `json:"storage"`
		Blocked       bool          `json:"blocked"`
		Rules         []visibleRule `json:"rules"`
		RouteTargets  []string      `json:"routeTargets"`
	}{SchemaVersion: 1, State: "unavailable", Rules: []visibleRule{}, RouteTargets: tunnel.HostRouteTargets()}
	if s := appTrafficCurrent.Load(); s != nil {
		s.mu.Lock()
		response.Session = s.id
		response.State = "running"
		if s.stopped {
			response.State = "closed"
		}
		s.mu.Unlock()
	}
	durableAppRoutes.mu.Lock()
	response.Storage = durableAppRoutes.status
	response.Blocked = durableAppRoutes.blocked
	entries := appPolicyEntries(durableAppRoutes.policies)
	durableAppRoutes.mu.Unlock()
	available := make(map[string]bool, len(response.RouteTargets))
	for _, target := range response.RouteTargets {
		available[target] = true
	}
	for _, rule := range entries {
		response.Rules = append(response.Rules, visibleRule{rule.UID, rule.Target, available[rule.Target]})
	}
	sort.Strings(response.RouteTargets)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}
func recoverAppRoutes(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var body struct {
		Session string `json:"session"`
		Action  string `json:"action"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 4097))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF || (body.Action != "retry" && body.Action != "reset") {
		controllerError(w, 400, "invalid route recovery")
		return
	}
	s := appTrafficCurrent.Load()
	if s == nil {
		controllerError(w, 409, "traffic session unavailable")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped || s.id != body.Session || s != appTrafficCurrent.Load() {
		controllerError(w, 409, "traffic session ended")
		return
	}
	durableAppRoutes.mu.Lock()
	defer durableAppRoutes.mu.Unlock()
	if body.Action == "retry" {
		durableAppRoutes.loadLocked()
	} else {
		if err := durableAppRoutes.resetLocked(); err != nil {
			s.routesBlocked = durableAppRoutes.blocked
			controllerError(w, 503, "source route recovery failed")
			return
		}
	}
	s.policies = cloneAppPolicies(durableAppRoutes.policies)
	s.routesBlocked = durableAppRoutes.blocked
	if durableAppRoutes.blocked {
		controllerError(w, 503, "source route storage unavailable")
		return
	}
	w.WriteHeader(MHTTP.StatusNoContent)
}
func (store *appRouteStore) resetLocked() error {
	// Preserve the original bytes before an explicit reset, including malformed data.
	input, err := os.Open(store.path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		store.status = "readError"
		return err
	}
	if err == nil {
		defer input.Close()
		backup, err := os.CreateTemp(filepath.Dir(store.path), "uid-routes-backup-*")
		if err != nil {
			return err
		}
		name := backup.Name()
		if _, err = io.Copy(backup, input); err != nil {
			backup.Close()
			os.Remove(name)
			return err
		}
		if err = backup.Sync(); err != nil {
			backup.Close()
			os.Remove(name)
			return err
		}
		if err = backup.Close(); err != nil {
			os.Remove(name)
			return err
		}
	}
	next := make(map[int64]string)
	if err := writeAppRouteFile(store.path, next); err != nil {
		store.status = "writeError"
		if errors.Is(err, errAppRouteCommitUncertain) {
			store.blocked = true
		}
		return err
	}
	store.policies = next
	store.status = "ready"
	store.blocked = false
	return nil
}
