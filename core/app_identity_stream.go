package main

import (
	"context"
	"encoding/json"
	HTTP "net/http"
	"sort"
	"time"

	"github.com/coder/websocket"
	MHTTP "github.com/metacubex/http"
)

const identityInFlightLimit = 128
const identityPollWait = time.Second
const identityPollLease = 2 * appRouteIdentityTimeout

func (s *appTrafficSession) wakeIdentity() {
	select {
	case s.identityWake <- struct{}{}:
	default:
	}
}
func (s *appTrafficSession) identityAvailableLocked() bool {
	return s.consumer || time.Now().Before(s.pollUntil)
}

// A single writer drains batches; credit prevents overrunning the host's bounded lookup/reply queue.
func (s *appTrafficSession) takeIdentityBatch() (appIdentityBatch, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	batch := appIdentityBatch{Session: s.id, Requests: []appIdentityRequest{}}
	if s.stopped || s != appTrafficCurrent.Load() {
		return batch, false
	}
	s.expireLocked()
	sent := 0
	pending := make([]*appIdentityPending, 0, len(s.pending))
	for _, p := range s.pending {
		if p.sent {
			sent++
		} else {
			pending = append(pending, p)
		}
	}
	limit := min(identityBatchLimit, identityInFlightLimit-sent)
	if limit <= 0 || len(pending) == 0 {
		return batch, true
	}
	// Oldest deadlines first: a sustained UDP stream cannot starve earlier queries.
	sort.Slice(pending, func(i, j int) bool { return pending[i].deadline.Before(pending[j].deadline) })
	for _, p := range pending[:min(limit, len(pending))] {
		p.sent = true
		batch.Requests = append(batch.Requests, p.request)
	}
	return batch, true
}

func getAppIdentityRequests(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	transport := req.URL.Query().Get("transport")
	if transport != "" && transport != "poll" {
		controllerError(w, 400, "invalid identity transport")
		return
	}
	s := appTrafficCurrent.Load()
	if s == nil {
		controllerError(w, 409, "traffic session unavailable")
		return
	}
	s.mu.Lock()
	if s.stopped || s.consumer {
		s.mu.Unlock()
		controllerError(w, 409, "identity consumer unavailable")
		return
	}
	s.consumer = true
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.consumer = false; s.mu.Unlock() }()
	if transport == "poll" {
		pollAppIdentity(w, req, s)
		return
	}
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	standard := (&HTTP.Request{Method: req.Method, URL: req.URL, Host: req.Host, Header: HTTP.Header(req.Header), Proto: req.Proto, ProtoMajor: req.ProtoMajor, ProtoMinor: req.ProtoMinor, RemoteAddr: req.RemoteAddr, Body: req.Body}).WithContext(ctx)
	conn, err := websocket.Accept(controllerWSWriter{w}, standard, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1024)
	ctx = conn.CloseRead(ctx)
	heartbeat := time.NewTicker(time.Second)
	defer heartbeat.Stop()
	first := true
	for {
		batch, alive := s.takeIdentityBatch()
		if !alive {
			return
		}
		if len(batch.Requests) == 0 && !first {
			select {
			case <-ctx.Done():
				return
			case <-s.identityDone:
				return
			case <-s.identityWake:
				continue
			case <-heartbeat.C:
			}
		}
		first = false
		data, _ := json.Marshal(batch)
		writeCtx, done := context.WithTimeout(ctx, 2*time.Second)
		err = conn.Write(writeCtx, websocket.MessageText, data)
		done()
		if err != nil {
			return
		}
	}
}

func pollAppIdentity(w MHTTP.ResponseWriter, req *MHTTP.Request, s *appTrafficSession) {
	timer := time.NewTimer(identityPollWait)
	defer timer.Stop()
	for {
		batch, alive := s.takeIdentityBatch()
		if !alive {
			controllerError(w, 409, "traffic session ended")
			return
		}
		if len(batch.Requests) == 0 {
			select {
			case <-req.Context().Done():
				return
			case <-s.identityDone:
				controllerError(w, 409, "traffic session ended")
				return
			case <-s.identityWake:
				continue
			case <-timer.C:
			}
		}
		w.Header().Set("Content-Type", "application/json")
		if json.NewEncoder(w).Encode(batch) == nil && req.Context().Err() == nil {
			s.mu.Lock()
			if !s.stopped {
				s.pollUntil = time.Now().Add(identityPollLease)
			}
			s.mu.Unlock()
		}
		return
	}
}
