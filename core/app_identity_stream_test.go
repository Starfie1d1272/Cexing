package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"testing"
	"time"

	MHTTP "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
)

func TestAppIdentityBatchCredits(t *testing.T) {
	s := routeTestSession(t)
	base := time.Now().Add(identityTTL)
	for i := 0; i < 256; i++ {
		id := fmt.Sprintf("%03d", i)
		s.pending[id] = &appIdentityPending{request: appIdentityRequest{ID: id}, deadline: base.Add(time.Duration(i)), result: make(chan int64, 1)}
	}
	var first appIdentityBatch
	for i := 0; i < 4; i++ {
		batch, alive := s.takeIdentityBatch()
		if !alive || len(batch.Requests) != 32 || batch.Requests[0].ID != fmt.Sprintf("%03d", i*32) {
			t.Fatal("batch order or bound changed")
		}
		if i == 0 {
			first = batch
		}
	}
	if batch, _ := s.takeIdentityBatch(); len(batch.Requests) != 0 {
		t.Fatal("exceeded host credit")
	}
	replies := []appIdentityReply{}
	for _, request := range first.Requests {
		replies = append(replies, appIdentityReply{ID: request.ID, UID: 10001, Status: "uid"})
	}
	postAppIdentityReplies(&routeRecorder{}, routeRequest(map[string]any{"session": s.id, "replies": replies}))
	select {
	case <-s.identityWake:
	default:
		t.Fatal("reply did not wake writer")
	}
	batch, _ := s.takeIdentityBatch()
	if len(batch.Requests) != 32 || batch.Requests[0].ID != "128" {
		t.Fatal("released credits did not drain oldest requests")
	}
}
func identityPollRequest(ctx context.Context) *MHTTP.Request {
	return (&MHTTP.Request{Method: "GET", URL: &url.URL{RawQuery: "transport=poll"}}).WithContext(ctx)
}
func waitIdentityConsumer(t *testing.T, s *appTrafficSession) {
	t.Helper()
	end := time.Now().Add(time.Second)
	for time.Now().Before(end) {
		s.mu.Lock()
		active := s.consumer
		s.mu.Unlock()
		if active {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("consumer did not start")
}
func TestAppIdentityPollGap(t *testing.T) {
	s := routeTestSession(t)
	// A successful response establishes availability across consecutive HTTP requests.
	s.pending["warmup"] = &appIdentityPending{request: appIdentityRequest{ID: "warmup"}, deadline: time.Now().Add(identityTTL)}
	getAppIdentityRequests(&routeRecorder{}, identityPollRequest(context.Background()))
	s.mu.Lock()
	delete(s.pending, "warmup")
	active := s.consumer
	available := s.identityAvailableLocked()
	s.mu.Unlock()
	if active || !available {
		t.Fatal("poll gap must release reader and retain bounded availability")
	}
	for _, network := range []C.NetWork{C.TCP, C.UDP} {
		metadata := routeTestMetadata(s, network)
		done := make(chan error, 1)
		go func() { _, err := resolveAppRoute(metadata); done <- err }()
		deadline := time.Now().Add(time.Second)
		queued := false
		for time.Now().Before(deadline) {
			s.mu.Lock()
			queued = len(s.pending) > 0
			s.mu.Unlock()
			if queued {
				break
			}
			time.Sleep(time.Millisecond)
		}
		if !queued {
			t.Fatal("query was lost between polls")
		}
		r := &routeRecorder{}
		getAppIdentityRequests(r, identityPollRequest(context.Background()))
		var batch appIdentityBatch
		if json.Unmarshal(r.Bytes(), &batch) != nil || len(batch.Requests) != 1 {
			t.Fatal("poll did not return queued identity")
		}
		postAppIdentityReplies(&routeRecorder{}, routeRequest(map[string]any{"session": s.id, "replies": []appIdentityReply{{ID: batch.Requests[0].ID, UID: 10001, Status: "uid"}}}))
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		if metadata.TrackerContext.(*appRouteContext).uid != 10001 {
			t.Fatal("poll query lost identity")
		}
	}
	s.mu.Lock()
	s.pollUntil = time.Now().Add(-time.Second)
	s.mu.Unlock()
	if _, err := resolveAppRoute(routeTestMetadata(s, C.TCP)); err != nil {
		t.Fatal(err)
	}
	if len(s.pending) != 0 {
		t.Fatal("expired poll lease accepted unserviceable query")
	}
}
func TestAppIdentityPollCancellationAndStop(t *testing.T) {
	s := routeTestSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan *routeRecorder, 1)
	go func() { r := &routeRecorder{}; getAppIdentityRequests(r, identityPollRequest(ctx)); done <- r }()
	waitIdentityConsumer(t, s)
	conflict := &routeRecorder{}
	getAppIdentityRequests(conflict, identityPollRequest(context.Background()))
	if conflict.status != 409 {
		t.Fatal("simultaneous consumer accepted")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled poll retained reader")
	}
	s.mu.Lock()
	active := s.consumer
	s.mu.Unlock()
	if active {
		t.Fatal("reader slot retained")
	}
	go func() {
		r := &routeRecorder{}
		getAppIdentityRequests(r, identityPollRequest(context.Background()))
		done <- r
	}()
	waitIdentityConsumer(t, s)
	stopAppTraffic()
	select {
	case r := <-done:
		if r.status != 409 {
			t.Fatal("stopped poll succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("session stop did not wake poll")
	}
}
