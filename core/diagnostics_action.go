package main

import (
	"encoding/json"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"gopkg.in/yaml.v3"
)

type diagnosticAction struct {
	Op               string         `json:"op"`
	ContextCollected *bool          `json:"contextCollected"`
	Operation        string         `json:"operation"`
	Stage            string         `json:"stage"`
	Outcome          string         `json:"outcome"`
	Object           string         `json:"object"`
	Reason           string         `json:"reason"`
	Code             string         `json:"code"`
	DurationMS       int64          `json:"durationMs"`
	Environment      map[string]any `json:"environment"`
	Settings         map[string]any `json:"settings"`
	Observations     map[string]any `json:"observations"`
}

func coreDiagnosticAction(home, input string) string {
	if len(input) > 16384 || !filepath.IsAbs(home) {
		return `{"error":"DIAGNOSTICS_INVALID"}`
	}
	var a diagnosticAction
	if json.Unmarshal([]byte(input), &a) != nil {
		return `{"error":"DIAGNOSTICS_INVALID"}`
	}
	if a.Op == "diagnostics-export" {
		bundle, e := diagnosticBundleForContext(home, a.ContextCollected)
		if e != nil {
			return `{"error":"DIAGNOSTICS_EXPORT_FAILED"}`
		}
		return bundle
	}
	s, err := getDiagnosticStore(home, "host")
	if err != nil {
		return `{"error":"DIAGNOSTICS_STORAGE_UNAVAILABLE"}`
	}
	switch a.Op {
	case "diagnostics-record":
		e := diagnosticEvent{Operation: a.Operation, Stage: a.Stage, Outcome: a.Outcome, Object: a.Object, Reason: a.Reason, DurationMS: a.DurationMS}
		// No arbitrary error message/object/exception crosses this API. Platform and
		// network business errors expose numeric/fixed codes; kernel causes collected
		// in the kernel process use the separately bounded redactor.
		if a.Code != "" {
			e.Error = &diagnosticError{Kind: "host_code", Code: diagnosticLabel(a.Code), Message: "host operation failed"}
		}
		e.Details = map[string]any{}
		for _, key := range []string{"appVersion", "versionCode", "sdkVersion", "osVersion", "deviceType", "abi", "networkType"} {
			if v, ok := a.Environment[key]; ok {
				switch value := v.(type) {
				case string:
					if len(value) <= 100 {
						e.Details[key] = value
					}
				case float64:
					e.Details[key] = value
				}
			}
		}
		for _, key := range []string{"vpnState", "tunCreateObserved", "kernelReadyReported", "stopOutcome", "failureCategory", "substageCoverage"} {
			if v, ok := a.Observations[key]; ok {
				switch value := v.(type) {
				case bool:
					e.Details[key] = value
				case string:
					if len(value) <= 100 {
						e.Details[key] = diagnosticLabel(value)
					}
				}
			}
		}
		settings := map[string]any{}
		for _, key := range []string{"keepAlive", "ipv6", "allowLan", "logToFile", "smartAutoConvert", "autoUpdate", "autoRestore", "mixedPort", "autoUpdateIntervalHours", "accessMode", "mode", "logLevel"} {
			if v, ok := a.Settings[key]; ok {
				switch value := v.(type) {
				case bool, float64:
					settings[key] = value
				case string:
					settings[key] = diagnosticLabel(value)
				}
			}
		}
		if len(settings) > 0 {
			e.Details["hostSettings"] = settings
			e.Details["settingsSource"] = "host_preferences_not_runtime_confirmation"
		}
		if err = s.record(e); err != nil {
			return `{"error":"DIAGNOSTICS_WRITE_FAILED"}`
		}
		return `{"recorded":true}`
	default:
		return `{"error":"DIAGNOSTICS_INVALID"}`
	}
}

// Allowlisted topology, no YAML/headers/URL/credentials. This describes the
// wrapper input and final platform projection; source.json is read only for
// fixed strategy flags, never subscription metadata or origin.
func diagnosticConfigSnapshot(home, text, overrides string) map[string]any {
	s, err := getDiagnosticStore(home, "kernel")
	if err != nil {
		return map[string]any{"status": "storage_unavailable"}
	}
	input := map[string]any{}
	if yaml.Unmarshal([]byte(text), &input) != nil {
		return map[string]any{"status": "config_unparseable"}
	}
	s.registerPrivateConfig(input)
	final := map[string]any{}
	if yaml.Unmarshal([]byte(text), &final) != nil {
		return map[string]any{"status": "config_unparseable"}
	}
	ov := map[string]any{}
	_ = json.Unmarshal([]byte(overrides), &ov)
	applyOverrides(final, overrides)
	projectPlatformConfig(final)
	raw := config.DefaultRawConfig()
	data, _ := yaml.Marshal(final)
	_ = yaml.Unmarshal(data, raw)
	out := map[string]any{"status": "projected_input", "coreVersion": constant.Version, "mode": raw.Mode.String(), "mixed-port": raw.MixedPort, "allow-lan": raw.AllowLan, "log-level": raw.LogLevel.String(), "dns": map[string]any{"enable": raw.DNS.Enable, "listen": s.text(raw.DNS.Listen), "enhanced-mode": raw.DNS.EnhancedMode.String(), "ipv6": raw.DNS.IPv6}}
	origins := map[string]string{}
	for key, setting := range map[string]string{"mode": "mode", "mixed-port": "mixedPort", "allow-lan": "allowLan", "log-level": "logLevel"} {
		source := "core_default"
		if _, ok := input[key]; ok {
			source = "generated_profile"
		}
		if v, ok := ov[setting]; ok && v != "" {
			source = "host_override"
		}
		origins[key] = source
	}
	origins["dns.listen"] = "core_default"
	if dns, ok := input["dns"].(map[string]any); ok {
		if _, exists := dns["listen"]; exists {
			origins["dns.listen"] = "generated_profile"
		} else if raw.DNS.Listen != "" {
			origins["dns.listen"] = "platform_default"
		}
	}
	origins["tun"] = "system_vpn_gvisor"
	out["sources"] = origins
	dns := out["dns"].(map[string]any)
	for key, list := range map[string][]string{"nameserver": raw.DNS.NameServer, "fallback": raw.DNS.Fallback, "default-nameserver": raw.DNS.DefaultNameserver, "proxy-server-nameserver": raw.DNS.ProxyServerNameserver, "direct-nameserver": raw.DNS.DirectNameServer} {
		values := []map[string]any{}
		for _, v := range list[:min(len(list), 32)] {
			values = append(values, s.endpoint(v))
		}
		dns[key] = values
		dns[key+"Omitted"] = max(0, len(list)-32)
	}
	for _, section := range []string{"proxies", "proxy-groups"} {
		items, _ := input[section].([]any)
		summary := []map[string]any{}
		for _, item := range items[:min(len(items), 64)] {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			row := map[string]any{}
			for _, key := range []string{"name", "server", "dialer-proxy"} {
				if v, ok := m[key].(string); ok {
					row[key] = s.object(v)
				}
			}
			for _, key := range []string{"port", "udp", "tls", "skip-cert-verify", "interval", "timeout"} {
				switch v := m[key].(type) {
				case int, bool:
					row[key] = v
				}
			}
			if v, ok := m["type"].(string); ok {
				row["type"] = diagnosticLabel(v)
			}
			for _, key := range []string{"proxies", "use"} {
				if refs, ok := m[key].([]any); ok {
					ids := []string{}
					for _, ref := range refs[:min(len(refs), 32)] {
						if v, ok := ref.(string); ok {
							ids = append(ids, s.object(v))
						}
					}
					row[key] = ids
					row[key+"Omitted"] = max(0, len(refs)-32)
				}
			}
			summary = append(summary, row)
		}
		out[section] = summary
		out[section+"Omitted"] = max(0, len(items)-64)
	}
	// Presence/counts diagnose empty providers without exporting subscription URLs.
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		m, _ := input[section].(map[string]any)
		out[section+"Count"] = len(m)
	}
	rules, _ := input["rules"].([]any)
	out["ruleCount"] = len(rules)
	return out
}
func diagnosticRecordConfig(text, overrides string) {
	kernelDiagnostic("effective_config", "projected", nil, diagnosticConfigSnapshot(homeDir, text, overrides))
}

// Named operational errors are retained, successful or generic connection
// records are excluded. This journal is additional to user-controlled logToFile.
func diagnosticStartResult(stage string, err error) {
	outcome := "success"
	if err != nil {
		outcome = "failed"
	}
	kernelDiagnostic(stage, outcome, err, nil)
}
func diagnosticReadVersion(home string) map[string]any {
	result := map[string]any{"effectiveVersion": "unknown"}
	data, err := os.ReadFile(filepath.Join(home, "profile-versions", "state.json"))
	if err != nil {
		return result
	}
	var state struct {
		Current *struct{ ID, ProfileID string }
	}
	if len(data) > 1024*1024 || json.Unmarshal(data, &state) != nil || state.Current == nil {
		return result
	}
	key, err := os.ReadFile(filepath.Join(home, "diagnostics", "correlation-key"))
	if err != nil || len(key) != 32 {
		return result
	}
	s := &diagnosticStore{key: key}
	result["effectiveVersion"] = s.object(state.Current.ID)
	result["profile"] = s.object(state.Current.ProfileID)
	if !strings.HasPrefix(state.Current.ID, "version-") || filepath.Base(state.Current.ID) != state.Current.ID {
		return result
	}
	if st, e := os.Stat(filepath.Join(home, "profile-versions", state.Current.ID, "overlay.yaml")); e == nil {
		result["profileOverlayPresent"] = st.Size() > 0
	} else {
		result["profileOverlayPresent"] = false
	}
	result["provenanceOrder"] = "original_then_profile_overlay_then_strategy_then_host_overrides_then_platform"
	result["sourceMetadata"] = "unknown"
	data, err = os.ReadFile(filepath.Join(home, "profile-versions", state.Current.ID, "source.json"))
	if err != nil || len(data) > 128*1024 {
		return result
	}
	var source struct {
		SmartConversion bool
		RegionPlan      *struct {
			Enable bool
			Mode   string
		}
	}
	if json.Unmarshal(data, &source) != nil {
		return result
	}
	result["sourceMetadata"] = "available"
	result["smartConversion"] = source.SmartConversion
	if source.RegionPlan != nil {
		result["regionEnabled"] = source.RegionPlan.Enable
		result["regionMode"] = diagnosticLabel(source.RegionPlan.Mode)
	}
	return result
}

func (s *diagnosticStore) endpoint(value string) map[string]any {
	out := map[string]any{"identity": s.object(value)}
	if !strings.Contains(value, "://") {
		value = "udp://" + value
	}
	u, err := url.Parse(value)
	if err != nil || u.Hostname() == "" {
		out["status"] = "unparsed"
		return out
	}
	out["protocol"] = diagnosticLabel(u.Scheme)
	out["host"] = s.object(u.Hostname())
	port := u.Port()
	if port == "" {
		switch u.Scheme {
		case "https", "h3", "quic":
			port = "443"
		case "tls":
			port = "853"
		default:
			port = "53"
		}
	}
	out["port"] = diagnosticLabel(port)
	if net.ParseIP(u.Hostname()) != nil {
		out["addressKind"] = "ip"
	} else {
		out["addressKind"] = "hostname"
	}
	out["hasProxySelector"] = u.Fragment != ""
	out["hasCustomPath"] = u.Path != ""
	out["hasQuery"] = u.RawQuery != ""
	return out
}
