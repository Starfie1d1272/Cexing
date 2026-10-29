package main

import (
	"math"
	"regexp"
	"strconv"
	"strings"
)

// These are vocabularies, not syntax filters. An identifier-shaped credential
// must never become a plaintext diagnostic label or error code.
const diagnosticOperations = "vpn host core profile subscription configuration entry recovery connection fixture check_controller check_dns check_connection check_delay check_bandwidth"
const diagnosticStages = "authorization service vpn protect assets core-init config core-start readiness system_authorization system_stop service_bind service_unbind network_protect resource_prepare core_init effective_config config_parse controller_listen config_apply tun_start core_ready core_stop config_reload_parse config_reload settings_patch runtime_error controller_transport controller_credentials controller_authorization controller_http controller_version precondition dns_exchange proxy_dial tls_handshake http_status state_observation environment test native_evidence recovery_probe recovery_binding recovery_validation runtime_validation start_precondition service_binding kernel_readiness stop tun_create geodata_prepare smart_model_prepare panel_assets_prepare core_initialize configuration_prepare core_start tun_destroy late_tun_destroy"
const diagnosticOutcomes = "started success failed skipped unknown cancelled observed projected completed applied rejected warning error"
const diagnosticReasons = "requires_explicit_bandwidth_test credentials_unavailable core_not_ready proxy_not_selected transport_error not_reported evidence_unavailable extension_event_via_ipc snapshot_missing_at_stop_return retired_request_not_collected native_snapshot_not_collected"
const diagnosticProxyTypes = "direct reject reject-drop compatible pass pass-rule rematch dns ss ssr snell socks5 http vmess vless trojan hysteria hysteria2 wireguard tuic ssh mieru anytls sudoku masque trusttunnel shadowquic openvpn tailscale zerotier selector select url-test fallback load-balance smart relay"

func diagnosticEnum(value, vocabulary string) string {
	for _, allowed := range strings.Fields(vocabulary) {
		if value == allowed {
			return value
		}
	}
	return "unknown"
}
func (s *diagnosticStore) enumField(out map[string]any, key, value, vocabulary string) {
	out[key] = diagnosticEnum(value, vocabulary)
	if out[key] == "unknown" && value != "" && value != "unknown" {
		out[key+"Identity"] = s.object(value)
	}
}

var diagnosticNumberCode = regexp.MustCompile(`^-?[0-9]{1,10}$`)

func diagnosticCodeValue(value string) (string, bool) {
	if diagnosticNumberCode.MatchString(value) {
		n, err := strconv.ParseInt(value, 10, 64)
		if err == nil && n >= -2147483648 && n <= 4294967295 {
			return strconv.FormatInt(n, 10), true
		}
	}
	if strings.HasPrefix(value, "errno:") {
		n, err := strconv.ParseUint(strings.TrimPrefix(value, "errno:"), 10, 32)
		if err == nil && n <= 2147483647 {
			return "errno:" + strconv.FormatUint(n, 10), true
		}
	}
	if strings.HasPrefix(value, "DNS_RCODE_") {
		n, err := strconv.ParseUint(strings.TrimPrefix(value, "DNS_RCODE_"), 10, 16)
		if err == nil && n <= 23 {
			return "DNS_RCODE_" + strconv.FormatUint(n, 10), true
		}
	}
	const fixed = "GEOSITE_MISSING RESOURCE_MISSING PROVIDER_UNRESOLVED VALIDATOR_BUSY VALIDATOR_HOME CONFIG_INVALID CORE_VALIDATION_FAILED VERSION_INVALID VERSION_STATE_INVALID VERSION_STALE VERSION_GLOBAL_STALE VERSION_COMPILE_FAILED VERSION_STAGE_FAILED VERSION_VERIFY_FAILED VERSION_COMMIT_FAILED EDIT_INTENT_FAILED BACKUP_RECOVERY_REQUIRED unknown deadline_exceeded cancelled DNS_RESOLVER_UNAVAILABLE DNS_EMPTY_RESPONSE DNS_NO_ANSWER PROXY_UNAVAILABLE PROBE_UNEXPECTED_HTTP_STATUS ECONNREFUSED ECONNRESET ETIMEDOUT ENETUNREACH EHOSTUNREACH EACCES EADDRINUSE EADDRNOTAVAIL TLS_CERTIFICATE TLS_HANDSHAKE_FAILED NATIVE_STOP_SNAPSHOT_PENDING NATIVE_EVIDENCE_SUPERSEDED NATIVE_EVIDENCE_SCOPE_MISMATCH NATIVE_EVENTS_TRUNCATED NATIVE_EVENT_INVALID NATIVE_EVENTS_UNAVAILABLE CONTROLLER_PROBE_UNCONFIRMED VPN_SESSION_UNCONFIRMED SERVICE_BIND_FAILED STOP_NOT_CONFIRMED START_SUPERSEDED AUTHORIZATION_FAILED OPTIONAL_MODEL_UNAVAILABLE OPTIONAL_PANEL_UNAVAILABLE TUN_DESTROY_FAILED CORE_STOP_FAILED TUN_CREATE_FAILED PROTECT_FAILED GEODATA_PREPARE_FAILED SMART_MODEL_PREPARE_FAILED PANEL_ASSETS_PREPARE_FAILED CORE_INITIALIZE_FAILED CONFIGURATION_PREPARE_FAILED CORE_START_FAILED LATE_TUN_DESTROY_FAILED"
	for _, v := range strings.Fields(fixed) {
		if value == v {
			return value, true
		}
	}
	return "unknown", false
}
func (s *diagnosticStore) hostCode(value string) *diagnosticError {
	if value == "" {
		return nil
	}
	code, known := diagnosticCodeValue(value)
	out := &diagnosticError{Kind: "host_code", Code: code, Message: "host operation failed"}
	if !known {
		out.CodeIdentity = s.object(value)
	}
	return out
}

var diagnosticVersion = regexp.MustCompile(`^v?[0-9]{1,4}(?:\.[0-9]{1,4}){1,3}(?:-(?:alpha|beta|rc)(?:\.[0-9]{1,4})?)?$`)
var diagnosticOSVersion = regexp.MustCompile(`^(?:HarmonyOS|OpenHarmony)[ -][0-9]{1,4}(?:\.[0-9]{1,4}){1,3}$`)
var diagnosticABI = regexp.MustCompile(`^(?:arm64-v8a|armeabi-v7a|x86_64|x86)(?:,(?:arm64-v8a|armeabi-v7a|x86_64|x86))*$`)

func (s *diagnosticStore) environment(out map[string]any, input map[string]any) {
	for _, key := range []string{"appVersion", "osVersion", "abi", "deviceType", "networkType", "versionCode", "sdkVersion"} {
		value, found := input[key]
		if !found {
			continue
		}
		if key == "versionCode" || key == "sdkVersion" {
			limit := float64(2147483647)
			if key == "sdkVersion" {
				limit = 1000
			}
			s.numberField(out, key, value, 0, limit)
			continue
		}
		v, ok := value.(string)
		if !ok {
			out[key] = "unknown"
			continue
		}
		valid := false
		switch key {
		case "appVersion":
			valid = diagnosticVersion.MatchString(v)
		case "osVersion":
			valid = diagnosticOSVersion.MatchString(v)
		case "abi":
			valid = diagnosticABI.MatchString(v)
		case "deviceType":
			s.enumField(out, key, v, "phone tablet 2in1 wearable tv car pc default unknown")
			continue
		case "networkType":
			s.enumField(out, key, v, "wifi cellular ethernet none unknown")
			continue
		}
		if valid {
			out[key] = v
		} else {
			out[key] = "unknown"
			if v != "" {
				out[key+"Identity"] = s.object(v)
			}
		}
	}
}
func (s *diagnosticStore) numberField(out map[string]any, key string, value any, min, max float64) {
	v, ok := value.(float64)
	if ok && !math.IsNaN(v) && math.Trunc(v) == v && v >= min && v <= max {
		out[key] = v
		return
	}
	out[key] = "unknown"
	if text, ok := value.(string); ok && text != "" {
		out[key+"Identity"] = s.object(text)
	}
}
func (s *diagnosticStore) settings(out map[string]any, input map[string]any) {
	for _, key := range []string{"keepAlive", "ipv6", "allowLan", "logToFile", "smartAutoConvert", "autoUpdate", "autoRestore"} {
		if value, ok := input[key]; ok {
			if b, ok := value.(bool); ok {
				out[key] = b
			} else {
				out[key] = "unknown"
				if text, ok := value.(string); ok {
					out[key+"Identity"] = s.object(text)
				}
			}
		}
	}
	if v, ok := input["mixedPort"]; ok {
		s.numberField(out, "mixedPort", v, 0, 65535)
	}
	if v, ok := input["autoUpdateIntervalHours"]; ok {
		s.numberField(out, "autoUpdateIntervalHours", v, 1, 8760)
	}
	for key, allowed := range map[string]string{"accessMode": "all white black", "mode": "rule global direct", "logLevel": "debug info warning error silent"} {
		if value, ok := input[key]; ok {
			if v, ok := value.(string); ok {
				if key == "mode" && v == "" {
					out[key] = ""
				} else {
					s.enumField(out, key, v, allowed)
				}
			} else {
				out[key] = "unknown"
			}
		}
	}
}
func (s *diagnosticStore) observations(out map[string]any, input map[string]any) {
	for _, key := range []string{"tunCreateObserved", "kernelReadyReported"} {
		if value, ok := input[key]; ok {
			if b, ok := value.(bool); ok {
				out[key] = b
			} else {
				out[key] = "unknown"
			}
		}
	}
	for key, allowed := range map[string]string{"vpnState": "disconnected connecting connected disconnecting unknown", "stopOutcome": "not_reported completed unknown", "failureCategory": "unknown permission configuration dns tls timeout network", "substageCoverage": "system_authorization_binding_protect_assets_not_observable_via_status_getters"} {
		if value, ok := input[key]; ok {
			if v, ok := value.(string); ok {
				s.enumField(out, key, v, allowed)
			} else {
				out[key] = "unknown"
			}
		}
	}
}

func diagnosticPublicConfigValue(key, value string) bool {
	vocabulary := ""
	switch strings.ToLower(key) {
	case "type":
		vocabulary = diagnosticProxyTypes
	case "mode":
		vocabulary = "rule global direct region all"
	case "enhanced-mode":
		vocabulary = "fake-ip redir-host"
	case "log-level", "loglevel":
		vocabulary = "debug info warning error silent"
	}
	return vocabulary != "" && diagnosticEnum(value, vocabulary) != "unknown"
}

func (s *diagnosticStore) logFailure(payload string) *diagnosticError {
	message := s.text(payload)
	out := &diagnosticError{Kind: "core_log", Message: message, DetailOmitted: message == "DETAIL_OMITTED_REDACTION_CAPACITY"}
	// A classification of the error suffix, not an invented numeric errno.
	suffix := payload
	if i := strings.LastIndex(payload, "error:"); i >= 0 {
		suffix = payload[i+6:]
	}
	lower := strings.ToLower(suffix)
	for _, pair := range [][2]string{{"connection refused", "connection_refused"}, {"econnrefused", "connection_refused"}, {"context deadline exceeded", "timeout"}, {"i/o timeout", "timeout"}, {"certificate", "tls_certificate"}, {"tls handshake", "tls_handshake"}, {"connection reset", "connection_reset"}} {
		if strings.Contains(lower, pair[0]) {
			out.Condition = pair[1]
			break
		}
	}
	return out
}

// Schema 1 journals may contain pre-fix plaintext labels/messages. Salvage their
// time, stages, numeric/fixed codes and cause structure, not their free text.
// Never rewrite or delete the original evidence as part of export.
func (s *diagnosticStore) sanitizeLegacy(journal *diagnosticJournal) {
	for i := range journal.Events {
		e := &journal.Events[i]
		old := e.Details
		safe := map[string]any{"legacyDetailsOmitted": len(old) > 0}
		s.environment(safe, old)
		s.observations(safe, old)
		if prefs, ok := old["hostSettings"].(map[string]any); ok {
			settings := map[string]any{}
			s.settings(settings, prefs)
			safe["hostSettings"] = settings
		}
		for _, key := range []string{"rcode", "answers", "httpStatus", "startupElapsedMs", "dialMs", "tlsMs", "httpMs"} {
			if value, ok := old[key]; ok {
				s.numberField(safe, key, value, 0, 2147483647)
			}
		}
		labels := map[string]string{}
		for key, value := range map[string]string{"operation": e.Operation, "stage": e.Stage, "outcome": e.Outcome, "reason": e.Reason} {
			if key == "reason" && value == "" {
				continue
			}
			allowed := diagnosticOperations
			switch key {
			case "stage":
				allowed = diagnosticStages
			case "outcome":
				allowed = diagnosticOutcomes
			case "reason":
				allowed = diagnosticReasons
			}
			labels[key] = diagnosticEnum(value, allowed)
			if labels[key] == "unknown" && value != "" && value != "unknown" {
				safe[key+"Identity"] = s.object(value)
			}
		}
		e.Operation = labels["operation"]
		e.Stage = labels["stage"]
		e.Outcome = labels["outcome"]
		e.Reason = labels["reason"]
		e.Details = safe
		if e.Object != "" && (len(e.Object) != 23 || !diagnosticOpaque.MatchString(e.Object)) {
			e.Object = s.object(e.Object)
		}
		s.sanitizeLegacyError(e.Error)
	}
}
func (s *diagnosticStore) sanitizeLegacyError(e *diagnosticError) {
	if e == nil {
		return
	}
	const kinds = "host_code core_log *errors.errorString *fmt.wrapError *errors.joinError *net.OpError *os.PathError syscall.Errno context.deadlineExceededError *tls.CertificateVerificationError x509.UnknownAuthorityError x509.HostnameError x509.CertificateInvalidError"
	if diagnosticEnum(e.Kind, kinds) == "unknown" {
		e.Kind = "legacy_error"
	}
	if e.Code != "" {
		code, known := diagnosticCodeValue(e.Code)
		if !known {
			e.CodeIdentity = s.object(e.Code)
		}
		e.Code = code
	}
	e.Condition = s.logFailure(e.Message).Condition
	e.Message = "LEGACY_MESSAGE_OMITTED_PRIVACY_POLICY"
	e.DetailOmitted = true
	for i := range e.Causes {
		s.sanitizeLegacyError(&e.Causes[i])
	}
}
