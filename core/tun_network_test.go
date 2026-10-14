package main

import (
	"github.com/metacubex/mihomo/constant"
	"gopkg.in/yaml.v3"
	"net/netip"
	"testing"
)

func TestSystemTunNetworkContract(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		opts := defaultTunOptions(37, enabled)
		if opts.MTU != 9000 || opts.FileDescriptor != 37 || opts.AutoRoute || opts.AutoDetectInterface || opts.Stack != constant.TunGvisor {
			t.Fatal("system-fd ownership, matching MTU or gVisor changed")
		}
		if len(opts.Inet4Address) != 1 || opts.Inet4Address[0] != netip.MustParsePrefix("172.19.0.1/30") {
			t.Fatal("IPv4 regression")
		}
		if enabled {
			if len(opts.Inet6Address) != 1 || opts.Inet6Address[0] != netip.MustParsePrefix("fdfe:dcba:9876::1/126") || opts.DNSHijack[1] != "[::]:53" {
				t.Fatal("incomplete dual stack")
			}
		} else if len(opts.Inet6Address) != 0 || len(opts.DNSHijack) != 1 {
			t.Fatal("IPv6 survives disabled mode")
		}
		if err := coreInit(t.TempDir()); err != nil {
			t.Fatal(err)
		}
		overrides := `{"mixedPort":0,"ipv6":false}`
		if enabled {
			overrides = `{"mixedPort":0,"ipv6":true}`
		}
		cfg, err := preparePlatformConfig("ipv6: true\ndns: {enable: true, ipv6: false, nameserver: [1.1.1.1]}\nrules: ['MATCH,DIRECT']", overrides)
		if err != nil {
			t.Fatal(err)
		}
		if cfg.General.IPv6 != enabled || cfg.DNS.IPv6 != enabled {
			t.Fatal("host, DNS and core disagree")
		}
		coreStop()
	}
	// Offline previews and REST reload both preserve the established system TUN.
	enabled := true
	tunIPv6Snapshot.Store(&enabled)
	defer tunIPv6Snapshot.Store(nil)
	overlay := map[string]any{}
	if err := yaml.Unmarshal([]byte("ipv6: false\ndns: {ipv6: false}"), &overlay); err != nil {
		t.Fatal(err)
	}
	applyOverrides(overlay, `{"ipv6":false}`)
	if overlay["ipv6"] != true || overlay["dns"].(map[string]any)["ipv6"] != true {
		t.Fatal("reload changed system network snapshot")
	}
}
