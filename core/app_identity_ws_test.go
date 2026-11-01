package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestAppIdentityWebSocketHandshake(t *testing.T) {
	if err := coreInit(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	defer coreStop()
	if err := startController(); err != nil {
		t.Fatal(err)
	}
	s := startAppTraffic()
	client := &http.Client{Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	for _, origin := range []string{"", "http://" + defaultController, "http://127.0.0.1", "http://localhost", "https://foreign.invalid"} {
		t.Run(origin, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			headers := http.Header{"Authorization": []string{"Bearer " + controllerSecret}}
			if origin != "" {
				headers.Set("Origin", origin)
			}
			conn, response, err := websocket.Dial(ctx, "ws://"+defaultController+"/ohos/app-traffic/identity", &websocket.DialOptions{HTTPClient: client, HTTPHeader: headers})
			if origin != "" && origin != "http://"+defaultController {
				if err == nil {
					conn.CloseNow()
					t.Fatal("foreign origin accepted")
				}
				if response == nil || response.StatusCode != 403 {
					t.Fatalf("foreign origin status: %v", response)
				}
				return
			}
			if err != nil {
				status := 0
				if response != nil {
					status = response.StatusCode
				}
				t.Fatalf("handshake failed, status %d: %v", status, err)
			}
			defer conn.CloseNow()
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var batch appIdentityBatch
			if json.Unmarshal(data, &batch) != nil || batch.Session != s.id {
				t.Fatal("invalid session heartbeat")
			}
			conn.CloseNow()
			deadline := time.Now().Add(time.Second)
			for time.Now().Before(deadline) {
				s.mu.Lock()
				busy := s.consumer
				s.mu.Unlock()
				if !busy {
					return
				}
				time.Sleep(time.Millisecond)
			}
			t.Fatal("disconnected identity consumer retained slot")
		})
	}
	t.Run("upstream-traffic-legacy-origin", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		conn, response, err := websocket.Dial(ctx, "ws://"+defaultController+"/traffic", &websocket.DialOptions{HTTPClient: client, HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + controllerSecret}, "Origin": []string{"http://127.0.0.1"},
		}})
		if err != nil {
			status := 0
			if response != nil {
				status = response.StatusCode
			}
			t.Fatalf("upstream handshake failed, status %d: %v", status, err)
		}
		conn.CloseNow()
	})

}
