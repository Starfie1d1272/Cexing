package main

import (
	"errors"
	"runtime"
	"sync"
	"weak"

	A "github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
)

// Weak keys identify object lifetimes, not reusable heap addresses. The cache
// must neither mistake a later provider object for an old node nor keep retired
// proxy adapters alive. Callers receive only a process-private opaque number.
type aiProxyIdentityStore struct {
	mu    sync.Mutex
	ids   map[weak.Pointer[A.Proxy]]uint64
	next  uint64
	limit int
}

var aiProxyIdentities = aiProxyIdentityStore{limit: 8192}

func (s *aiProxyIdentityStore) identity(value C.Proxy) (uint64, error) {
	proxy, ok := value.(*A.Proxy)
	if !ok || proxy == nil {
		return 0, errors.New("PROBE_ROUTE_UNPROVEN")
	}
	defer runtime.KeepAlive(proxy)
	key := weak.Make(proxy)
	s.mu.Lock()
	defer s.mu.Unlock()
	if id, ok := s.ids[key]; ok {
		return id, nil
	}
	limit := s.limit
	if limit <= 0 {
		limit = 8192
	}
	if len(s.ids) >= limit {
		for key := range s.ids {
			if key.Value() == nil {
				delete(s.ids, key)
			}
		}
	}
	if len(s.ids) >= limit {
		return 0, errors.New("PROBE_ROUTE_LIMIT")
	}
	if s.ids == nil {
		s.ids = map[weak.Pointer[A.Proxy]]uint64{}
	}
	s.next++
	if s.next == 0 {
		return 0, errors.New("PROBE_ROUTE_LIMIT")
	}
	s.ids[key] = s.next
	return s.next, nil
}
