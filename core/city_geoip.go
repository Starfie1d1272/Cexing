package main

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net"
	HTTP "net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/oschwald/maxminddb-golang"
)

const cityRelease = "2026-10"
const cityURL = "https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz"
const cityGzipBytes int64 = 60193321
const cityRawBytes int64 = 126998165
const cityGzipSHA256 = "c839d407f85a1e0bddba354cef16b2c398182d1c34ed8d985555dce134b36b14"
const cityRawSHA256 = "9e250f02722d1ad1780f88192f0e908af285478a33e76b88b349c9181ae9d0f5"

type cityStatus struct {
	State         string `json:"state"`
	Reason        string `json:"reason,omitempty"`
	Release       string `json:"release"`
	DownloadBytes int64  `json:"downloadBytes"`
	StoredBytes   int64  `json:"storedBytes"`
	Received      int64  `json:"received"`
}
type cityStore struct {
	mu      sync.Mutex
	path    string
	state   cityStatus
	checked bool
	cancel  context.CancelFunc
}

var cityStores sync.Map

func cityStoreFor(home string) *cityStore {
	path := filepath.Join(home, "controller-security", "city-"+cityRelease+".mmdb")
	created := &cityStore{path: path, state: cityStatus{State: "missing", Reason: "not_downloaded", Release: cityRelease, DownloadBytes: cityGzipBytes, StoredBytes: cityRawBytes}}
	value, _ := cityStores.LoadOrStore(path, created)
	return value.(*cityStore)
}

func init() {
	// Same authenticated Controller group; no C ABI, Worker, native JS bridge,
	// remote-IP lookup or caller-supplied download URL.
	route.Register(func(r chi.Router) {
		store := cityStoreFor(homeDir)
		r.Get("/ohos/geoip/status", func(w MHTTP.ResponseWriter, req *MHTTP.Request) {
			writeCityJSON(w, store.status())
		})
		r.Post("/ohos/geoip/download", store.download)
		r.Post("/ohos/geoip/cancel", func(w MHTTP.ResponseWriter, req *MHTTP.Request) {
			store.mu.Lock()
			if store.cancel != nil {
				store.cancel()
			}
			store.mu.Unlock()
			w.WriteHeader(204)
		})
		r.Post("/ohos/geoip/lookup", store.lookup)
	})
}

func writeCityJSON(w MHTTP.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(value)
}

func validCityFile(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return errors.New("missing")
	}
	if err != nil {
		return errors.New("storage")
	}
	if !info.Mode().IsRegular() || info.Size() != cityRawBytes {
		return errors.New("integrity")
	}
	file, err := os.Open(path)
	if err != nil {
		return errors.New("storage")
	}
	hash := sha256.New()
	_, err = io.Copy(hash, file)
	_ = file.Close()
	if err != nil || hex.EncodeToString(hash.Sum(nil)) != cityRawSHA256 {
		return errors.New("integrity")
	}
	reader, err := maxminddb.Open(path)
	if err != nil {
		return errors.New("invalid")
	}
	defer reader.Close()
	if reader.Metadata.DatabaseType != "DBIP-City-Lite" || reader.Metadata.IPVersion != 6 || reader.Metadata.NodeCount == 0 {
		return errors.New("invalid")
	}
	return nil
}

func (s *cityStore) status() cityStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.checked && s.state.State != "downloading" {
		s.checked = true
		if err := validCityFile(s.path); err == nil {
			s.state.State = "ready"
			s.state.Reason = ""
		} else if err.Error() != "missing" {
			s.state.State = "error"
			s.state.Reason = err.Error()
		}
		// Missing or invalid data is never marked available; an explicit download
		// repairs it atomically without removing any other files.
	}
	return s.state
}

func cityInput(req *MHTTP.Request, value any) bool {
	decoder := json.NewDecoder(io.LimitReader(req.Body, 16385))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return false
	}
	var extra any
	return decoder.Decode(&extra) == io.EOF
}

func (s *cityStore) download(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var input struct {
		Confirm bool   `json:"confirmDownload"`
		Release string `json:"release"`
	}
	if !cityInput(req, &input) || !input.Confirm || input.Release != cityRelease {
		controllerError(w, 400, "explicit city database download confirmation required")
		return
	}
	if status := s.status(); status.State == "ready" {
		writeCityJSON(w, status)
		return
	}
	s.mu.Lock()
	if s.state.State == "downloading" {
		s.mu.Unlock()
		controllerError(w, 409, "city download already running")
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 3*time.Minute)
	s.cancel = cancel
	s.state.State = "downloading"
	s.state.Reason = ""
	s.state.Received = 0
	s.mu.Unlock()
	defer cancel()
	// Reuse Mihomo's existing certificate roots, including its bundled CA set.
	// Normal TLS hostname checks remain enabled; redirects/environment proxies
	// cannot broaden the fixed download destination.
	transport := &HTTP.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: ca.GetCertPool()}}
	defer transport.CloseIdleConnections()
	client := &HTTP.Client{Transport: transport, Timeout: 3 * time.Minute, CheckRedirect: func(_ *HTTP.Request, _ []*HTTP.Request) error { return errors.New("redirect_not_allowed") }}
	err := installCity(ctx, s.path, client, cityURL, func(received int64) { s.mu.Lock(); s.state.Received = received; s.mu.Unlock() })
	s.mu.Lock()
	s.cancel = nil
	s.checked = true
	if err == nil {
		s.state.State = "ready"
		s.state.Reason = ""
	} else {
		s.state.State = "error"
		s.state.Reason = err.Error()
		// Only fixed stage codes originate in installCity; never return an HTTP
		// error object that could contain network metadata.
		if errors.Is(ctx.Err(), context.Canceled) {
			s.state.State = "missing"
			s.state.Reason = "cancelled"
		}
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			s.state.State = "error"
			s.state.Reason = "timeout"
		}
	}
	status := s.state
	s.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		w.WriteHeader(503)
	}
	writeCityJSON(w, status)
}

type cityProgress struct {
	io.Reader
	received int64
	changed  func(int64)
}

func (r *cityProgress) Read(p []byte) (int, error) {
	n, e := r.Reader.Read(p)
	r.received += int64(n)
	if n > 0 {
		r.changed(r.received)
	}
	return n, e
}

func installCity(ctx context.Context, path string, client *HTTP.Client, url string, progress func(int64)) error {
	dir := filepath.Dir(path)
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("storage")
	}
	request, err := HTTP.NewRequestWithContext(ctx, HTTP.MethodGet, url, nil)
	if err != nil {
		return errors.New("download")
	}
	response, err := client.Do(request)
	if err != nil {
		return errors.New("download")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return errors.New("download")
	}
	compressed, err := os.CreateTemp(dir, ".city-download-")
	if err != nil {
		return errors.New("storage")
	}
	defer os.Remove(compressed.Name())
	defer compressed.Close()
	gzipHash := sha256.New()
	progressReader := &cityProgress{Reader: io.TeeReader(response.Body, gzipHash), changed: progress}
	count, err := io.Copy(compressed, io.LimitReader(progressReader, cityGzipBytes+1))
	if err != nil {
		return errors.New("download")
	}
	if count != cityGzipBytes || hex.EncodeToString(gzipHash.Sum(nil)) != cityGzipSHA256 {
		return errors.New("integrity")
	}
	if _, err = compressed.Seek(0, io.SeekStart); err != nil {
		return errors.New("storage")
	}
	unzip, err := gzip.NewReader(compressed)
	if err != nil {
		return errors.New("decompress")
	}
	defer unzip.Close()
	staged, err := os.CreateTemp(dir, ".city-staging-")
	if err != nil {
		return errors.New("storage")
	}
	defer os.Remove(staged.Name())
	defer staged.Close()
	rawHash := sha256.New()
	count, err = io.Copy(io.MultiWriter(staged, rawHash), io.LimitReader(unzip, cityRawBytes+1))
	if err != nil {
		return errors.New("decompress")
	}
	if count != cityRawBytes || hex.EncodeToString(rawHash.Sum(nil)) != cityRawSHA256 {
		return errors.New("integrity")
	}
	if err = staged.Sync(); err != nil {
		return errors.New("storage")
	}
	if err = staged.Close(); err != nil {
		return errors.New("storage")
	}
	if err = validCityFile(staged.Name()); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return errors.New("cancelled_or_timeout")
	}
	// Data stays in the provider-protected credential directory, never under /ui/.
	// No successful publication exists until the fixed bytes and MMDB match.
	if err = os.Rename(staged.Name(), path); err != nil {
		return errors.New("storage")
	}
	directory, err := os.Open(dir)
	if err != nil {
		return errors.New("storage")
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return errors.New("storage")
	}
	return nil
}

type cityLocation struct {
	IP        string  `json:"ip"`
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	City      string  `json:"city"`
	Country   string  `json:"country"`
}
type cityRecord struct {
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`
	Country struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"country"`
	Location struct {
		Latitude  *float64 `maxminddb:"latitude"`
		Longitude *float64 `maxminddb:"longitude"`
	} `maxminddb:"location"`
}

func cityName(names map[string]string, locale string) string {
	switch locale {
	case "zh":
		locale = "zh-CN"
	case "zh-tw":
		locale = "zh-CN"
	}
	if value := names[locale]; value != "" {
		return value
	}
	return names["en"]
}
func (s *cityStore) lookup(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	var input struct {
		IPs    []string `json:"ips"`
		Locale string   `json:"locale"`
	}
	if !cityInput(req, &input) || len(input.IPs) > 128 {
		controllerError(w, 400, "invalid city lookup batch")
		return
	}
	if s.status().State != "ready" {
		controllerError(w, 409, "city database not available")
		return
	}
	reader, err := maxminddb.Open(s.path)
	if err != nil {
		controllerError(w, 503, "city database unreadable")
		return
	}
	defer reader.Close()
	out := map[string]*cityLocation{}
	for _, text := range input.IPs {
		if len(text) > 64 {
			controllerError(w, 400, "invalid IP")
			return
		}
		ip := net.ParseIP(text)
		if ip == nil {
			controllerError(w, 400, "IP literals only; no hostname resolution")
			return
		}
		out[text] = nil
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
			continue
		}
		var record cityRecord
		if reader.Lookup(ip, &record) != nil || record.Location.Latitude == nil || record.Location.Longitude == nil {
			continue
		}
		lat, lon := *record.Location.Latitude, *record.Location.Longitude
		if math.IsNaN(lat) || math.IsInf(lat, 0) || math.IsNaN(lon) || math.IsInf(lon, 0) || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
			continue
		}
		out[text] = &cityLocation{text, lat, lon, cityName(record.City.Names, input.Locale), cityName(record.Country.Names, input.Locale)}
	}
	writeCityJSON(w, map[string]any{"locations": out, "release": cityRelease, "scope": "local_only_no_origin_lookup"})
}
