//go:build smartbeta

package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/smart/lightgbm"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
)

// Real Linux sockets, real Smart group and upstream model, local test endpoints.
// This is not OHOS TUN, TLS/REALITY, radio switching or a throughput benchmark.
func TestSmartRealForwarding(t *testing.T) {
	modelPath := os.Getenv("SMART_REAL_MODEL")
	if modelPath == "" {
		t.Skip("real upstream model not supplied")
	}
	home := t.TempDir()
	C.SetHomeDir(home)
	model, err := os.ReadFile(modelPath)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(home, "Model.bin"), model, 0600); err != nil {
		t.Fatal(err)
	}
	var deliveriesA, deliveriesB atomic.Int64
	var deliveredMu sync.Mutex
	delivered := map[string]int{}
	var originPeers sync.Map
	originHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		owner, _ := originPeers.Load(r.RemoteAddr)
		node, _ := owner.(string)
		switch node {
		case "local-a":
			deliveriesA.Add(1)
		case "local-b":
			deliveriesB.Add(1)
		default:
			http.Error(w, "unattributed origin request", 403)
			return
		}
		deliveredMu.Lock()
		delivered[r.URL.Path]++
		deliveredMu.Unlock()
		w.Header().Set("X-Cexing-Test-Proxy", node)
		io.WriteString(w, strings.Repeat("real-local-payload", 256))
	})
	origin := httptest.NewServer(originHandler)
	defer origin.Close()
	second := httptest.NewServer(originHandler)
	defer second.Close()
	var hitsA, hitsB, emptyA, emptyB atomic.Int64
	proxy := func(name string, hits, empty *atomic.Int64) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "CONNECT" {
				http.Error(w, "CONNECT required", 405)
				return
			}
			host, _, splitErr := net.SplitHostPort(r.Host)
			if splitErr != nil || host != "127.0.0.1" {
				http.Error(w, "test only permits loopback targets", 403)
				return
			}
			target, err := net.DialTimeout("tcp", r.Host, time.Second)
			if err != nil {
				http.Error(w, "target unavailable", 502)
				return
			}
			client, buffered, err := w.(http.Hijacker).Hijack()
			if err != nil {
				target.Close()
				return
			}
			originPeers.Store(target.LocalAddr().String(), name)
			defer originPeers.Delete(target.LocalAddr().String())
			hits.Add(1)
			fmt.Fprint(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
			defer target.Close()
			defer client.Close()
			// A successful CONNECT is a dial attempt, not proof of an HTTP
			// delivery. Preserve the original tunnel bytes, including buffered data.
			go func() {
				written, _ := io.Copy(target, buffered)
				if written == 0 {
					empty.Add(1)
				}
				target.Close()
			}()
			io.Copy(client, target)
		}))
	}
	a, b := proxy("local-a", &hitsA, &emptyA), proxy("local-b", &hitsB, &emptyB)
	defer a.Close()
	defer b.Close()
	port := func(address string) string { u, _ := url.Parse(address); return u.Port() }
	reserve, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mixed := reserve.Addr().(*net.TCPAddr).Port
	reserve.Close()
	yaml := fmt.Sprintf(`mixed-port: %d
bind-address: 127.0.0.1
allow-lan: false
mode: rule
find-process-mode: off
lgbm-auto-update: false
profile: {store-selected: false}
proxies:
 - {name: local-a, type: http, server: 127.0.0.1, port: %s}
 - {name: local-b, type: http, server: 127.0.0.1, port: %s}
proxy-groups:
 - name: smart-real
   type: smart
   proxies: [local-a, local-b]
   uselightgbm: true
   collectdata: false
   prefer-asn: false
   sample-rate: 1
rules: ['MATCH,smart-real']
`, mixed, port(a.URL), port(b.URL))
	cfg, err := config.Parse([]byte(yaml))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg.Proxies["smart-real"].Adapter().(*outboundgroup.Smart); !ok {
		t.Fatal("not a real Smart group")
	}
	hub.ApplyConfig(cfg)
	defer coreStop()
	p, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixed))
	tr := &http.Transport{Proxy: http.ProxyURL(p), DisableKeepAlives: true}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	before := lightgbm.ModelStatus().Predictions
	for i := 0; i < 12; i++ {
		target := origin.URL
		if i%2 == 1 {
			target = second.URL
		}
		path := fmt.Sprintf("/target/%d", i)
		resp, err := client.Get(target + path)
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		node := resp.Header.Get("X-Cexing-Test-Proxy")
		if err != nil || resp.StatusCode != 200 || string(data) != strings.Repeat("real-local-payload", 256) || (node != "local-a" && node != "local-b") {
			t.Fatalf("forwarding: %v status=%d bytes=%d", err, resp.StatusCode, len(data))
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for lightgbm.ModelStatus().Predictions == before && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("real Smart chain: CONNECT local-a=%d local-b=%d; delivered local-a=%d local-b=%d; empty CONNECT=%d; state=%s valid LightGBM predictions=%d", hitsA.Load(), hitsB.Load(), deliveriesA.Load(), deliveriesB.Load(), emptyA.Load()+emptyB.Load(), lightgbm.ModelStatus().State, lightgbm.ModelStatus().Predictions-before)
	if lightgbm.ModelStatus().State != "loaded" || lightgbm.ModelStatus().Predictions <= before {
		t.Fatal("forwarded but no LightGBM prediction participation")
	}
	if deliveriesA.Load()+deliveriesB.Load() != 12 {
		t.Fatalf("unexpected chain: delivered=%d, want 12 unique HTTP requests", deliveriesA.Load()+deliveriesB.Load())
	}
	deliveredMu.Lock()
	for i := 0; i < 12; i++ {
		path := fmt.Sprintf("/target/%d", i)
		if delivered[path] != 1 {
			t.Errorf("request %s delivered %d times", path, delivered[path])
		}
	}
	deliveredMu.Unlock()
	// Fail the previously used node; retain actual errors while checking recovery.
	if deliveriesA.Load() >= deliveriesB.Load() {
		a.Close()
	} else {
		b.Close()
	}
	recovered := 0
	for i := 0; i < 6; i++ {
		resp, err := client.Get(fmt.Sprintf("%s/after-node-failure/%d", origin.URL, i))
		if err != nil {
			t.Logf("actual node-failure request: %v", err)
			continue
		}
		_, readErr := io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode == 200 && readErr == nil {
			recovered++
		}
	}
	t.Logf("node failure: recovered=%d local-a=%d local-b=%d", recovered, hitsA.Load(), hitsB.Load())
	if recovered == 0 || deliveriesA.Load() == 0 || deliveriesB.Load() == 0 {
		t.Fatal("no verified recovery through the second valid node")
	}
}
