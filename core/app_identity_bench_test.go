package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	C "github.com/metacubex/mihomo/constant"
)

// Measures the local authenticated bridge with synthetic immediate UID replies, not the platform API or UDP forwarding.
func BenchmarkAppIdentityRoundTrip(b *testing.B) {
	if err := coreInit(b.TempDir()); err != nil {
		b.Fatal(err)
	}
	defer coreStop()
	if err := startController(); err != nil {
		b.Fatal(err)
	}
	s := startAppTraffic()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	conn, _, err := websocket.Dial(ctx, "ws://"+defaultController+"/ohos/app-traffic/identity", &websocket.DialOptions{HTTPClient: client, HTTPHeader: http.Header{"Authorization": []string{"Bearer " + controllerSecret}}})
	if err != nil {
		b.Fatal(err)
	}
	defer conn.CloseNow()
	pumpDone := make(chan struct{})
	var pumpError atomic.Pointer[error]
	go func() {
		defer close(pumpDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var batch appIdentityBatch
			if err = json.Unmarshal(data, &batch); err != nil {
				pumpError.Store(&err)
				return
			}
			if len(batch.Requests) == 0 {
				continue
			}
			replies := make([]appIdentityReply, 0, len(batch.Requests))
			for _, request := range batch.Requests {
				replies = append(replies, appIdentityReply{ID: request.ID, UID: 10001, Status: "uid"})
			}
			body, _ := json.Marshal(map[string]any{"session": batch.Session, "replies": replies})
			req, _ := http.NewRequestWithContext(ctx, "POST", "http://"+defaultController+"/ohos/app-traffic/identity", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+controllerSecret)
			response, err := client.Do(req)
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				pumpError.Store(&err)
				return
			}
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			if response.StatusCode != 204 {
				err = fmt.Errorf("reply status %d", response.StatusCode)
				pumpError.Store(&err)
				return
			}
		}
	}()
	var next, failed atomic.Int64
	var workers sync.WaitGroup
	b.ResetTimer()
	started := time.Now()
	for i := 0; i < 128; i++ {
		workers.Go(func() {
			for {
				if next.Add(1) > int64(b.N) {
					return
				}
				metadata := routeTestMetadata(s, C.UDP)
				_, err := appUDPKey(metadata)
				resolved, _ := metadata.TrackerContext.(*appRouteContext)
				if err != nil || resolved == nil || resolved.uid != 10001 {
					failed.Add(1)
				}
			}
		})
	}
	workers.Wait()
	elapsed := time.Since(started)
	b.StopTimer()
	cancel()
	conn.CloseNow()
	<-pumpDone
	if failure := pumpError.Load(); failure != nil {
		b.Fatal(*failure)
	}
	if failed.Load() != 0 {
		b.Fatalf("%d unresolved identities", failed.Load())
	}
	b.ReportMetric(float64(b.N)/elapsed.Seconds(), "queries/s")
}
