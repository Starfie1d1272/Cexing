package main

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"
	_ "unsafe" // required for the locked Mihomo router binding below

	"github.com/metacubex/chi"
	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
)

// The locked v1.19.32 router has no exported constructor. Bind only its exact
// factory signature so the host can own listener shutdown without copying API
// handlers, patching module cache, changing dependencies or starting a second
// server. An upgrade must recheck this private Go contract and build/test it.
//
//go:linkname newMihomoControllerRouter github.com/metacubex/mihomo/hub/route.router
func newMihomoControllerRouter(bool, string, string, route.Cors) *chi.Mux

var (
	controllerLifecycleMu sync.Mutex
	controllerServer      *MHTTP.Server
	controllerSocket      *controllerTrackedListener
	controllerServeDone   chan struct{}
	controllerEpoch       atomic.Uint64
	controllerRunning     atomic.Bool
)

type controllerTrackedListener struct {
	net.Listener
	mu          sync.Mutex
	closed      bool
	connections map[*controllerTrackedConn]struct{}
}
type controllerTrackedConn struct {
	net.Conn
	owner *controllerTrackedListener
}

func (l *controllerTrackedListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	tracked := &controllerTrackedConn{Conn: conn, owner: l}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		conn.Close()
		return nil, net.ErrClosed
	}
	l.connections[tracked] = struct{}{}
	return tracked, nil
}
func (c *controllerTrackedConn) Close() error {
	err := c.Conn.Close()
	c.owner.mu.Lock()
	delete(c.owner.connections, c)
	c.owner.mu.Unlock()
	return err
}
func (l *controllerTrackedListener) Close() error {
	l.mu.Lock()
	l.closed = true
	l.mu.Unlock()
	return l.Listener.Close()
}
func (l *controllerTrackedListener) closeConnections() {
	l.mu.Lock()
	conns := make([]*controllerTrackedConn, 0, len(l.connections))
	for conn := range l.connections {
		conns = append(conns, conn)
	}
	l.mu.Unlock()
	for _, conn := range conns {
		// A hard session stop must not leave a TCP half-close where a peer can
		// still buffer WS writes after observing EOF. Reset owned TCP sockets.
		if tcp, ok := conn.Conn.(*net.TCPConn); ok {
			_ = tcp.SetLinger(0)
		}
		_ = conn.Close()
	}
}

// Call while lifecycle mutex is held. Close covers HTTP; tracked connections
// also cover upgraded/hijacked WS, which Server.Close explicitly leaves open.
func stopControllerLocked() {
	controllerRunning.Store(false)
	controllerEpoch.Add(1)
	if controllerServer == nil {
		return
	}
	_ = controllerServer.Close()
	controllerSocket.closeConnections()
	<-controllerServeDone // listener's Serve loop exited: no late start/accept
	controllerServer = nil
	controllerSocket = nil
	controllerServeDone = nil
}
func stopController() {
	controllerLifecycleMu.Lock()
	defer controllerLifecycleMu.Unlock()
	stopControllerLocked()
}
func serveController() error {
	controllerLifecycleMu.Lock()
	defer controllerLifecycleMu.Unlock()
	stopControllerLocked()
	socket, err := net.Listen("tcp4", defaultController)
	if err != nil {
		return errors.New("controller: authenticated listener unavailable")
	}
	tracked := &controllerTrackedListener{Listener: socket, connections: make(map[*controllerTrackedConn]struct{})}
	router := newMihomoControllerRouter(false, controllerSecret, "", route.Cors{AllowOrigins: []string{"http://" + defaultController}})
	epoch := controllerEpoch.Add(1)
	server := &MHTTP.Server{ReadHeaderTimeout: 8 * time.Second, Handler: MHTTP.HandlerFunc(func(w MHTTP.ResponseWriter, req *MHTTP.Request) {
		if epoch != controllerEpoch.Load() {
			controllerError(w, 409, "controller session ended")
			return
		}
		router.ServeHTTP(w, req)
	})}
	done := make(chan struct{})
	controllerServer = server
	controllerSocket = tracked
	controllerServeDone = done
	controllerRunning.Store(true)
	go func() {
		defer close(done)
		if err := server.Serve(tracked); err != nil && !errors.Is(err, MHTTP.ErrServerClosed) {
			if epoch == controllerEpoch.Load() {
				controllerRunning.Store(false)
			}
			log.Errorln("[OHOS] Controller listener ended unexpectedly")
		}
	}()
	return nil
}
