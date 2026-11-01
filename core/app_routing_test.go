package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"testing"
	"time"

	MHTTP "github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type routeRecorder struct {
	header MHTTP.Header
	status int
	bytes.Buffer
}

func (r *routeRecorder) Header() MHTTP.Header {
	if r.header == nil {
		r.header = make(MHTTP.Header)
	}
	return r.header
}
func (r *routeRecorder) WriteHeader(code int) { r.status = code }
func routeRequest(value any) *MHTTP.Request {
	data, _ := json.Marshal(value)
	return &MHTTP.Request{Body: io.NopCloser(bytes.NewReader(data)), URL: &url.URL{}}
}
func routeTestSession(t *testing.T) *appTrafficSession {
	prior := appTrafficCurrent.Load()
	initAppRouteStore(t.TempDir())
	s := startAppTraffic()
	s.id = "route-test"
	t.Cleanup(func() { stopAppTraffic(); appTrafficCurrent.Store(prior) })
	return s
}
func routeTestMetadata(s *appTrafficSession, network C.NetWork) *C.Metadata {
	return &C.Metadata{Type: C.TUN, NetWork: network, TrackerContext: s, Host: "synthetic.example",
		RawSrcAddr: &net.TCPAddr{IP: net.ParseIP("192.0.2.1"), Port: 34567}, RawDstAddr: &net.TCPAddr{IP: net.ParseIP("198.18.0.2"), Port: 443}}
}
func awaitRoutePending(t *testing.T, s *appTrafficSession) (string, appIdentityRequest) {
	t.Helper()
	until := time.Now().Add(time.Second)
	for time.Now().Before(until) {
		s.mu.Lock()
		for id, pending := range s.pending {
			pending.sent = true
			request := pending.request
			s.mu.Unlock()
			return id, request
		}
		s.mu.Unlock()
		time.Sleep(time.Millisecond)
	}
	t.Fatal("query did not reach the identity queue")
	return "", appIdentityRequest{}
}
func TestAppRouteIdentityBeforeOutbound(t *testing.T) {
	for _, network := range []C.NetWork{C.TCP, C.UDP} {
		t.Run(network.String(), func(t *testing.T) {
			s := routeTestSession(t)
			s.consumer = true
			s.rowLocked(10001)
			s.policies[10001] = "DIRECT"
			metadata := routeTestMetadata(s, network)
			result := make(chan string, 1)
			go func() {
				target, err := resolveAppRoute(metadata)
				if err != nil {
					result <- err.Error()
				} else {
					result <- target
				}
			}()
			id, request := awaitRoutePending(t, s)
			select {
			case value := <-result:
				t.Fatalf("resolved before identity reply: %s", value)
			default:
			}
			if request.Remote.Address != "198.18.0.2" || request.Local.Port != 34567 || request.Protocol != network.String() {
				t.Fatalf("wrong original tuple: %+v", request)
			}
			reply := map[string]any{"session": s.id, "replies": []appIdentityReply{{ID: id, UID: 10001, Status: "uid"}}}
			recorder := &routeRecorder{}
			postAppIdentityReplies(recorder, routeRequest(reply))
			if recorder.status != 204 {
				t.Fatalf("reply: %d", recorder.status)
			}
			if target := <-result; target != "DIRECT" {
				t.Fatalf("target %q", target)
			}
			h := observeAppTraffic(&statistic.TrackerInfo{Metadata: metadata, Start: time.Now(), TrafficRoute: "direct"})
			h.Add(5, 7)
			h.Close()
			s.mu.Lock()
			snapshot := s.snapshotLocked()
			row := s.rows["10001"]
			if row.Routes.Direct.Upload != 5 || row.Routes.Direct.Download != 7 || row.Routes.Direct.Active != 0 || row.Recent[0].Target != "synthetic.example" || len(s.pending) != 0 {
				t.Errorf("identity/accounting not shared: %+v", row)
			}
			if snapshot.Totals.Direct.Connections != 1 {
				t.Error("connection counted twice")
			}
			s.mu.Unlock()
			// A duplicate response must not move counters or overwrite the chosen identity.
			postAppIdentityReplies(&routeRecorder{}, routeRequest(reply))
		})
	}
}
func TestAppRoutePolicyTrustBoundary(t *testing.T) {
	s := routeTestSession(t)
	s.rowLocked(10001)
	for _, tc := range []struct {
		session string
		uid     int64
		target  string
		status  int
	}{
		{"old", 10001, "DIRECT", 409}, {s.id, 10002, "DIRECT", 400}, {s.id, 10001, "missing", 400}, {s.id, -1, "DIRECT", 400},
		{s.id, 10001, "DIRECT", 204}, {s.id, 10001, "", 204},
	} {
		r := &routeRecorder{}
		putAppRoute(r, routeRequest(map[string]any{"session": tc.session, "uid": tc.uid, "target": tc.target}))
		if r.status != tc.status {
			t.Errorf("%+v got %d", tc, r.status)
		}
	}
	if len(s.policies) != 0 {
		t.Fatal("follow did not clear rule")
	}
	// Unknown identities remain usable until a source-specific rule requires identity.
	if _, err := resolveAppRoute(routeTestMetadata(s, C.TCP)); err != nil {
		t.Fatal(err)
	}
	s.policies[10001] = "DIRECT"
	if _, err := resolveAppRoute(routeTestMetadata(s, C.TCP)); err == nil {
		t.Fatal("unknown source bypassed forced policy")
	}
}
func TestAppRouteStopCancelsIdentity(t *testing.T) {
	s := routeTestSession(t)
	s.consumer = true
	done := make(chan error, 1)
	go func() { _, err := resolveAppRoute(routeTestMetadata(s, C.TCP)); done <- err }()
	id, _ := awaitRoutePending(t, s)
	stopAppTraffic()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("stopped session routed")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("stop did not release lookup")
	}
	r := &routeRecorder{}
	postAppIdentityReplies(r, routeRequest(map[string]any{"session": s.id, "replies": []appIdentityReply{{ID: id, UID: 10001, Status: "uid"}}}))
	if r.status != 409 || len(s.policies) != 0 || len(s.pending) != 0 {
		t.Fatal("stale session accepted reply or retained policy")
	}
}

func TestAppRouteUDPNATPartitions(t *testing.T) {
	s := routeTestSession(t)
	s.consumer = true
	keyFor := func(uid int64, port int) (string, *C.Metadata) {
		t.Helper()
		metadata := routeTestMetadata(s, C.UDP)
		metadata.RawDstAddr = &net.UDPAddr{IP: net.ParseIP("198.18.0.2"), Port: port}
		done := make(chan string, 1)
		go func() {
			key, err := appUDPKey(metadata)
			if err != nil {
				done <- "error"
			} else {
				done <- key
			}
		}()
		id, _ := awaitRoutePending(t, s)
		status := "uid"
		if uid < 0 {
			status = "notFound"
		}
		postAppIdentityReplies(&routeRecorder{}, routeRequest(map[string]any{"session": s.id, "replies": []appIdentityReply{{ID: id, UID: uid, Status: status}}}))
		return <-done, metadata
	}
	a, _ := keyFor(10001, 443)
	again, _ := keyFor(10001, 443)
	b, _ := keyFor(10002, 443)
	remote, _ := keyFor(10001, 8443)
	unknown, _ := keyFor(-1, 443)
	if a == "error" || a != again || a == b || a == remote || unknown == "error" || unknown == a || unknown == b {
		t.Fatal("UDP NAT partition reused another owner or tuple")
	}
	s.mu.Lock()
	s.policies[10001] = "DIRECT"
	s.mu.Unlock()
	routed, metadata := keyFor(10001, 443)
	if routed == "error" || routed == a {
		t.Fatal("route change reused prior UDP mapping")
	}
	rejected, _ := keyFor(-1, 443)
	if rejected != "error" {
		t.Fatal("unknown UDP bypassed forced source rule")
	}
	s.mu.Lock()
	delete(s.policies, 10001)
	s.mu.Unlock()
	target, err := resolveAppRoute(metadata)
	if target != "DIRECT" || err != nil || len(s.pending) != 0 {
		t.Fatal("UDP route selection discarded queried packet snapshot")
	}
}

type gatedUDPPacket struct {
	C.UDPPacket
	dropped chan struct{}
}

func (p *gatedUDPPacket) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.ParseIP("192.0.2.1"), Port: 34567}
}
func (p *gatedUDPPacket) Drop() { p.dropped <- struct{}{} }

func TestAppRouteUDPAsyncBound(t *testing.T) {
	entered := make(chan struct{}, 128)
	release := make(chan struct{})
	waitRelease := release
	dropped := make(chan struct{}, 129)
	tunnel.SetHostRouting(resolveAppRoute, func(*C.Metadata) (string, error) {
		entered <- struct{}{}
		<-waitRelease
		return "", errors.New("synthetic lookup unavailable")
	})
	defer tunnel.SetHostRouting(resolveAppRoute, appUDPKey)
	defer func() {
		if release != nil {
			close(release)
		}
	}()
	for i := 0; i < 128; i++ {
		tunnel.Tunnel.HandleUDPPacket(&gatedUDPPacket{dropped: dropped}, &C.Metadata{Type: C.TUN, NetWork: C.UDP})
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("shared UDP worker blocked on platform lookup")
		}
	}
	tunnel.Tunnel.HandleUDPPacket(&gatedUDPPacket{dropped: dropped}, &C.Metadata{Type: C.TUN, NetWork: C.UDP})
	select {
	case <-dropped:
	case <-time.After(time.Second):
		t.Fatal("UDP overflow did not drop promptly")
	}
	select {
	case <-entered:
		t.Fatal("UDP identity gate exceeded 128 slots")
	default:
	}
	close(release)
	release = nil
	for i := 0; i < 128; i++ {
		select {
		case <-dropped:
		case <-time.After(time.Second):
			t.Fatal("UDP failure leaked packet")
		}
	}
}
