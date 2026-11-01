package main

import (
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/tunnel"
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
	Target string   `json:"target"`
	Route  string   `json:"route"`
	Rule   string   `json:"rule"`
	Policy []string `json:"policy"`
}
type appTrafficRow struct {
	LastSeen       int64              `json:"lastSeen"`
	RouteTarget    string             `json:"routeTarget"`
	BundleVerified bool               `json:"bundleVerified"` // No public cross-UID bundle verification route is available.
	IdentityStatus string             `json:"identityStatus"`
	UID            int64              `json:"uid"`
	BundleName     string             `json:"bundleName"`
	Routes         appTrafficRoutes   `json:"routes"`
	Recent         []appTrafficReason `json:"recent"`
}
type appTrafficSummary struct {
	RouteTargets     []string         `json:"routeTargets"`
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
	result   chan int64
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
	policies           map[int64]string
	routesBlocked      bool
	sequence           uint64
	identityWake       chan struct{}
	identityDone       chan struct{}
	pollUntil          time.Time
}

var appTrafficCurrent atomic.Pointer[appTrafficSession]

func init() {
	statistic.SetTrackerObserver(observeAppTraffic)
	tunnel.SetHostRouting(resolveAppRoute, appUDPKey)
	route.Register(func(r chi.Router) {
		r.Get("/ohos/app-traffic", getAppTraffic)
		r.Get("/ohos/app-routes", getAppRoutes)
		r.Post("/ohos/app-routes/recover", recoverAppRoutes)
		r.Put("/ohos/app-traffic/route", putAppRoute)
		r.Get("/ohos/app-traffic/identity", getAppIdentityRequests)
		r.Post("/ohos/app-traffic/identity", postAppIdentityReplies)
	})
}

// Called under runLock before the TUN accepts packets. Aggregates and recent
// explanations live only in memory; a new session replaces the previous one.
func startAppTraffic() *appTrafficSession {
	s := &appTrafficSession{id: controllerSession, startedAt: time.Now().UnixMilli(),
		rows: make(map[string]*appTrafficRow), pending: make(map[string]*appIdentityPending), failures: make(map[string]int64), policies: make(map[int64]string), identityWake: make(chan struct{}, 1), identityDone: make(chan struct{})}
	s.policies, s.routesBlocked = appRouteStoreSnapshot()
	s.rows[""] = &appTrafficRow{IdentityStatus: "unknown", UID: -1, Recent: []appTrafficReason{}}
	appTrafficCurrent.Store(s)
	return s
}
func stopAppTraffic() {
	if s := appTrafficCurrent.Load(); s != nil {
		s.mu.Lock()
		if !s.stopped {
			s.stopped = true
			close(s.identityDone)
			s.pollUntil = time.Time{}
			s.endedAt = time.Now().UnixMilli()
			s.failures["sessionEnded"] += int64(len(s.pending))
			for _, p := range s.pending {
				if p.result != nil {
					p.result <- -1
				}
			}
			clear(s.pending)
			clear(s.policies)
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
	resolved, hasResolved := info.Metadata.TrackerContext.(*appRouteContext)
	if hasResolved {
		s = resolved.session
	}
	if (!ok && !hasResolved) || s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	kind := info.TrafficRoute
	if kind != "proxy" && kind != "direct" {
		kind = "unclassified"
	}
	row := s.rows[""]
	if hasResolved && resolved.uid >= 0 {
		row = s.rowLocked(resolved.uid)
	}
	h := &appTrafficHandle{session: s, row: row, route: kind}
	b := h.row.Routes.bucket(kind)
	b.Connections++
	b.Active++
	reason := appTrafficReason{id: info.UUID.String(), At: info.Start.UnixMilli(), Route: kind, Rule: info.Rule, Target: appTrafficTarget(info.Metadata), Policy: []string{}}
	for i, name := range info.Chain {
		if i >= 8 {
			break
		}
		if len(name) <= 256 {
			reason.Policy = append(reason.Policy, name)
		}
	}
	addAppTrafficReason(h.row, reason)
	if hasResolved {
		return h
	}
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
	s.wakeIdentity()
	return h
}
func addAppTrafficReason(row *appTrafficRow, reason appTrafficReason) {
	if reason.At > row.LastSeen {
		row.LastSeen = reason.At
	}
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
	h.row.LastSeen = time.Now().UnixMilli()
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
			if p.result != nil {
				p.result <- -1
			}
			s.failures["timeout"]++
			s.wakeIdentity()
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
		copied.RouteTarget = s.policies[row.UID]
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
	snapshot.RouteTargets = tunnel.HostRouteTargets()
	sort.Strings(snapshot.RouteTargets)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
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
	freed := false
	for _, reply := range body.Replies {
		p, ok := s.pending[reply.ID]
		if !ok || !p.sent {
			continue
		}
		delete(s.pending, reply.ID) // duplicates and late replies cannot move bytes twice
		freed = true
		if reply.Status != "uid" || reply.UID < 0 || reply.UID > 2147483647 {
			status := reply.Status
			switch status {
			case "unsupported", "notFound", "error", "timeout":
			default:
				status = "error"
			}
			s.failures[status]++
			if p.result != nil {
				p.result <- -1
			}
			continue
		}
		if p.result != nil {
			p.result <- reply.UID
			continue
		}
		row := s.rowLocked(reply.UID)
		if row.UID < 0 {
			continue
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
	if freed {
		s.wakeIdentity()
	}
	w.WriteHeader(MHTTP.StatusNoContent)
}
