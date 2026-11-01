package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func putSavedRoute(s *appTrafficSession, uid int64, target string) int {
	r := &routeRecorder{}
	putAppRoute(r, routeRequest(map[string]any{"session": s.id, "uid": uid, "target": target}))
	return r.status
}
func TestAppRouteDurableColdFirstPacket(t *testing.T) {
	for _, network := range []C.NetWork{C.TCP, C.UDP} {
		t.Run(network.String(), func(t *testing.T) {
			s := routeTestSession(t)
			s.rowLocked(10001)
			if status := putSavedRoute(s, 10001, "DIRECT"); status != 204 {
				t.Fatalf("save %d", status)
			}
			path := durableAppRoutes.path
			stopAppTraffic()
			initAppRouteStore(filepath.Dir(path))
			s = startAppTraffic()
			s.id = "reconnected"
			s.consumer = true
			if s.rows["10001"] != nil {
				t.Fatal("test requires no observed row")
			}
			result := make(chan string, 1)
			go func() {
				target, err := resolveAppRoute(routeTestMetadata(s, network))
				if err != nil {
					result <- "error"
				} else {
					result <- target
				}
			}()
			id, _ := awaitRoutePending(t, s)
			postAppIdentityReplies(&routeRecorder{}, routeRequest(map[string]any{"session": s.id, "replies": []appIdentityReply{{ID: id, UID: 10001, Status: "uid"}}}))
			if target := <-result; target != "DIRECT" {
				t.Fatalf("first packet missed saved rule: %q", target)
			}
			if status := putSavedRoute(s, 10001, ""); status != 204 {
				t.Fatalf("unobserved saved UID delete %d", status)
			}
			initAppRouteStore(filepath.Dir(path))
			policies, blocked := appRouteStoreSnapshot()
			if blocked || len(policies) != 0 {
				t.Fatal("follow did not persist deletion")
			}
		})
	}
}
func TestAppRouteWriteFailureDoesNotPublish(t *testing.T) {
	s := routeTestSession(t)
	s.rowLocked(10001)
	if status := putSavedRoute(s, 10001, "DIRECT"); status != 204 {
		t.Fatal(status)
	}
	path := durableAppRoutes.path
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// An impossible parent is deterministic even when the test runs as root.
	durableAppRoutes.path = filepath.Join(path, "child.json")
	if status := putSavedRoute(s, 10001, ""); status != 503 {
		t.Fatal(status)
	}
	if s.policies[10001] != "DIRECT" || durableAppRoutes.policies[10001] != "DIRECT" {
		t.Fatal("failed write published removal")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("failed save changed original")
	}
	durableAppRoutes.path = path
	if status := putSavedRoute(s, 10001, ""); status != 204 {
		t.Fatal(status)
	}
}
func TestAppRouteCorruptPreservationAndRecovery(t *testing.T) {
	s := routeTestSession(t)
	path := durableAppRoutes.path
	bad := []byte(`{"version":1,"rules":[{"uid":1,"target":"DIRECT"},{"uid":1,"target":"DIRECT"}]}`)
	if err := os.WriteFile(path, bad, 0600); err != nil {
		t.Fatal(err)
	}
	initAppRouteStore(filepath.Dir(path))
	s = startAppTraffic()
	s.id = "corrupt"
	if !s.routesBlocked || durableAppRoutes.status != "corrupt" {
		t.Fatal("corruption not surfaced")
	}
	if _, err := resolveAppRoute(routeTestMetadata(s, C.TCP)); err == nil {
		t.Fatal("unloaded rules silently bypassed")
	}
	s.rowLocked(10001)
	if status := putSavedRoute(s, 10001, "DIRECT"); status != 503 {
		t.Fatal(status)
	}
	r := &routeRecorder{}
	recoverAppRoutes(r, routeRequest(map[string]any{"session": s.id, "action": "retry"}))
	if r.status != 503 {
		t.Fatal(r.status)
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(bad) {
		t.Fatal("corruption overwritten by retry")
	}
	r = &routeRecorder{}
	recoverAppRoutes(r, routeRequest(map[string]any{"session": s.id, "action": "reset"}))
	if r.status != 204 || s.routesBlocked {
		t.Fatal("explicit reset failed")
	}
	backups, _ := filepath.Glob(filepath.Join(filepath.Dir(path), "uid-routes-backup-*"))
	if len(backups) != 1 {
		t.Fatal("missing preserved original")
	}
	backup, _ := os.ReadFile(backups[0])
	if string(backup) != string(bad) {
		t.Fatal("backup bytes differ")
	}
	initAppRouteStore(filepath.Dir(path))
	if durableAppRoutes.blocked {
		t.Fatal("reset not durable")
	}
}
func TestAppRouteMissingTargetRemainsManageable(t *testing.T) {
	s := routeTestSession(t)
	path := durableAppRoutes.path
	if err := writeAppRouteFile(path, map[int64]string{10001: "removed-group"}); err != nil {
		t.Fatal(err)
	}
	initAppRouteStore(filepath.Dir(path))
	s = startAppTraffic()
	s.id = "missing-target"
	if _, err := s.routeLocked(10001); err == nil {
		t.Fatal("missing target silently followed normal routing")
	}
	if _, err := s.routeLocked(-1); err == nil {
		t.Fatal("unknown identity bypassed saved rule")
	}
	r := &routeRecorder{}
	getAppRoutes(r, routeRequest(nil))
	var view struct {
		Storage string `json:"storage"`
		Rules   []struct {
			UID       int64  `json:"uid"`
			Target    string `json:"target"`
			Available bool   `json:"available"`
		} `json:"rules"`
	}
	if err := json.Unmarshal(r.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if view.Storage != "ready" || len(view.Rules) != 1 || view.Rules[0].Available || view.Rules[0].UID != 10001 {
		t.Fatalf("saved rule not manageable: %s", r.Bytes())
	}
	if status := putSavedRoute(s, 10001, ""); status != 204 {
		t.Fatal(status)
	}
}
func TestAppRouteReadFailureRetryAndCapacity(t *testing.T) {
	s := routeTestSession(t)
	path := durableAppRoutes.path
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	initAppRouteStore(filepath.Dir(path))
	s = startAppTraffic()
	s.id = "read-error"
	if !s.routesBlocked || durableAppRoutes.status != "readError" {
		t.Fatal("read failure not blocked")
	}
	os.Remove(path)
	r := &routeRecorder{}
	recoverAppRoutes(r, routeRequest(map[string]any{"session": s.id, "action": "retry"}))
	if r.status != 204 || s.routesBlocked {
		t.Fatal("retry did not restore missing-file empty state")
	}
	next := make(map[int64]string)
	for uid := int64(0); uid < appRouteLimit; uid++ {
		next[uid] = "DIRECT"
	}
	durableAppRoutes.mu.Lock()
	err := durableAppRoutes.saveLocked(next)
	durableAppRoutes.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	s.policies = cloneAppPolicies(next)
	s.rowLocked(appRouteLimit)
	if status := putSavedRoute(s, appRouteLimit, "DIRECT"); status != 503 {
		t.Fatal(status)
	}
	initAppRouteStore(filepath.Dir(path))
	if len(durableAppRoutes.policies) != appRouteLimit {
		t.Fatal("capacity failure lost rules")
	}
}

func TestAppRouteConcurrentDurableUpdatesAndRejectedContext(t *testing.T) {
	s := routeTestSession(t)
	for uid := int64(1); uid <= 16; uid++ {
		s.rowLocked(uid)
	}
	var workers sync.WaitGroup
	status := make(chan int, 16)
	for uid := int64(1); uid <= 16; uid++ {
		workers.Add(1)
		go func(uid int64) { defer workers.Done(); status <- putSavedRoute(s, uid, "DIRECT") }(uid)
	}
	workers.Wait()
	close(status)
	for code := range status {
		if code != 204 {
			t.Fatal(code)
		}
	}
	initAppRouteStore(filepath.Dir(durableAppRoutes.path))
	if len(durableAppRoutes.policies) != 16 || len(s.policies) != 16 {
		t.Fatal("concurrent saves lost a UID")
	}
	metadata := routeTestMetadata(s, C.UDP)
	if _, err := resolveAppRoute(metadata); err == nil {
		t.Fatal("unknown UID routed")
	}
	if _, err := resolveAppRoute(metadata); err == nil {
		t.Fatal("rejected packet context bypassed on second lookup")
	}
	r := &routeRecorder{}
	recoverAppRoutes(r, routeRequest(map[string]any{"session": "old", "action": "reset"}))
	if r.status != 409 || len(durableAppRoutes.policies) != 16 {
		t.Fatal("stale session reset saved policies")
	}
	stat, err := os.Stat(durableAppRoutes.path)
	if err != nil || stat.Mode().Perm() != 0600 {
		t.Fatal("rules file is not private")
	}
}

func TestAppRouteMalformedFileDoesNotInventUID(t *testing.T) {
	s := routeTestSession(t)
	path := durableAppRoutes.path
	for _, text := range []string{`{"version":1,"rules":[{"target":"DIRECT"}]}`, `{"version":1,"rules":null}`, `{"version":2,"rules":[]}`, `{"version":1,"rules":[{"uid":0,"target":"DIRECT"}],"extra":true}`} {
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		initAppRouteStore(filepath.Dir(path))
		if durableAppRoutes.status != "corrupt" || !durableAppRoutes.blocked {
			t.Fatalf("invalid schema accepted: %s", text)
		}
	}
	_ = s
}

func TestAppRouteEncodedCapacityPreservesFile(t *testing.T) {
	routeTestSession(t)
	path := durableAppRoutes.path
	if err := writeAppRouteFile(path, map[int64]string{1: "DIRECT"}); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(path)
	policies := make(map[int64]string)
	for uid := int64(0); uid < appRouteLimit; uid++ {
		policies[uid] = strings.Repeat("\x01", 256)
	}
	if err := writeAppRouteFile(path, policies); err == nil {
		t.Fatal("encoded file exceeded readable bound")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("oversized encoding replaced durable rules")
	}
}
