package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
)

// Exercises the production config projection and real mixed listener with synthetic loopback sockets.
// It cannot establish an OHOS TUN or prove a private upstream node works.
func TestMixedLoopbackHTTPAndTLS(t *testing.T) {
	if err := coreInit(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	payload := strings.Repeat("local-response", 32)
	target := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, payload) })
	plain := httptest.NewServer(target)
	defer plain.Close()
	secure := httptest.NewTLSServer(target)
	defer secure.Close()
	var hitsA, hitsB atomic.Int64
	proxy := func(hits *atomic.Int64) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			host := r.URL.Hostname()
			if r.Method == http.MethodConnect {
				host, _, _ = net.SplitHostPort(r.Host)
			}
			if host != "127.0.0.1" {
				http.Error(w, "loopback only", http.StatusForbidden)
				return
			}
			hits.Add(1)
			if r.Method == http.MethodConnect {
				upstream, err := net.DialTimeout("tcp", r.Host, time.Second)
				if err != nil {
					http.Error(w, "unavailable", 502)
					return
				}
				downstream, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					upstream.Close()
					return
				}
				_, _ = io.WriteString(downstream, "HTTP/1.1 200 Connection Established\r\n\r\n")
				go func() { _, _ = io.Copy(upstream, downstream); upstream.Close() }()
				_, _ = io.Copy(downstream, upstream)
				downstream.Close()
				return
			}
			request := r.Clone(r.Context())
			request.RequestURI = ""
			transport := &http.Transport{Proxy: nil}
			response, err := transport.RoundTrip(request)
			if err != nil {
				http.Error(w, "upstream unavailable", 502)
				return
			}
			defer response.Body.Close()
			for name, values := range response.Header {
				for _, value := range values {
					w.Header().Add(name, value)
				}
			}
			w.WriteHeader(response.StatusCode)
			_, _ = io.Copy(w, response.Body)
		}))
	}
	a, b := proxy(&hitsA), proxy(&hitsB)
	defer a.Close()
	defer b.Close()
	port := func(address string) string { parsed, _ := url.Parse(address); return parsed.Port() }
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mixed := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	clientProxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixed))
	transport := &http.Transport{Proxy: http.ProxyURL(clientProxy), TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 4 * time.Second}
	apply := func(name string) {
		text := fmt.Sprintf(`mixed-port: %d
bind-address: 127.0.0.1
allow-lan: false
mode: rule
dns: {enable: false}
proxies:
 - {name: local-a, type: http, server: 127.0.0.1, port: %s}
 - {name: local-b, type: http, server: 127.0.0.1, port: %s}
rules: ['MATCH,%s']
`, mixed, port(a.URL), port(b.URL), name)
		cfg, err := preparePlatformConfig(text, `{"mixedPort":`+fmt.Sprint(mixed)+`}`)
		if err != nil {
			t.Fatal(err)
		}
		executor.ApplyConfig(cfg, true)
	}
	fetch := func(address string) {
		response, err := client.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || response.StatusCode != 200 || string(data) != payload {
			t.Fatalf("mixed response status=%d bytes=%d err=%v", response.StatusCode, len(data), err)
		}
	}
	apply("local-a")
	fetch(plain.URL)
	fetch(secure.URL)
	if hitsA.Load() != 2 || hitsB.Load() != 0 {
		t.Fatalf("first proxy chain a=%d b=%d", hitsA.Load(), hitsB.Load())
	}
	a.Close()
	if response, err := client.Get(plain.URL); err == nil {
		response.Body.Close()
		if response.StatusCode == 200 {
			t.Fatal("failed proxy unexpectedly forwarded")
		}
	}
	apply("local-b")
	fetch(plain.URL)
	fetch(secure.URL)
	if hitsB.Load() != 2 {
		t.Fatalf("recovered proxy chain b=%d", hitsB.Load())
	}
}
