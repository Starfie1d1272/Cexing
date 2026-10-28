package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	HTTP "net/http"
	"net/netip"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

const identityLimit = 256
const identityBatchLimit = 32
const identityTTL = 8 * time.Second

// The handle, not the live manager map, owns accounting. Close never adds a
// final total: IO already in flight may still call Add after Close.
type appTrafficHandle struct {
	session          *appTrafficSession
	row              *appTrafficRow
	route            string
	upload, download int64
	closed           bool
}
type appTrafficBytes struct {
	Upload      int64 `json:"upload"`
	Download    int64 `json:"download"`
	Connections int64 `json:"connections"`
	Active      int64 `json:"active"`
}
type appTrafficRoutes struct {
	Proxy        appTrafficBytes `json:"proxy"`
	Direct       appTrafficBytes `json:"direct"`
	Unclassified appTrafficBytes `json:"unclassified"`
}

func (r *appTrafficRoutes) bucket(route string) *appTrafficBytes {
	switch route {
	case "proxy":
		return &r.Proxy
	case "direct":
		return &r.Direct
	default:
		return &r.Unclassified
	}
}

type appTrafficReason struct {
	id     string
	At     int64    `json:"at"`
	Route  string   `json:"route"`
	Rule   string   `json:"rule"`
	Policy []string `json:"policy"`
}
type appTrafficRow struct {
	BundleVerified bool               `json:"bundleVerified"` // No public cross-UID bundle verification route is available.
	IdentityStatus string             `json:"identityStatus"`
	UID            int64              `json:"uid"`
	BundleName     string             `json:"bundleName"`
	Routes         appTrafficRoutes   `json:"routes"`
	Recent         []appTrafficReason `json:"recent"`
}
type appTrafficSummary struct {
	SchemaVersion    int              `json:"schemaVersion"`
	Session          string           `json:"session"`
	State            string           `json:"state"` // running or closed; no offline checkpoint
	StartedAt        int64            `json:"startedAt"`
	EndedAt          int64            `json:"endedAt"`
	Partial          bool             `json:"partial"`
	Totals           appTrafficRoutes `json:"totals"`
	Apps             []appTrafficRow  `json:"apps"`
	IdentityFailures map[string]int64 `json:"identityFailures"`
}
type appIdentityAddress struct {
	Address string `json:"address"`
	Port    uint16 `json:"port"`
	Family  int    `json:"family"`
}
type appIdentityRequest struct {
	ID       string             `json:"id"`
	Protocol string             `json:"protocol"`
	Local    appIdentityAddress `json:"local"`
	Remote   appIdentityAddress `json:"remote"`
}
type appIdentityPending struct {
	request  appIdentityRequest
	handle   *appTrafficHandle
	reason   appTrafficReason
	deadline time.Time
	sent     bool
}
type appIdentityBatch struct {
	Session  string               `json:"session"`
	Requests []appIdentityRequest `json:"requests"`
}
type appIdentityReply struct {
	ID     string `json:"id"`
	UID    int64  `json:"uid"`
	Status string `json:"status"`
}
type appTrafficSession struct {
	mu                 sync.Mutex
	id                 string
	startedAt, endedAt int64
	stopped, consumer  bool
	rows               map[string]*appTrafficRow
	pending            map[string]*appIdentityPending
	failures           map[string]int64
}

var appTrafficCurrent atomic.Pointer[appTrafficSession]

func init() {
	statistic.SetTrackerObserver(observeAppTraffic)
	route.Register(func(r chi.Router) {
		r.Get("/ohos/app-traffic", getAppTraffic)
		r.Get("/ohos/app-traffic/identity", getAppIdentityRequests)
		r.Post("/ohos/app-traffic/identity", postAppIdentityReplies)
	})
}

// Called under runLock before the TUN accepts packets. Aggregates and recent
// explanations live only in memory; a new session replaces the previous one.
func startAppTraffic() *appTrafficSession {
	s := &appTrafficSession{id: controllerSession, startedAt: time.Now().UnixMilli(),
		rows: make(map[string]*appTrafficRow), pending: make(map[string]*appIdentityPending), failures: make(map[string]int64)}
	s.rows[""] = &appTrafficRow{IdentityStatus: "unknown", UID: -1, Recent: []appTrafficReason{}}
	appTrafficCurrent.Store(s)
	return s
}
func stopAppTraffic() {
	if s := appTrafficCurrent.Load(); s != nil {
		s.mu.Lock()
		if !s.stopped {
			s.stopped = true
			s.endedAt = time.Now().UnixMilli()
			s.failures["sessionEnded"] += int64(len(s.pending))
			clear(s.pending)
		}
		s.mu.Unlock()
	}
}

func rawIdentityAddress(addr net.Addr) (appIdentityAddress, bool) {
	var tuple netip.AddrPort
	switch a := addr.(type) {
	case *net.TCPAddr:
		tuple = a.AddrPort()
	case *net.UDPAddr:
		tuple = a.AddrPort()
	}
	if !tuple.IsValid() || tuple.Port() == 0 || tuple.Addr().IsUnspecified() {
		return appIdentityAddress{}, false
	}
	ip := tuple.Addr().Unmap()
	family := 1
	if ip.Is6() {
		family = 2
	}
	return appIdentityAddress{Address: ip.String(), Port: tuple.Port(), Family: family}, true
}
func observeAppTraffic(info *statistic.TrackerInfo) statistic.TrackerObserver {
	if info.Metadata == nil || info.Metadata.Type != C.TUN {
		return nil
	}
	s, ok := info.Metadata.TrackerContext.(*appTrafficSession)
	if !ok || s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	kind := info.TrafficRoute
	if kind != "proxy" && kind != "direct" {
		kind = "unclassified"
	}
	h := &appTrafficHandle{session: s, row: s.rows[""], route: kind}
	b := h.row.Routes.bucket(kind)
	b.Connections++
	b.Active++
	reason := appTrafficReason{id: info.UUID.String(), At: info.Start.UnixMilli(), Route: kind, Rule: info.Rule, Policy: []string{}}
	for i, name := range info.Chain {
		if i >= 8 {
			break
		}
		if len(name) <= 256 {
			reason.Policy = append(reason.Policy, name)
		}
	}
	addAppTrafficReason(h.row, reason)
	if s.stopped {
		s.failures["sessionEnded"]++
		return h
	}
	local, localOK := rawIdentityAddress(info.Metadata.RawSrcAddr)
	remote, remoteOK := rawIdentityAddress(info.Metadata.RawDstAddr)
	if !localOK || !remoteOK {
		s.failures["missingTuple"]++
		return h
	}
	if len(s.pending) >= identityLimit {
		s.expireLocked()
	}
	if len(s.pending) >= identityLimit {
		s.failures["overflow"]++
		return h
	}
	protocol := info.Metadata.NetWork.String()
	if protocol != "tcp" && protocol != "udp" {
		s.failures["unsupported"]++
		return h
	}
	id := info.UUID.String()
	s.pending[id] = &appIdentityPending{request: appIdentityRequest{ID: id, Protocol: protocol, Local: local, Remote: remote},
		handle: h, reason: reason, deadline: time.Now().Add(identityTTL)}
	return h
}
func addAppTrafficReason(row *appTrafficRow, reason appTrafficReason) {
	if len(row.Recent) == 4 {
		copy(row.Recent, row.Recent[1:])
		row.Recent = row.Recent[:3]
	}
	row.Recent = append(row.Recent, reason)
}
func (h *appTrafficHandle) Add(upload, download int64) {
	if upload <= 0 && download <= 0 {
		return
	}
	s := h.session
	s.mu.Lock()
	defer s.mu.Unlock()
	b := h.row.Routes.bucket(h.route)
	if upload > 0 {
		h.upload += upload
		b.Upload += upload
	}
	if download > 0 {
		h.download += download
		b.Download += download
	}
}
func (h *appTrafficHandle) Close() {
	s := h.session
	s.mu.Lock()
	defer s.mu.Unlock()
	if !h.closed {
		h.closed = true
		h.row.Routes.bucket(h.route).Active--
	}
}
func (s *appTrafficSession) expireLocked() {
	now := time.Now()
	for id, p := range s.pending {
		if !now.Before(p.deadline) {
			delete(s.pending, id)
			s.failures["timeout"]++
		}
	}
}
func (s *appTrafficSession) snapshotLocked() appTrafficSummary {
	s.expireLocked()
	result := appTrafficSummary{SchemaVersion: 1, Session: s.id, State: "running", StartedAt: s.startedAt,
		EndedAt: s.endedAt, Apps: []appTrafficRow{}, IdentityFailures: make(map[string]int64)}
	if s.stopped {
		result.State = "closed"
	}
	for key, value := range s.failures {
		result.IdentityFailures[key] = value
	}
	for _, row := range s.rows {
		copied := *row
		copied.Recent = []appTrafficReason{}
		copied.Recent = append(copied.Recent, row.Recent...)
		result.Apps = append(result.Apps, copied)
		for _, route := range []string{"proxy", "direct", "unclassified"} {
			dst, src := result.Totals.bucket(route), row.Routes.bucket(route)
			dst.Upload += src.Upload
			dst.Download += src.Download
			dst.Connections += src.Connections
			dst.Active += src.Active
		}
	}
	// A normal stop with outstanding trackers still has an unconfirmed tail.
	result.Partial = s.stopped && result.Totals.Proxy.Active+result.Totals.Direct.Active+result.Totals.Unclassified.Active > 0
	sort.Slice(result.Apps, func(i, j int) bool { return result.Apps[i].UID < result.Apps[j].UID })
	return result
}

func getAppTraffic(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	s := appTrafficCurrent.Load()
	if s == nil {
		controllerError(w, 409, "traffic session unavailable")
		return
	}
	s.mu.Lock()
	snapshot := s.snapshotLocked()
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
}

func getAppIdentityRequests(w MHTTP.ResponseWriter, req *MHTTP.Request) {
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
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	standard := (&HTTP.Request{Method: req.Method, URL: req.URL, Host: req.Host, Header: HTTP.Header(req.Header),
		Proto: req.Proto, ProtoMajor: req.ProtoMajor, ProtoMinor: req.ProtoMinor, RemoteAddr: req.RemoteAddr, Body: req.Body}).WithContext(ctx)
	conn, err := websocket.Accept(controllerWSWriter{w}, standard, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(1024)
	ctx = conn.CloseRead(ctx)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		s.mu.Lock()
		if s.stopped || s != appTrafficCurrent.Load() {
			s.mu.Unlock()
			return
		}
		s.expireLocked()
		batch := appIdentityBatch{Session: s.id, Requests: []appIdentityRequest{}}
		for _, p := range s.pending {
			if !p.sent {
				p.sent = true
				batch.Requests = append(batch.Requests, p.request)
				if len(batch.Requests) == identityBatchLimit {
					break
				}
			}
		}
		s.mu.Unlock()
		// Empty batches are heartbeat frames; the host bounds outstanding work itself.
		data, _ := json.Marshal(batch)
		writeCtx, done := context.WithTimeout(ctx, 2*time.Second)
		err := conn.Write(writeCtx, websocket.MessageText, data)
		done()
		if err != nil {
			return
		}
	}
}
func postAppIdentityReplies(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var body struct {
		Session string             `json:"session"`
		Replies []appIdentityReply `json:"replies"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 32*1024+1))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF || len(body.Replies) > identityBatchLimit {
		controllerError(w, 400, "invalid identity batch")
		return
	}
	s := appTrafficCurrent.Load()
	if s == nil {
		controllerError(w, 409, "traffic session unavailable")
		return
	}
	s.mu.Lock()
	if s.stopped || s.id != body.Session {
		s.mu.Unlock()
		controllerError(w, 409, "traffic session ended")
		return
	}
	s.expireLocked()
	for _, reply := range body.Replies {
		p, ok := s.pending[reply.ID]
		if !ok || !p.sent {
			continue
		}
		delete(s.pending, reply.ID) // duplicates and late replies cannot move bytes twice
		if reply.Status != "uid" || reply.UID < 0 {
			status := reply.Status
			switch status {
			case "unsupported", "notFound", "error", "timeout":
			default:
				status = "error"
			}
			s.failures[status]++
			continue
		}
		key := strconv.FormatInt(reply.UID, 10)
		row := s.rows[key]
		if row == nil {
			if len(s.rows) >= 129 {
				s.failures["overflow"]++
				continue
			}
			row = &appTrafficRow{IdentityStatus: "uid", UID: reply.UID, Recent: []appTrafficReason{}}
			s.rows[key] = row
		}
		h := p.handle
		from, to := h.row.Routes.bucket(h.route), row.Routes.bucket(h.route)
		from.Upload -= h.upload
		from.Download -= h.download
		from.Connections--
		to.Upload += h.upload
		to.Download += h.download
		to.Connections++
		if !h.closed {
			from.Active--
			to.Active++
		}
		for i, reason := range h.row.Recent {
			if reason.id == reply.ID {
				h.row.Recent = append(h.row.Recent[:i], h.row.Recent[i+1:]...)
				break
			}
		}
		h.row = row
		addAppTrafficReason(row, p.reason)
	}
	s.mu.Unlock()
	w.WriteHeader(MHTTP.StatusNoContent)
}
