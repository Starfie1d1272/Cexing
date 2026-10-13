package main

import (
	"context"
	"github.com/metacubex/mihomo/component/resolver"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
	"github.com/miekg/dns"
)

func TestHostNetworkDefaults(t *testing.T) {
	if err := coreInit(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	for _, overrides := range []string{"", `{}`, `{broken`, `{"allowLan":"true"}`, `{"allowLan":false}`} {
		cfg, err := preparePlatformConfig(`mixed-port: 0
allow-lan: true
dns: {enable: true, listen: '0.0.0.0:1053', nameserver: [1.1.1.1]}
rules: ['MATCH,DIRECT']`, overrides)
		if err != nil {
			t.Fatal(err)
		}
		if cfg.General.AllowLan {
			t.Fatalf("subscription enabled LAN for %q", overrides)
		}
		if cfg.DNS.Listen != defaultDNSListen {
			t.Fatalf("unsafe DNS listener: %s", cfg.DNS.Listen)
		}
	}
	cfg, err := preparePlatformConfig(`mixed-port: 0
allow-lan: false
dns: {enable: true, listen: '[::]:1053', nameserver: [1.1.1.1]}
hosts: {network-default.test: 192.0.2.1}
rules: ['MATCH,DIRECT']`, `{"allowLan":true}`)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.General.AllowLan || cfg.DNS.Listen != defaultDNSListen {
		t.Fatal("LAN consent changed independent DNS policy")
	}
	executor.ApplyConfig(cfg, true)
	// Real production DNS server, synthetic hosts, no external resolver request.
	for _, network := range []string{"udp", "tcp"} {
		query := new(dns.Msg)
		query.SetQuestion("network-default.test.", dns.TypeA)
		answer, _, err := (&dns.Client{Net: network}).Exchange(query, defaultDNSListen)
		if err != nil || answer == nil || answer.Id != query.Id || len(answer.Answer) != 1 {
			t.Fatalf("%s DNS: answer=%v err=%v", network, answer, err)
		}
	}
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		t.Fatal(err)
	}
	for _, address := range addresses {
		ip, ok := address.(*net.IPNet)
		if !ok || ip.IP.IsLoopback() || ip.IP.To4() == nil {
			continue
		}
		for _, network := range []string{"tcp", "udp"} {
			query := new(dns.Msg)
			query.SetQuestion("network-default.test.", dns.TypeA)
			if _, _, err := (&dns.Client{Net: network, Timeout: 200 * time.Millisecond}).Exchange(query, net.JoinHostPort(ip.IP.String(), "1053")); err == nil {
				t.Fatalf("%s DNS reachable at nonloopback address %s", network, ip.IP)
			}
		}
		break
	}
	// These are the same in-process relay functions called by sing_tun for
	// hijacked UDP packets and TCP streams; they do not dial dns.listen.
	query := new(dns.Msg)
	query.SetQuestion("network-default.test.", dns.TypeA)
	packed, _ := query.Pack()
	packet, err := resolver.RelayDnsPacket(context.Background(), packed, make([]byte, 65535))
	if err != nil {
		t.Fatal(err)
	}
	answer := new(dns.Msg)
	if err := answer.Unpack(packet); err != nil || len(answer.Answer) != 1 {
		t.Fatalf("TUN UDP relay: %v %v", answer, err)
	}
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- resolver.RelayDnsConn(context.Background(), server, time.Second); server.Close() }()
	client.SetDeadline(time.Now().Add(time.Second))
	conn := &dns.Conn{Conn: client}
	if err := conn.WriteMsg(query); err != nil {
		t.Fatal(err)
	}
	answer, err = conn.ReadMsg()
	client.Close()
	<-done
	if err != nil || answer == nil || len(answer.Answer) != 1 {
		t.Fatalf("TUN TCP relay: %v %v", answer, err)
	}
	ext := defaultTunExt()
	if ext.stack != "gvisor" || len(ext.dnsHijack) != 1 || ext.dnsHijack[0] != "0.0.0.0:53" {
		t.Fatal("TUN DNS interception changed")
	}
}
