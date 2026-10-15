package main

import (
	A "github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"runtime"
	"testing"
)

func TestAIProxyLifetimeIdentityIsStableBoundedAndNotNameBased(t *testing.T) {
	store := aiProxyIdentityStore{limit: 2}
	first := A.NewProxy(outbound.NewDirect())
	sameName := A.NewProxy(outbound.NewDirect())
	third := A.NewProxy(outbound.NewDirect())
	a, err := store.identity(first)
	if err != nil {
		t.Fatal(err)
	}
	b, err := store.identity(first)
	if err != nil || a != b {
		t.Fatal("live identity changed", err)
	}
	c, err := store.identity(sameName)
	if err != nil || c == a {
		t.Fatal("same-name objects shared an identity", err)
	}
	if _, err := store.identity(third); err == nil {
		t.Fatal("live registry bound bypassed")
	}
	if id, err := store.identity(first); err != nil || id != a {
		t.Fatal("capacity evicted a live identity", err)
	}
	runtime.KeepAlive(first)
	runtime.KeepAlive(sameName)
}
