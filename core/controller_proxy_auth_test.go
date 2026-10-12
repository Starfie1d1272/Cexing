package main

import (
	"sync"
	"testing"

	"github.com/metacubex/mihomo/component/auth"
	authStore "github.com/metacubex/mihomo/listener/auth"
)

func TestProxyAuthSnapshotConcurrentReplacement(t *testing.T) {
	store := authStore.Default
	original := store.Authenticator()
	defer store.SetAuthenticator(original)
	valid := auth.NewAuthenticator([]auth.AuthUser{{User: "synthetic", Pass: "one"}})
	store.SetAuthenticator(valid)
	retained := store.Authenticator()
	store.SetAuthenticator(nil)
	if retained == nil || !retained.Verify("synthetic", "one") || retained.Verify("synthetic", "wrong") || store.Authenticator() != nil {
		t.Fatal("auth snapshot semantics changed")
	}
	var group sync.WaitGroup
	group.Add(2)
	go func() {
		defer group.Done()
		for i := 0; i < 1000; i++ {
			store.SetAuthenticator(valid)
			store.SetAuthenticator(nil)
		}
	}()
	go func() {
		defer group.Done()
		for i := 0; i < 1000; i++ {
			if snapshot := store.Authenticator(); snapshot != nil {
				snapshot.Verify("synthetic", "one")
				snapshot.Users()
			}
		}
	}()
	group.Wait()
	if authStore.Default != store {
		t.Fatal("default store identity changed after initialization")
	}
}
