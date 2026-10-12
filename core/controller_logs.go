package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	HTTP "net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	MHTTP "github.com/metacubex/http"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
)

type controllerResourcesKey struct{}
type controllerResources struct {
	cancel  context.CancelFunc
	mu      sync.Mutex
	closing bool
	logs    sync.WaitGroup
}

func (s *controllerResources) beginLog() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return false
	}
	s.logs.Add(1)
	return true
}
func (s *controllerResources) fence() {
	s.mu.Lock()
	s.closing = true
	s.mu.Unlock()
}

// Bridge only the standard HTTP types required by the already locked WS
// library. The server and Hijack still use the one owned Mihomo HTTP listener.
type controllerWSWriter struct{ MHTTP.ResponseWriter }

func (w controllerWSWriter) Header() HTTP.Header { return HTTP.Header(w.ResponseWriter.Header()) }
func (w controllerWSWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return MHTTP.NewResponseController(w.ResponseWriter).Hijack()
}

// Owned cancellation boundary for /logs. The upstream handler blocks forever
// on its event channel when a disconnected peer selects level=silent.
func getControllerLogs(w MHTTP.ResponseWriter, req *MHTTP.Request) {
	resources, ok := req.Context().Value(controllerResourcesKey{}).(*controllerResources)
	if !ok || !resources.beginLog() {
		controllerError(w, 409, "controller session ended")
		return
	}
	defer resources.logs.Done() // runs after unsubscribe, relay and reader cleanup
	levelText := req.URL.Query().Get("level")
	if levelText == "" {
		levelText = "info"
	}
	level, ok := log.LogLevelMapping[levelText]
	if !ok {
		controllerError(w, 400, "invalid log level")
		return
	}
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	var conn *websocket.Conn
	peerDone := make(chan struct{})
	if req.Header.Get("Upgrade") == "websocket" {
		standard := (&HTTP.Request{Method: req.Method, URL: req.URL, Host: req.Host, Header: HTTP.Header(req.Header),
			Proto: req.Proto, ProtoMajor: req.ProtoMajor, ProtoMinor: req.ProtoMinor, RemoteAddr: req.RemoteAddr, Body: req.Body}).WithContext(ctx)
		var err error
		conn, err = websocket.Accept(controllerWSWriter{w}, standard, nil)
		if err != nil {
			return
		}
		conn.SetReadLimit(4096)
		go func() {
			defer close(peerDone)
			for {
				if _, _, err := conn.Read(ctx); err != nil {
					return
				}
			}
		}()
		defer func() { cancel(); conn.CloseNow(); <-peerDone }()
	} else {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		_ = MHTTP.NewResponseController(w).Flush()
	}
	sub := log.Subscribe()
	events := make(chan log.Event, 1024)
	relayDone := make(chan struct{})
	go func() {
		defer close(relayDone)
		for event := range sub {
			select {
			case events <- event:
			default:
			}
		}
	}()
	// Keep draining the observable until UnSubscribe completes: its emitter holds
	// a mutex and can block on a full subscriber buffer. Then join this relay.
	defer func() { log.UnSubscribe(sub); <-relayDone }()
	for {
		select {
		case <-ctx.Done():
			return
		case <-peerDone:
			return
		case event := <-events:
			if event.LogLevel < level {
				continue
			}
			payload := redactControllerSecret(event.Payload)
			var value any = route.Log{Type: event.Type(), Payload: payload}
			if req.URL.Query().Get("format") == "structured" {
				name := event.Type()
				if name == "warning" {
					name = "warn"
				}
				value = route.LogStructured{Time: time.Now().Format(time.TimeOnly), Level: name, Message: payload, Fields: []route.LogStructuredField{}}
			}
			data, err := json.Marshal(value)
			if err != nil {
				return
			}
			data = append(data, '\n')
			if conn != nil {
				if conn.Write(ctx, websocket.MessageText, data) != nil {
					return
				}
			} else {
				if _, err := w.Write(data); err != nil {
					return
				}
				if MHTTP.NewResponseController(w).Flush() != nil {
					return
				}
			}
		}
	}
}
