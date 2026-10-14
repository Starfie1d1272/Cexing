package aiprobe

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	P "github.com/metacubex/mihomo/adapter/provider"
	C "github.com/metacubex/mihomo/constant"
	CP "github.com/metacubex/mihomo/constant/provider"
	R "github.com/metacubex/mihomo/rules/common"
	"github.com/metacubex/mihomo/tunnel"
)

type localAdapter struct {
	*outbound.Base
	address string
	count   atomic.Int32
}

func (a *localAdapter) DialContext(ctx context.Context, _ *C.Metadata) (C.Conn, error) {
	a.count.Add(1)
	c, err := (&net.Dialer{}).DialContext(ctx, "tcp", a.address)
	if err != nil {
		return nil, err
	}
	return outbound.NewConn(c, a), nil
}
func trustedServer(t *testing.T, h http.Handler) (*httptest.Server, *x509.CertPool) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Synthetic probe"}, DNSNames: []string{"chatgpt.com", "claude.ai", "gemini.google.com"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, _ := x509.MarshalECPrivateKey(key)
	cert, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(h)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	server.StartTLS()
	t.Cleanup(server.Close)
	roots := x509.NewCertPool()
	leaf, _ := x509.ParseCertificate(der)
	roots.AddCert(leaf)
	return server, roots
}
func localGroup(t *testing.T, address string) (*localAdapter, *localAdapter, *G.Selector) {
	t.Helper()
	a := &localAdapter{Base: outbound.NewBase(outbound.BaseOption{Name: "selected-node", Type: C.Direct}), address: address}
	wrong := &localAdapter{Base: outbound.NewBase(outbound.BaseOption{Name: "wrong-node", Type: C.Direct}), address: address}
	proxies := []C.Proxy{adapter.NewProxy(a), adapter.NewProxy(wrong)}
	provider, err := P.NewCompatibleProvider("synthetic", proxies, P.NewHealthCheck(proxies, "", 0, 0, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { provider.Close() })
	selected, err := G.NewSelector(G.GroupCommonOption{Name: "AI"}, G.SelectorOption{DefaultSelected: "selected-node"}, adapter.NewProxy(outbound.NewReject()), []CP.ProxyProvider{provider})
	if err != nil {
		t.Fatal(err)
	}
	tunnel.UpdateProxies(map[string]C.Proxy{"AI": adapter.NewProxy(selected), "wrong": adapter.NewProxy(wrong), "DIRECT": adapter.NewProxy(wrong), "GLOBAL": adapter.NewProxy(wrong)}, nil)
	tunnel.UpdateRules([]C.Rule{R.NewMatch("wrong")}, nil, nil)
	tunnel.OnRunning()
	return a, wrong, selected
}

// Real fixed Mihomo HTTP inbound + SpecialProxy routing + real Selector. All
// upstream TCP dials terminate at a local HTTPS server with a synthetic CA.
func TestDirectedListenerAndLifecycle(t *testing.T) {
	if os.Getenv("CEXING_PROBE_CHILD") != "1" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestDirectedListenerAndLifecycle$", "-test.v")
		cmd.Env = append(os.Environ(), "CEXING_PROBE_CHILD=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v\n%s", err, out)
		}
		return
	}
	var hold atomic.Bool
	var status atomic.Int32
	status.Store(200)
	server, roots := trustedServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Proxy-Authorization") != "" || r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("credential reached service")
		}
		if hold.Load() {
			<-r.Context().Done()
			return
		}
		w.Header().Set("Retry-After", "1")
		w.WriteHeader(int(status.Load()))
		io.WriteString(w, "ChatGPT Claude Gemini")
	}))
	a, wrong, selected := localGroup(t, server.Listener.Addr().String())
	lease, err := newSession("AI", tunnel.Tunnel, officialHosts)
	if err != nil {
		t.Fatal(err)
	}
	client, transport := lease.client()
	transport.TLSClientConfig = &tls.Config{RootCAs: roots}
	for _, mode := range []tunnel.TunnelMode{tunnel.Rule, tunnel.Global, tunnel.Direct} {
		tunnel.SetMode(mode)
		result := probe(context.Background(), client, official[0])
		if result.State != "reachable" {
			t.Fatalf("%s: %#v", mode.String(), result)
		}
	}
	if a.count.Load() != 3 || wrong.count.Load() != 0 || selected.Now() != "selected-node" {
		t.Fatal("wrong routing or selection changed")
	}
	// No implicit direct fallback when the bound group disappears.
	tunnel.UpdateProxies(map[string]C.Proxy{"DIRECT": adapter.NewProxy(wrong)}, nil)
	fail := probe(context.Background(), client, official[0])
	if fail.State == "reachable" || wrong.count.Load() != 0 {
		t.Fatal("missing group fell through")
	}
	a, wrong, selected = localGroup(t, server.Listener.Addr().String())
	// TLS verification is active, not bypassed merely because proxying succeeded.
	untrusted, untrustedTransport := lease.client()
	if result := probe(context.Background(), untrusted, official[0]); result.State == "reachable" {
		t.Fatal("untrusted TLS accepted")
	}
	untrustedTransport.CloseIdleConnections()
	raw, err := net.Dial("tcp", lease.socket.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	io.WriteString(raw, "CONNECT chatgpt.com:443 HTTP/1.1\r\nHost: chatgpt.com:443\r\n\r\n")
	line, _ := bufio.NewReader(raw).ReadString('\n')
	if !strings.Contains(line, "407") {
		t.Fatal("anonymous proxy accepted", line)
	}
	idle, err := net.Dial("tcp", lease.socket.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	address := lease.socket.Addr().String()
	lease.close()
	transport.CloseIdleConnections()
	idle.SetReadDeadline(time.Now().Add(time.Second))
	if _, err = idle.Read(make([]byte, 1)); err == nil {
		t.Fatal("idle connection survived cleanup")
	}
	idle.Close()
	raw.Close()
	if conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond); err == nil {
		conn.Close()
		t.Fatal("listener survived cleanup")
	}

	// Cache/backoff and identity cancellation run through the same real listener.
	manager := &Manager{clientFactory: func(s *session) (*http.Client, *http.Transport) {
		c, tr := s.client()
		tr.TLSClientConfig = &tls.Config{RootCAs: roots}
		return c, tr
	}}
	id := Identity{Profile: "synthetic.yaml", Revision: "version-synthetic", Group: "AI", Selection: "selected-node"}
	var current atomic.Bool
	current.Store(true)
	status.Store(429)
	results, err := manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range results {
		if r.State != "limited" || r.RetryAt == nil || r.RetryAt.Before(time.Now().Add(50*time.Second)) {
			t.Fatal("bad backoff", r)
		}
	}
	before := a.count.Load()
	_, err = manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, true)
	if err != nil || a.count.Load() != before {
		t.Fatal("manual retry bypassed backoff", err)
	}

	// Expiry rechecks with a new timestamp; cancelled work cannot populate cache.
	oldAt := results[0].At
	manager.cache[id] = cacheEntry{results: results, expires: time.Now().Add(-time.Second)}
	status.Store(200)
	fresh, err := manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, false)
	if err != nil || !fresh[0].At.After(oldAt) || a.count.Load() <= before {
		t.Fatal("expired cache reused", err)
	}
	hold.Store(true)
	id.Revision = "version-next"
	finished := make(chan error, 1)
	go func() {
		_, err := manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, false)
		finished <- err
	}()
	limit := time.Now().Add(time.Second)
	before = a.count.Load()
	for a.count.Load() == before && time.Now().Before(limit) {
		time.Sleep(time.Millisecond)
	}
	if _, err := manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, false); err == nil {
		t.Fatal("concurrent lease admitted")
	}
	current.Store(false)
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("stale result accepted")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("selection cancellation did not finish")
	}
	if _, ok := manager.cache[id]; ok {
		t.Fatal("cancelled result cached")
	}

	current.Store(false)
	if _, err = manager.Check(context.Background(), id, tunnel.Tunnel, current.Load, false); err == nil {
		t.Fatal("stale identity accepted cache")
	}
}

func TestProbeClassificationAndBounds(t *testing.T) {
	cases := []struct {
		status      int
		body, state string
	}{{200, "chatgpt", "reachable"}, {200, "new schema", "unknown"}, {200, "unsupported_country", "unknown"}, {403, "Access denied", "unknown"}, {403, "unsupported_country", "region_restricted"}, {429, "", "limited"}, {200, strings.Repeat("x", 64*1024+1), "unknown"}, {302, "chatgpt", "unknown"}}
	for _, c := range cases {
		t.Run(c.state, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(c.status); io.WriteString(w, c.body) }))
			defer server.Close()
			r := probe(context.Background(), server.Client(), endpoint{"test", server.URL, "chatgpt"})
			if r.State != c.state {
				t.Fatal(r)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if r := probe(ctx, http.DefaultClient, official[0]); r.State == "reachable" {
		t.Fatal("cancel accepted")
	}
}

func TestTimeoutAndNetworkFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	client := server.Client()
	client.Timeout = 10 * time.Millisecond
	if r := probe(context.Background(), client, endpoint{"test", server.URL, "test"}); r.State != "timeout" {
		t.Fatal(r)
	}
	server.Close()
	if r := probe(context.Background(), client, endpoint{"test", server.URL, "test"}); r.State != "network_failed" {
		t.Fatal(r)
	}
}
