package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/oschwald/maxminddb-golang"
	"io"
	"net"
	HTTP "net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type cityRoundTrip func(*HTTP.Request) (*HTTP.Response, error)

func (f cityRoundTrip) RoundTrip(r *HTTP.Request) (*HTTP.Response, error) { return f(r) }

func TestCityInstallRejectsUnsafeDirectoryBeforeNetwork(t *testing.T) {
	calls := 0
	client := &HTTP.Client{Transport: cityRoundTrip(func(r *HTTP.Request) (*HTTP.Response, error) { calls++; return nil, io.EOF })}
	dir := t.TempDir()
	if err := os.Symlink(dir, filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	if err := installCity(context.Background(), filepath.Join(dir, "link", "db.mmdb"), client, cityURL, func(int64) {}); err == nil {
		t.Fatal("symlink directory accepted")
	}
	if calls != 0 {
		t.Fatal("unsafe path initiated network")
	}
}

func TestCityMissingAndCorruptNeverReady(t *testing.T) {
	dir := t.TempDir()
	s := cityStoreFor(dir)
	if got := s.status(); got.State != "missing" {
		t.Fatalf("missing = %+v", got)
	}
	path := filepath.Join(dir, "controller-security")
	_ = os.Mkdir(path, 0700)
	_ = os.WriteFile(s.path, []byte("bad"), 0600)
	s.checked = false
	if got := s.status(); got.State != "error" || got.Reason != "integrity" {
		t.Fatalf("invalid = %+v", got)
	}
}

func TestCityRealDataLocalReaderAndInstall(t *testing.T) {
	// Public fixed DB-IP release downloaded once for explicit cloud validation.
	// Quick skips this data-heavy fixture rather than claiming a real-data pass.
	raw := os.Getenv("CITY_REAL_MMDB")
	archive := os.Getenv("CITY_REAL_GZIP")
	if raw == "" || archive == "" {
		t.Skip("optional verified official city database")
	}
	if err := validCityFile(raw); err != nil {
		t.Fatal(err)
	}
	compressed, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(compressed)
	if int64(len(compressed)) != cityGzipBytes || hex.EncodeToString(hash[:]) != cityGzipSHA256 {
		t.Fatal("wrong public archive")
	}
	dir := t.TempDir()
	_ = os.Mkdir(filepath.Join(dir, "controller-security"), 0700)
	calls := 0
	client := &HTTP.Client{Transport: cityRoundTrip(func(r *HTTP.Request) (*HTTP.Response, error) {
		calls++
		if r.URL.String() != cityURL || r.URL.RawQuery != "" || r.Body != nil || r.Header.Get("Authorization") != "" {
			t.Fatal("download forwarded caller data")
		}
		file, e := os.Open(archive)
		return &HTTP.Response{StatusCode: 200, Body: file}, e
	})}
	target := filepath.Join(dir, "controller-security", "city-2026-10.mmdb")
	progress := int64(0)
	if err = installCity(context.Background(), target, client, cityURL, func(n int64) { progress = n }); err != nil {
		t.Fatal(err)
	}
	if calls != 1 || progress != cityGzipBytes {
		t.Fatal("unexpected download count/progress")
	}
	if err = validCityFile(target); err != nil {
		t.Fatal(err)
	}
	// Existing reader library handles IPv4/IPv6 locally; never contact DB-IP with
	// query IPs. The official format page documents this public sample address.
	reader, err := maxminddb.Open(target)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	var record cityRecord
	if err = reader.Lookup(net.ParseIP("8.8.8.8"), &record); err != nil {
		t.Fatal(err)
	}
	if record.Location.Latitude == nil || record.Location.Longitude == nil || record.Country.Names["en"] == "" {
		t.Fatal("actual city coordinates missing")
	}
	if calls != 1 {
		t.Fatal("lookup sent query to provider")
	}
	// Restart revalidates and retains the exact installed release.
	s := cityStoreFor(dir)
	if s.status().State != "ready" {
		t.Fatal("installed release not recovered")
	}
}

func TestCityRoutesAuthenticationAndExplicitConsent(t *testing.T) {
	home := t.TempDir()
	if err := coreInit(home); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	cfg, err := preparePlatformConfig("mixed-port: 0\nmode: direct\nlog-level: silent\ndns:\n  enable: false\n", `{"mixedPort":0}`)
	if err != nil {
		t.Fatal(err)
	}
	if err = startController(); err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	client := &HTTP.Client{Timeout: 5 * time.Second, Transport: &HTTP.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	request := func(method, path, body string, authorized bool) int {
		req, e := HTTP.NewRequest(method, "http://"+defaultController+path, strings.NewReader(body))
		if e != nil {
			t.Fatal(e)
		}
		if authorized {
			req.Header.Set("Authorization", "Bearer "+controllerSecret)
		}
		response, e := client.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer response.Body.Close()
		_, _ = io.Copy(io.Discard, response.Body)
		return response.StatusCode
	}
	for _, item := range []struct{ method, path string }{{"GET", "/ohos/geoip/status"}, {"POST", "/ohos/geoip/download"}, {"POST", "/ohos/geoip/cancel"}, {"POST", "/ohos/geoip/lookup"}} {
		if got := request(item.method, item.path, "{}", false); got != 401 {
			t.Fatalf("anonymous city operation = %d", got)
		}
	}
	if got := request("GET", "/ohos/geoip/status", "", true); got != 200 {
		t.Fatal("status unavailable")
	}
	for _, body := range []string{`{}`, `{"confirmDownload":false,"release":"2026-10"}`, `{"confirmDownload":true,"release":"other"}`, `{"confirmDownload":true,"release":"2026-10","url":"https://private.invalid"}`} {
		if got := request("POST", "/ohos/geoip/download", body, true); got != 400 {
			t.Fatalf("unconfirmed/arbitrary download = %d", got)
		}
	}
	if got := request("POST", "/ohos/geoip/lookup", `{"ips":["8.8.8.8"]}`, true); got != 409 {
		t.Fatal("missing data lookup reported available")
	}
	if got := request("POST", "/ohos/geoip/cancel", "{}", true); got != 204 {
		t.Fatal("cancel failed")
	}
	if _, err = os.Stat(cityStoreFor(home).path); !os.IsNotExist(err) {
		t.Fatal("status/lookup/invalid consent unexpectedly installed data")
	}
}

func TestCityPinnedSourceManifest(t *testing.T) {
	data, err := os.ReadFile("../third_party/city-geoip/source.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err = json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest["release"] != cityRelease || manifest["url"] != cityURL || manifest["gzipSha256"] != cityGzipSHA256 || manifest["mmdbSha256"] != cityRawSHA256 || manifest["gzipBytes"] != float64(cityGzipBytes) || manifest["mmdbBytes"] != float64(cityRawBytes) {
		t.Fatal("download code and public source pin differ")
	}
}
