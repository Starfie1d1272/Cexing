// engine.go - mihomo 内核生命周期管理（初始化 / 启动 TUN / 停止）
//
// 启动流程:
//  1. coreInit: 设置 homeDir（country.mmdb / config 缓存等落盘目录）
//  2. coreStartTun: 把 ArkTS 侧传入的 configJson（JSON，YAML 兼容）覆盖到 mihomo
//     默认配置上 -> config.ParseRawConfig -> 宿主 Controller + executor（起 mixed-port /
//     dns / external-controller）-> 用系统下发的 tun fd 单独起 gVisor TUN 入站
//  3. coreStop: 关 TUN -> listener.StopListener（external-controller 随 config
//     重载关闭；Go runtime 常驻不卸载，dlclose 不安全）
package main

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/metacubex/mihomo/constant"
	MDNS "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

const (
	defaultMixedPort  = 7890
	defaultController = "127.0.0.1:9090"
	defaultDNSListen  = "127.0.0.1:1053"
)

var (
	runLock     sync.Mutex
	initialized bool
	tunListener *sing_tun.Listener
	homeDir     string
	logSub      <-chan log.Event
)

// sanitizeConfigJson - 清洗 ArkTS 侧传入的配置文本（防御性，双端修复）：
//  1. 去 UTF-8 BOM
//  2. 修复旧版前端导入路径造成的 UTF-8 双重编码：String.fromCharCode 把原始
//     字节逐字节映射成 U+0000~U+00FF 字符再落盘，续字节 0x80~0x9F 变成 C1 控制符，
//     yaml.v3 解析报 "control characters are not allowed"。检测到 C1 控制符且
//     全部码点 ≤0xFF 时，把码点还原为字节（恢复原始 UTF-8 字节流）。
func sanitizeConfigJson(s string) string {
	s = strings.TrimPrefix(s, "\ufeff")
	hasC1 := false
	allLatin1 := true
	for _, r := range s {
		if r >= 0x80 && r <= 0x9F {
			hasC1 = true
		}
		if r > 0xFF {
			allLatin1 = false
		}
	}
	if !hasC1 || !allLatin1 {
		return s
	}
	bytes := make([]byte, 0, len(s))
	for _, r := range s {
		bytes = append(bytes, byte(r))
	}
	if utf8.Valid(bytes) {
		log.Warnln("[OHOS] configJson repaired from byte-flattened UTF-8 (%d -> %d bytes)", len(s), len(bytes))
		return string(bytes)
	}
	return s
}

// tunExt - configJson 中 "tun" 节点的扩展字段（mihomo RawTun 没有 address 字段，
// 由 wrapper 消费后不传给 mihomo 本体）
type tunExt struct {
	stack     string
	address   string
	mtu       uint32
	dnsHijack []string
}

func defaultTunExt() tunExt {
	return tunExt{
		stack:     "gvisor",
		address:   "172.19.0.1/30",
		mtu:       9000,
		dnsHijack: []string{"0.0.0.0:53"},
	}
}

// Snapshot is immutable until the system TUN stops; readers include offline previews.
var tunIPv6Snapshot atomic.Pointer[bool]

func defaultTunOptions(fd int, ipv6 bool) LC.Tun {
	ext := defaultTunExt()
	opts := LC.Tun{
		Enable: true, Device: "Cexing", Stack: enforceStack(constant.TunGvisor),
		DNSHijack: ext.dnsHijack, AutoRoute: false, AutoDetectInterface: false,
		Inet4Address: []netip.Prefix{netip.MustParsePrefix(ext.address)}, MTU: ext.mtu, FileDescriptor: fd,
	}
	if ipv6 {
		opts.Inet6Address = []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
		opts.DNSHijack = append(opts.DNSHijack, "[::]:53")
	}
	return opts
}

func coreInit(home string) (result error) {
	defer func() { diagnosticStartResult("core_init", result) }()
	runLock.Lock()
	defer runLock.Unlock()
	if tunListener != nil {
		return errors.New("mihomoInit: cannot reinitialize a running TUN")
	}
	initialized = false

	if home == "" {
		return errors.New("mihomoInit: empty home dir")
	}
	if err := os.MkdirAll(home, 0o755); err != nil {
		return fmt.Errorf("mihomoInit: mkdir home: %w", err)
	}
	// The log relay survives coreStop. Switch its destination under the same lock
	// used by writeLogLine; no file descriptor is retained across writes.
	logFileMu.Lock()
	logRetryAfter = time.Time{}
	logSessionActive = true
	logNeedsMaintenance = true
	homeDir = home
	diagnosticKernelHome.Store(home)
	_, _ = getDiagnosticStore(home, "kernel")
	logFileMu.Unlock()
	constant.SetHomeDir(home)
	log.SetLevel(log.INFO)

	// 宿主只暴露受认证的安全重载和有限 PATCH，保留上游 embed 限制。
	route.SetEmbedMode(true)
	if err := initControllerSecurity(home); err != nil {
		return err
	}

	if logSub == nil { // 重复连接时幂等：只订阅一次，避免 relay goroutine 泄漏
		logSub = log.Subscribe() // 在 worker 线程首进 Go 后订阅，规避主线程 TLS 问题
		startLogRelay()
	}

	initialized = true
	log.Infoln("[OHOS] mihomo core initialized, home=%s", home)
	return nil
}

// startLogRelay - 把 mihomo 日志转发到 hilog（android_stub 的 __android_log_print
// 映射到 OH_LOG）并追加写入 homeDir/mihomo.log，供真机排障。落盘受两个约束：
//  1. logToFileEnabled=false（设置页可关）时只进 hilog、不写文件；
//  2. 超过 logFileMaxBytes 自动轮转为 mihomo.log.old，总量有界（≤2 份）。
func startLogRelay() {
	go func() {
		for e := range logSub {
			line := fmt.Sprintf("[%s] %s", e.LogLevel.String(), redactOrdinaryLog(e.Payload))
			hilogPrint(int(e.LogLevel), "mihomo", line)
			kernelDiagnosticLog(e.Type(), e.Payload)
			writeLogLine(line)
		}
	}()
}

func coreStartTun(fd int, configJson string, overridesJson string) (result error) {
	stage := "precondition"
	started := time.Now()
	defer func() {
		outcome := "success"
		if result != nil {
			outcome = "failed"
		}
		kernelDiagnostic(stage, outcome, result, map[string]any{"startupElapsedMs": time.Since(started).Milliseconds()})
	}()
	runLock.Lock()
	defer runLock.Unlock()

	if !initialized {
		return errors.New("mihomoStartTun: core not initialized, call mihomoInit first")
	}
	if tunListener != nil {
		return errors.New("mihomoStartTun: tun already running")
	}
	if fd <= 0 {
		return fmt.Errorf("mihomoStartTun: invalid tun fd %d", fd)
	}

	// 启动与 REST 热重载使用同一个最终约束与解析入口。
	stage = "config_parse"
	diagnosticRecordConfig(configJson, overridesJson)
	cfg, err := preparePlatformConfig(configJson, overridesJson)
	if err != nil {
		return err
	}
	kernelDiagnostic("config_parse", "success", nil, nil)
	ext := defaultTunExt() // 系统地址、MTU、DNS 劫持不能由订阅覆盖
	stage = "controller_listen"
	if err := startController(); err != nil {
		return err
	}
	kernelDiagnostic("controller_listen", "success", nil, nil)
	stage = "config_apply"
	executor.ApplyConfig(cfg, true)
	observeAIProbeConfig(configJson)
	applyLogOverride(overridesJson)
	activeOverrides = overridesJson
	kernelDiagnostic("config_apply", "completed", nil, nil)

	// 6. 用系统 tun fd 起 gVisor 入站
	opts := defaultTunOptions(fd, cfg.General.IPv6)
	stage = "tun_start"
	kernelDiagnostic("tun_start", "started", nil, nil)
	l, err := sing_tun.New(opts, tunnel.Tunnel)
	if err != nil {
		return fmt.Errorf("mihomoStartTun: start tun: %w", err)
	}
	tunListener = l
	enabled := cfg.General.IPv6
	tunIPv6Snapshot.Store(&enabled)
	stage = "core_ready"
	log.Infoln("[OHOS] TUN started fd=%d stack=%s address=%s mtu=%d hijack=%v", fd, opts.Stack.String(), ext.address, ext.mtu, ext.dnsHijack)
	return nil
}

// applyOverrides - 把 ArkTS 设置页的用户覆写（JSON）合并进 overlay。
// 合并顺序: profile overlay -> overrides -> 平台必需项，语义 = 用户覆写 > 订阅配置
// 同名键。键映射（ArkTS 驼峰 -> mihomo 配置 kebab）: mixedPort->mixed-port、
// logLevel->log-level、allowLan->allow-lan、mode->mode；IPv6 与系统 TUN 会话一致。logToFile 是 wrapper 专用开关（不属 mihomo 配置），单独消费。
// overridesJson 为空或解析失败时跳过该层（不影响启动）。
func applyOverrides(overlay map[string]any, overridesJson string) {
	// Neither a subscription nor REST reload can enable half a dual-stack tunnel.
	network := map[string]any{}
	_ = yaml.Unmarshal([]byte(overridesJson), &network)
	ipv6, _ := network["ipv6"].(bool)
	if snapshot := tunIPv6Snapshot.Load(); snapshot != nil {
		ipv6 = *snapshot
	}
	overlay["ipv6"] = ipv6
	if dns, ok := overlay["dns"].(map[string]any); ok {
		dns["ipv6"] = ipv6
	}

	// LAN exposure requires the host setting; subscription values are not consent.
	overlay["allow-lan"] = false
	if overridesJson == "" {
		log.Infoln("[OHOS] overrides: empty, skipped")
		return
	}
	ov := map[string]any{}
	if err := yaml.Unmarshal([]byte(overridesJson), &ov); err != nil {
		log.Warnln("[OHOS] overrides: invalid input, skipped")
		return
	}
	keyMap := map[string]string{
		"mixedPort": "mixed-port",
		"logLevel":  "log-level",
		"allowLan":  "allow-lan",
		"mode":      "mode",
	}
	for src, dst := range keyMap {
		v, ok := ov[src]
		if !ok {
			continue
		}
		if src == "allowLan" {
			if enabled, valid := v.(bool); valid {
				overlay[dst] = enabled
			}
			continue
		}
		// 用户未显式选择模式（空串）时跳过，保留订阅配置自带的 mode
		if dst == "mode" {
			if s, isStr := v.(string); !isStr || s == "" {
				continue
			}
		}
		overlay[dst] = v
	}
	log.Infoln("[OHOS] supported user overrides applied")
}

// Commit wrapper-only settings after configuration validation and application.
// Preparing a rejected candidate must not change the active logging policy.
func applyLogOverride(overridesJson string) {
	ov := map[string]any{}
	if yaml.Unmarshal([]byte(overridesJson), &ov) == nil {
		if enabled, ok := ov["logToFile"].(bool); ok {
			setLogToFile(enabled)
		}
	}
}

func coreStop() {
	kernelDiagnostic("core_stop", "started", nil, nil)
	runLock.Lock()
	defer runLock.Unlock()

	if tunListener != nil {
		_ = tunListener.Close()
		tunListener = nil
	}
	// 声明式 generic inbound 与固定顶层端口是不同的 listener 集合。
	listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
	listener.PatchTunnel(nil, tunnel.Tunnel)
	listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
	// 端口置 0 关闭固定顶层监听；Cleanup 本身只处理自动 TUN。
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	MDNS.ReCreateServer("", nil, nil)
	stopController()
	activeOverrides = ""
	tunIPv6Snapshot.Store(nil)
	kernelDiagnostic("core_stop", "completed", nil, nil)
	log.Infoln("[OHOS] mihomo core stopped")
	// Quiesce only the ordinary file sink; the relay/hilog and diagnostic store
	// survive stop. Queued events must not recreate files in an ended session.
	logFileMu.Lock()
	logSessionActive = false
	logFileMu.Unlock()
}

// parseTunPrefix - 兼容 "172.19.0.1/30" 与裸地址 "172.19.0.1"（ohos 补 /30，参照 FlClash）
func parseTunPrefix(s string) (netip.Prefix, error) {
	s = strings.TrimSpace(s)
	if !strings.Contains(s, "/") {
		addr, err := netip.ParseAddr(s)
		if err != nil {
			return netip.Prefix{}, err
		}
		if addr.Is6() {
			return netip.PrefixFrom(addr, 126), nil
		}
		return netip.PrefixFrom(addr, 30), nil
	}
	p, err := netip.ParsePrefix(s)
	if err != nil {
		return netip.Prefix{}, err
	}
	return p, nil
}
