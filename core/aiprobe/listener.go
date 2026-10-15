// Package aiprobe owns short-lived, authenticated loopback listeners for fixed
// public HTTPS checks. It never changes tunnel mode, group choices or config.
package aiprobe

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	I "github.com/metacubex/mihomo/adapter/inbound"
	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/component/auth"
	C "github.com/metacubex/mihomo/constant"
	authStore "github.com/metacubex/mihomo/listener/auth"
	inboundHTTP "github.com/metacubex/mihomo/listener/http"
)

// session owns every accepted connection, including unauthenticated/half-open
// clients and hijacked CONNECT streams that upstream listener.Close cannot own.
type session struct {
	socket         net.Listener
	proxy          *url.URL
	proxyGroup     C.Proxy
	ctx            context.Context
	cancel         context.CancelFunc
	group          string
	hosts          map[string]bool
	mu             sync.Mutex
	closed         bool
	connections    map[net.Conn]bool
	workers        sync.WaitGroup
	done           chan struct{}
	user, password string
}

func newSession(group string, proxyGroup C.Proxy, hosts map[string]bool) (*session, error) {
	if group == "" || proxyGroup == nil || proxyGroup.Name() != group {
		return nil, errors.New("PROBE_UNBOUND")
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, errors.New("PROBE_CREDENTIAL_UNAVAILABLE")
	}
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("PROBE_LISTENER_UNAVAILABLE")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	s := &session{socket: socket, proxyGroup: proxyGroup, ctx: ctx, cancel: cancel, group: group, hosts: hosts, user: "probe", password: hex.EncodeToString(key), connections: map[net.Conn]bool{}, done: make(chan struct{})}
	s.proxy = &url.URL{Scheme: "http", Host: socket.Addr().String(), User: url.UserPassword(s.user, s.password)}
	store := authStore.NewAuthStore(auth.NewAuthenticator([]auth.AuthUser{{User: s.user, Pass: s.password}}))
	go func() {
		defer close(s.done)
		for {
			conn, err := socket.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			if s.closed || len(s.connections) >= 8 {
				s.mu.Unlock()
				conn.Close()
				continue
			}
			s.connections[conn] = true
			s.workers.Add(1)
			s.mu.Unlock()
			go func() {
				defer s.workers.Done()
				defer conn.Close()
				defer func() { s.mu.Lock(); delete(s.connections, conn); s.mu.Unlock() }()
				_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
				inboundHTTP.HandleConn(conn, s, store, I.WithInName("Cexing AI check"), I.WithSpecialProxy(group))
			}()
		}
	}()
	return s, nil
}

func (s *session) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	// Defense in depth: even an authenticated local peer cannot turn this lease
	// into an arbitrary forward proxy. Production hosts are a fixed whitelist.
	if metadata == nil || metadata.SpecialProxy != s.group || metadata.DstPort != 443 || !s.hosts[metadata.Host] {
		conn.Close()
		return
	}
	// Capture the verified group before starting the lease. Dialing that object
	// avoids SpecialProxy's unlocked lookup in the mutable global proxy map.
	remote, err := s.proxyGroup.DialContext(s.ctx, metadata)
	if err != nil {
		conn.Close()
		return
	}
	defer remote.Close()
	_ = N.RelayContext(s.ctx, conn, remote)
}
func (s *session) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) { packet.Drop() }
func (s *session) NatTable() C.NatTable                              { return nil }
func (s *session) close() {
	s.cancel()
	s.mu.Lock()
	s.closed = true
	for conn := range s.connections {
		_ = conn.Close()
	}
	s.mu.Unlock()
	_ = s.socket.Close()
	<-s.done
	s.workers.Wait()
}

func (s *session) client() (*http.Client, *http.Transport) {
	transport := &http.Transport{Proxy: http.ProxyURL(s.proxy), DisableKeepAlives: true, DisableCompression: true,
		DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext, TLSHandshakeTimeout: 5 * time.Second,
		ResponseHeaderTimeout: 8 * time.Second, MaxResponseHeaderBytes: 16 * 1024}
	return &http.Client{Transport: transport, Timeout: 8 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, transport
}
