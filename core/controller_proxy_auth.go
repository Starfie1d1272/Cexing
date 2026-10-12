package main

import (
	"sync"

	"github.com/metacubex/mihomo/component/auth"
	authStore "github.com/metacubex/mihomo/listener/auth"
)

// This is proxy authentication, not the Controller Secret. Install once before
// listeners are created; never replace the exported Default during start/reload.
// Both the executor's setters and HTTP/SOCKS/mixed readers retain this identity.
func init() {
	authStore.Default = &synchronizedProxyAuthStore{store: authStore.Default}
}

type synchronizedProxyAuthStore struct {
	mu    sync.RWMutex
	store auth.AuthStore
}

func (s *synchronizedProxyAuthStore) Authenticator() auth.Authenticator {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.store.Authenticator()
}
func (s *synchronizedProxyAuthStore) SetAuthenticator(value auth.Authenticator) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store.SetAuthenticator(value)
}
