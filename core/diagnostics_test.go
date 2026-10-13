package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	D "github.com/miekg/dns"
)

func TestDiagnosticRestartPreservesFailureAndCorrelation(t *testing.T) {
	home := t.TempDir()
	s, err := newDiagnosticStore(home, "kernel")
	if err != nil {
		t.Fatal(err)
	}
	failure := fmt.Errorf("proxy dial: %w", &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED})
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "proxy_dial", Outcome: "failed", Object: "private-node", Error: s.failure(failure, 0)}); err != nil {
		t.Fatal(err)
	}
	id := s.object("private-node")
	next, err := newDiagnosticStore(home, "kernel")
	if err != nil {
		t.Fatal(err)
	}
	if id != next.object("private-node") {
		t.Fatal("object identity lost across restart")
	}
	bundle, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(bundle, "proxy_dial") || !strings.Contains(bundle, "errno:111") || !strings.Contains(bundle, "kernel-previous") {
		t.Fatal("prior failure absent", bundle)
	}
	previous := readDiagnosticSource(s.root, "kernel-previous")
	if previous.Status != "available" || previous.Journal.Session == next.journal.Session {
		t.Fatal("session rotation invalid")
	}
	if len(next.journal.Events) != 0 || strings.Contains(bundle, "private-node") {
		t.Fatal("empty boot or redaction invalid")
	}
	// Three retained process generations, oldest explicitly absent at next boot.
	if _, err = newDiagnosticStore(home, "kernel"); err != nil {
		t.Fatal(err)
	}
	older := readDiagnosticSource(s.root, "kernel-older")
	if older.Journal.Session != s.journal.Session {
		t.Fatal("older retention invalid")
	}
	if _, err = newDiagnosticStore(home, "kernel"); err != nil {
		t.Fatal(err)
	}
	older = readDiagnosticSource(s.root, "kernel-older")
	if older.Journal.Session == s.journal.Session {
		t.Fatal("oldest not evicted")
	}
}
func TestDiagnosticRedactsBeforePersistenceAndKeepsErrorStructure(t *testing.T) {
	s, err := newDiagnosticStore(t.TempDir(), "host")
	if err != nil {
		t.Fatal(err)
	}
	s.registerPrivateConfig(map[string]any{"proxies": []any{map[string]any{"name": "Private Node Label", "password": "synthetic-password", "uuid": "synthetic-uuid", "server": "private.proxy.test", "ws-opts": map[string]any{"headers": map[string]any{"X-Auth": "synthetic-header"}}}}})
	raw := "dial Private Node Label private.proxy.test:443: ECONNREFUSED; synthetic-password synthetic-uuid synthetic-header; https://user:pass@subscription.test/feed?token=synthetic-sub#frag; Authorization: Bearer synthetic-controller; password=synthetic-equals; /home/private-user/config.yaml"
	e := s.failure(fmt.Errorf("failed: %w", errors.New(raw)), 0)
	if err = s.record(diagnosticEvent{Operation: "connection", Stage: "proxy_dial", Outcome: "failed", Error: e}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(s.root, "host-current.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"Private Node Label", "private.proxy.test", "synthetic-password", "synthetic-uuid", "synthetic-header", "subscription.test", "synthetic-sub", "synthetic-controller", "synthetic-equals", "private-user"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("secret survived persistence: %s", secret)
		}
	}
	if !strings.Contains(string(data), "ECONNREFUSED") || len(e.Causes) != 1 || !strings.Contains(e.Message, s.object("Private Node Label")) {
		t.Fatal("structure or identity lost", string(data))
	}
	if e.Code != "" {
		t.Fatal("invented error code")
	}
}
func TestDiagnosticRotationCapacityMissingCorruptionAndExportBound(t *testing.T) {
	home := t.TempDir()
	for _, lane := range []string{"host", "kernel"} {
		for boot := 0; boot < 3; boot++ {
			s, err := newDiagnosticStore(home, lane)
			if err != nil {
				t.Fatal(err)
			}
			for i := 0; i < 300; i++ {
				if err = s.record(diagnosticEvent{Operation: "fixture", Stage: "test", Outcome: "failed", Error: &diagnosticError{Kind: "fixture", Message: strings.Repeat("x", 2000)}}); err != nil {
					t.Fatal(err)
				}
			}
			st, err := os.Stat(filepath.Join(s.root, lane+"-current.json"))
			if err != nil || st.Size() > diagnosticJournalLimit {
				t.Fatal("journal exceeded bound")
			}
			if s.journal.Dropped == 0 {
				t.Fatal("missing truncation count")
			}
		}
	}
	bundle, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle) > diagnosticBundleLimit {
		t.Fatal("bundle exceeded bound")
	}
	if !strings.Contains(bundle, "exportOmitted") {
		t.Fatal("export omission unmarked")
	}
	var parsed map[string]any
	if json.Unmarshal([]byte(bundle), &parsed) != nil {
		t.Fatal("invalid bundle")
	}
	missing := readDiagnosticSource(t.TempDir(), "host-current")
	if missing.Status != "missing" {
		t.Fatal(missing)
	}
	if err = os.WriteFile(filepath.Join(home, "diagnostics", "host-current.json"), []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	invalid := readDiagnosticSource(filepath.Join(home, "diagnostics"), "host-current")
	if invalid.Status != "invalid" {
		t.Fatal(invalid)
	}
}
func TestDiagnosticActionDoesNotRequireConfigurationAndRejectsPrivateExtras(t *testing.T) {
	home := t.TempDir()
	result := coreDiagnosticAction(home, `{"op":"diagnostics-record","operation":"vpn","stage":"system_authorization","outcome":"failed","code":"201","environment":{"appVersion":"0.1.0","osVersion":"HarmonyOS 7.0.0.109","secret":"forbidden"},"settings":{"allowLan":false,"mixedPort":7890,"mainGroup":"private","origin":"https://secret.test/sub"}}`)
	if result != `{"recorded":true}` {
		t.Fatal(result)
	}
	bundle := coreDiagnosticAction(home, `{"op":"diagnostics-export"}`)
	for _, secret := range []string{"forbidden", "private", "secret.test"} {
		if strings.Contains(bundle, secret) {
			t.Fatal("unexpected exported extra", secret)
		}
	}
	if !strings.Contains(bundle, "HarmonyOS 7.0.0.109") || !strings.Contains(bundle, "system_authorization") {
		t.Fatal("evidence missing", bundle)
	}
	// Unavailable correlation key must not hide already-sanitized old evidence.
	if err := os.Remove(filepath.Join(home, "diagnostics", "correlation-key")); err != nil {
		t.Fatal(err)
	}
	if bundle = coreDiagnosticAction(home, `{"op":"diagnostics-export"}`); !strings.Contains(bundle, "system_authorization") {
		t.Fatal("prior evidence hidden by key failure")
	}
}

type fixtureResolver struct {
	resolver.Resolver
	rcode int
	err   error
}

func (r fixtureResolver) ExchangeContext(ctx context.Context, q *D.Msg) (*D.Msg, error) {
	if q.Question[0].Name != "example.com." || q.Question[0].Qtype != D.TypeA {
		return nil, errors.New("unexpected probe")
	}
	if r.err != nil {
		return nil, r.err
	}
	a := new(D.Msg)
	a.SetReply(q)
	a.Rcode = r.rcode
	if r.rcode == D.RcodeSuccess {
		a.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: "example.com.", Rrtype: D.TypeA, Class: D.ClassINET}, A: net.IPv4(192, 0, 2, 1)}}
	}
	return a, nil
}

type fixtureProxy struct {
	C.Proxy
	err  error
	conn C.Conn
}

func (p fixtureProxy) DialContext(ctx context.Context, m *C.Metadata) (C.Conn, error) {
	if m.Host != diagnosticProbeHost || m.DstPort != 443 {
		return nil, errors.New("unexpected target")
	}
	return p.conn, p.err
}

type baseCoreConn = C.Conn
type fixtureConn struct {
	baseCoreConn
	net.Conn
}

func (c fixtureConn) Read(p []byte) (int, error)         { return c.Conn.Read(p) }
func (c fixtureConn) Write(p []byte) (int, error)        { return c.Conn.Write(p) }
func (c fixtureConn) Close() error                       { return c.Conn.Close() }
func (c fixtureConn) LocalAddr() net.Addr                { return c.Conn.LocalAddr() }
func (c fixtureConn) RemoteAddr() net.Addr               { return c.Conn.RemoteAddr() }
func (c fixtureConn) SetDeadline(t time.Time) error      { return c.Conn.SetDeadline(t) }
func (c fixtureConn) SetReadDeadline(t time.Time) error  { return c.Conn.SetReadDeadline(t) }
func (c fixtureConn) SetWriteDeadline(t time.Time) error { return c.Conn.SetWriteDeadline(t) }

func TestDiagnosticTypicalFailuresDistinguishStagesWithoutNetwork(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	for _, test := range []struct {
		name        string
		r           fixtureResolver
		stage, code string
	}{
		{"nxdomain", fixtureResolver{rcode: D.RcodeNameError}, "dns_exchange", "DNS_RCODE_3"},
		{"servfail", fixtureResolver{rcode: D.RcodeServerFailure}, "dns_exchange", "DNS_RCODE_2"},
		{"dns_timeout", fixtureResolver{err: context.DeadlineExceeded}, "dns_exchange", "context deadline exceeded"},
	} {
		t.Run(test.name, func(t *testing.T) {
			stage, details, err := diagnosticNetworkProbe(ctx, "dns", test.r, nil)
			if stage != test.stage || err == nil || err.Error() != test.code {
				t.Fatal(stage, details, err)
			}
		})
	}
	stage, _, err := diagnosticNetworkProbe(ctx, "connection", nil, fixtureProxy{err: syscall.ECONNREFUSED})
	if stage != "proxy_dial" || !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatal(stage, err)
	}
	stage, _, err = diagnosticNetworkProbe(ctx, "dns", fixtureResolver{}, nil)
	if stage != "dns_exchange" || err != nil {
		t.Fatal(stage, err)
	}
	// A socket that speaks plaintext proves dial succeeded but TLS failed.
	local, peer := net.Pipe()
	defer peer.Close()
	go func() {
		b := make([]byte, 1024)
		_, _ = peer.Read(b)
		_, _ = peer.Write([]byte("HTTP/1.1 403 Forbidden\r\n\r\n"))
		peer.Close()
	}()
	stage, _, err = diagnosticNetworkProbe(ctx, "connection", nil, fixtureProxy{conn: fixtureConn{Conn: local}})
	if stage != "tls_handshake" || err == nil {
		t.Fatal(stage, err)
	}
}

func TestDiagnosticHTTPProbeStatusAndTrafficBudget(t *testing.T) {
	for _, status := range []int{204, 403, 502} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			local, peer := net.Pipe()
			defer local.Close()
			defer peer.Close()
			_ = local.SetDeadline(time.Now().Add(time.Second))
			sent := make(chan string, 1)
			go func() {
				b := make([]byte, 512)
				n, _ := peer.Read(b)
				sent <- string(b[:n])
				_, _ = fmt.Fprintf(peer, "HTTP/1.1 %d Fixture\r\nConnection: close\r\n\r\n", status)
				peer.Close()
			}()
			got, err := diagnosticHTTPProbe(local)
			if got != status || (err == nil) != (status == 204) {
				t.Fatal(got, err)
			}
			request := <-sent
			if !strings.HasPrefix(request, "HEAD /generate_204 ") || len(request) > 256 {
				t.Fatal("unexpected bandwidth/body request")
			}
		})
	}
}
func TestDiagnosticConfigSnapshotProvenanceAndPrivateFields(t *testing.T) {
	home := t.TempDir()
	text := `mixed-port: 9000
mode: rule
dns:
  enable: true
  listen: 127.0.0.1:1053
  nameserver: ['https://private-dns.test/dns-query?token=dnsfake']
proxies:
  - {name: SyntheticNode, type: ss, server: private-node.test, port: 443, password: synthetic-node-password}
proxy-groups:
  - {name: SyntheticGroup, type: select, proxies: [SyntheticNode]}
proxy-providers:
  privateProvider: {type: http, url: 'https://private-sub.test/synthetic-token'}
`
	snapshot := diagnosticConfigSnapshot(home, text, `{"mixedPort":7890,"logLevel":"info","allowLan":false,"logToFile":false}`)
	data, _ := json.Marshal(snapshot)
	for _, secret := range []string{"private-dns.test", "dnsfake", "private-node.test", "synthetic-node-password", "private-sub.test", "synthetic-token", "privateProvider", "SyntheticNode", "SyntheticGroup"} {
		if strings.Contains(string(data), secret) {
			t.Fatal("private config survived", secret)
		}
	}
	if snapshot["mixed-port"] != 7890 || snapshot["sources"].(map[string]string)["mixed-port"] != "host_override" || snapshot["sources"].(map[string]string)["dns.listen"] != "generated_profile" {
		t.Fatal("provenance/value invalid", snapshot)
	}
	s, _ := getDiagnosticStore(home, "kernel")
	rows := snapshot["proxies"].([]map[string]any)
	group := snapshot["proxy-groups"].([]map[string]any)
	if rows[0]["name"] != s.object("SyntheticNode") || group[0]["proxies"].([]string)[0] != rows[0]["name"] {
		t.Fatal("topology association lost")
	}
	oldHome := homeDir
	homeDir = home
	defer func() { homeDir = oldHome }()
	if err := validateProviderPath("diagnostics/correlation-key"); err == nil {
		t.Fatal("diagnostic key is a provider resource")
	}
}

func TestDiagnosticFailedWriteIsVisibleWithoutReplacingPriorEvidence(t *testing.T) {
	home := t.TempDir()
	s, err := getDiagnosticStore(home, "host")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "system_authorization", Outcome: "failed"}); err != nil {
		t.Fatal(err)
	}
	if err = os.Rename(s.root, s.root+"-fixture-offline"); err != nil {
		t.Fatal(err)
	}
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "system_stop", Outcome: "unknown"}); err == nil {
		t.Fatal("unwritable storage falsely succeeded")
	}
	if err = os.Rename(s.root+"-fixture-offline", s.root); err != nil {
		t.Fatal(err)
	}
	bundle, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(bundle, `"liveWriteFailures": 1`) || !strings.Contains(bundle, `"unpersistedEvents": 1`) || !strings.Contains(bundle, "system_authorization") {
		t.Fatal("write failure/prior evidence missing", bundle)
	}
}
func TestDiagnosticExportSaltingAndSymlinkExclusion(t *testing.T) {
	home := t.TempDir()
	s, err := getDiagnosticStore(home, "host")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.record(diagnosticEvent{Operation: "vpn", Stage: "test", Outcome: "failed", Object: "synthetic-node"}); err != nil {
		t.Fatal(err)
	}
	one, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	two, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(one, s.object("synthetic-node")) || one == two {
		t.Fatal("export did not salt identities")
	}
	secret := filepath.Join(home, "not-diagnostic.json")
	_ = os.WriteFile(secret, []byte(`{"schema":1,"events":[{"details":{"secret":"synthetic-leak"}}]}`), 0600)
	if err = os.Symlink(secret, filepath.Join(s.root, "kernel-current.json")); err != nil {
		t.Fatal(err)
	}
	bundle, err := diagnosticBundle(home)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(bundle, "synthetic-leak") || !strings.Contains(bundle, "not_regular_file") {
		t.Fatal("unrelated symlink exported", bundle)
	}
}

func TestDiagnosticInvalidProjectionAndJoinedCausesStayExplicit(t *testing.T) {
	home := t.TempDir()
	summary := diagnosticConfigSnapshot(home, "mixed-port: not-a-port\n", "")
	if summary["status"] != "invalid_projected_field_types" {
		t.Fatal("invalid input silently replaced by defaults", summary)
	}
	s, err := newDiagnosticStore(t.TempDir(), "kernel")
	if err != nil {
		t.Fatal(err)
	}
	joined := s.failure(errors.Join(syscall.ECONNREFUSED, context.DeadlineExceeded), 0)
	if len(joined.Causes) != 2 || joined.Causes[0].Code != "errno:111" || joined.Causes[1].Code != "deadline_exceeded" {
		t.Fatal("joined causes collapsed", joined)
	}
	many := s.failure(errors.Join(syscall.ECONNREFUSED, syscall.EIO, syscall.EPERM, syscall.ENOENT, syscall.EPIPE), 0)
	if len(many.Causes) != 4 || !many.CausesTruncated {
		t.Fatal("joined cause limit unmarked", many)
	}
}

func TestDiagnosticShortSecretsCannotDefeatURLRedactionOrOpaqueIdentity(t *testing.T) {
	s, err := newDiagnosticStore(t.TempDir(), "kernel")
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"/", "a", "https", "object-deadbeefdeadbeef"} {
		s.registerPrivateConfig(map[string]any{"password": secret, "name": "SyntheticNode"})
		text := s.text("dial SyntheticNode: https://user:pass@private.test/path-with-private-credential?hidden=private-query-value; credential " + secret)
		if strings.HasPrefix(secret, "object-") && strings.Contains(text, secret) {
			t.Fatal("opaque-looking credential persisted", text)
		}
		for _, private := range []string{"private.test", "path-with-private-credential", "private-query-value"} {
			if strings.Contains(text, private) {
				t.Fatal("short secret defeated URL masking", secret, text)
			}
		}
		if !strings.Contains(text, s.object("SyntheticNode")) {
			t.Fatal("short secret rewrote object identity", secret, text)
		}
	}
}
