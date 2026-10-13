package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	HTTP "net/http"
	"sync"
	"time"

	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	D "github.com/miekg/dns"
)

var diagnosticProbeMu sync.Mutex

const diagnosticProbeHost = "www.gstatic.com"

type diagnosticCheckInput struct {
	Kind  string `json:"kind"`
	Proxy string `json:"proxy"`
}
type diagnosticCheckResult struct {
	Kind       string           `json:"kind"`
	Stage      string           `json:"stage"`
	Outcome    string           `json:"outcome"`
	At         string           `json:"at"`
	DurationMS int64            `json:"durationMs"`
	Reason     string           `json:"reason,omitempty"`
	Error      *diagnosticError `json:"error,omitempty"`
	Details    map[string]any   `json:"details,omitempty"`
}

// The single explicit probe uses a fixed target; no caller URL/body or bandwidth
// loop. It exercises the selected kernel adapter, not the device-wide TUN path.
func diagnosticNetworkProbe(ctx context.Context, kind string, r resolver.Resolver, p C.Proxy) (stage string, details map[string]any, err error) {
	details = map[string]any{"target": "gstatic_https_204", "scope": "kernel_selected_adapter_not_system_tun"}
	if kind == "dns" {
		stage = "dns_exchange"
		details["target"] = "example_com_A"
		details["scope"] = "configured_core_resolver"
		if r == nil {
			return stage, details, errors.New("DNS_RESOLVER_UNAVAILABLE")
		}
		q := new(D.Msg)
		q.SetQuestion("example.com.", D.TypeA)
		answer, e := r.ExchangeContext(ctx, q)
		if e != nil {
			return stage, details, e
		}
		if answer == nil {
			return stage, details, errors.New("DNS_EMPTY_RESPONSE")
		}
		details["rcode"] = answer.Rcode
		details["answers"] = len(answer.Answer)
		details["truncated"] = answer.Truncated
		if answer.Rcode != D.RcodeSuccess {
			return stage, details, fmt.Errorf("DNS_RCODE_%d", answer.Rcode)
		}
		if len(answer.Answer) == 0 {
			return stage, details, errors.New("DNS_NO_ANSWER")
		}
		return stage, details, nil
	}
	stage = "proxy_dial"
	if p == nil {
		return stage, details, errors.New("PROXY_UNAVAILABLE")
	}
	started := time.Now()
	conn, e := p.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Type: C.INNER, Host: diagnosticProbeHost, DstPort: 443})
	details["dialMs"] = time.Since(started).Milliseconds()
	if e != nil {
		return stage, details, e
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	// Closing the socket cancels read/write even if a platform ignores deadlines.
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()
	defer close(done)
	stage = "tls_handshake"
	started = time.Now()
	secure := tls.Client(conn, &tls.Config{ServerName: diagnosticProbeHost, MinVersion: tls.VersionTLS12})
	if e = secure.HandshakeContext(ctx); e != nil {
		return stage, details, e
	}
	details["tlsMs"] = time.Since(started).Milliseconds()
	stage = "http_status"
	started = time.Now()
	status, e := diagnosticHTTPProbe(secure)
	details["httpMs"] = time.Since(started).Milliseconds()
	details["httpStatus"] = status
	return stage, details, e
}
func diagnosticHTTPProbe(secure net.Conn) (int, error) {
	_, e := io.WriteString(secure, "HEAD /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n")
	if e != nil {
		return 0, e
	}
	response, e := HTTP.ReadResponse(bufio.NewReader(io.LimitReader(secure, 16*1024)), &HTTP.Request{Method: "HEAD"})
	if e != nil {
		return 0, e
	}
	defer response.Body.Close()
	if response.StatusCode != 204 {
		return response.StatusCode, errors.New("PROBE_UNEXPECTED_HTTP_STATUS")
	}
	return response.StatusCode, nil
}
func getDiagnosticCheck(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	var input diagnosticCheckInput
	decoder := json.NewDecoder(io.LimitReader(req.Body, 2049))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || (input.Kind != "dns" && input.Kind != "connection" && input.Kind != "delay") || len(input.Proxy) > 256 {
		controllerError(w, 400, "invalid diagnostic check")
		return
	}
	if !diagnosticProbeMu.TryLock() {
		controllerError(w, 429, "diagnostic check busy")
		return
	}
	defer diagnosticProbeMu.Unlock()
	started := time.Now()
	ctx, cancel := context.WithTimeout(req.Context(), 8*time.Second)
	defer cancel()
	runLock.Lock()
	home := homeDir
	r := resolver.DefaultResolver
	var p C.Proxy
	if input.Proxy != "" {
		p = tunnel.Proxies()[input.Proxy]
	}
	ready := tunListener != nil
	runLock.Unlock()
	result := diagnosticCheckResult{Kind: input.Kind, At: started.UTC().Format(time.RFC3339Nano)}
	if !ready {
		result.Stage = "precondition"
		result.Outcome = "skipped"
		result.Reason = "core_not_ready"
	} else if input.Kind != "dns" && input.Proxy == "" {
		result.Stage = "precondition"
		result.Outcome = "skipped"
		result.Reason = "proxy_not_selected"
	} else {
		stage, details, err := diagnosticNetworkProbe(ctx, input.Kind, r, p)
		result.Stage = stage
		result.Details = details
		result.Outcome = "success"
		if err != nil {
			result.Outcome = "failed"
			if s, e := getDiagnosticStore(home, "kernel"); e == nil {
				result.Error = s.failure(err, 0)
			}
		}
	}
	result.DurationMS = time.Since(started).Milliseconds()
	if s, err := getDiagnosticStore(home, "kernel"); err == nil {
		if err = s.record(diagnosticEvent{Operation: "check_" + input.Kind, Stage: result.Stage, Outcome: result.Outcome, Object: input.Proxy, DurationMS: result.DurationMS, Reason: result.Reason, Error: result.Error, Details: result.Details}); err != nil {
			if result.Details == nil {
				result.Details = map[string]any{}
			}
			result.Details["evidencePersisted"] = false
		}
	}
	_ = json.NewEncoder(w).Encode(result)
}
