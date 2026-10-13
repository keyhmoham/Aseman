package network_test

import (
	"context"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/logger"
	httpadapter "github.com/tradera/tradera/plugins/adapters/network/http"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/network/tcp"
	wsadapter "github.com/tradera/tradera/plugins/adapters/network/websocket"
)

func TestProtocolStopDrainsActiveConnections(t *testing.T) {
	for _, kind := range []string{"http", "tcp", "websocket"} {
		t.Run(kind, func(t *testing.T) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			addr := ln.Addr().String()
			_ = ln.Close()
			var p interface {
				api.Plugin
				network.Network
			}
			switch kind {
			case "http":
				p = httpadapter.New(logger.Global())
			case "tcp":
				p = tcp.New(logger.Global())
			case "websocket":
				p = wsadapter.New(logger.Global())
			}
			if err := p.Init(context.Background(), &api.Dependencies{Config: map[string]any{"addr": addr}, Logger: logger.Global()}); err != nil {
				t.Fatal(err)
			}
			entered := make(chan struct{})
			var once sync.Once
			if err := p.Handle(network.MethodGet, "/work", func(ctx context.Context, _ *network.Request) (*network.Response, error) {
				once.Do(func() { close(entered) })
				<-ctx.Done()
				return &network.Response{Status: 200}, nil
			}); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- p.Serve(ctx) }()
			deadline := time.Now().Add(3 * time.Second)
			for {
				conn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
				if err == nil {
					_ = conn.Close()
					break
				}
				if time.Now().After(deadline) {
					t.Fatal(err)
				}
				time.Sleep(5 * time.Millisecond)
			}
			var closeClient func()
			if kind == "websocket" {
				conn, _, err := websocket.DefaultDialer.Dial("ws://"+addr+"/ws", nil)
				if err != nil {
					t.Fatal(err)
				}
				closeClient = func() { _ = conn.Close() }
			} else if kind == "tcp" {
				conn, err := net.Dial("tcp", addr)
				if err != nil {
					t.Fatal(err)
				}
				closeClient = func() { _ = conn.Close() }
			} else {
				requestDone := make(chan struct{})
				go func() {
					defer close(requestDone)
					resp, err := (&http.Client{Timeout: 3 * time.Second}).Get("http://" + addr + "/work")
					if err == nil {
						_, _ = io.Copy(io.Discard, resp.Body)
						_ = resp.Body.Close()
					}
				}()
				select {
				case <-entered:
				case <-time.After(time.Second):
					t.Fatal("handler did not start")
				}
				closeClient = func() {
					select {
					case <-requestDone:
					case <-time.After(time.Second):
						t.Error("HTTP request did not drain")
					}
				}
			}
			defer closeClient()
			stopCtx, finish := context.WithTimeout(context.Background(), time.Second)
			defer finish()
			if err := p.Stop(stopCtx); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("listener did not stop")
			}
		})
	}
}
