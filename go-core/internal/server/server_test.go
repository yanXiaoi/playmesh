package server

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"
)

func TestServerStartsServesAndStops(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	coreServer := New(
		"127.0.0.1:0",
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNoContent)
		}),
		logger,
	)

	if err := coreServer.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if coreServer.Address() == "" {
		t.Fatal("Address() should be available after start")
	}
	if err := coreServer.Start(); err == nil {
		t.Fatal("second Start() should fail")
	}

	client := &http.Client{Timeout: time.Second}
	response, err := client.Get("http://" + coreServer.Address())
	if err != nil {
		t.Fatalf("GET running server: %v", err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusNoContent)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := coreServer.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("Shutdown() error = %v", err)
	}

	select {
	case err := <-coreServer.Errors():
		if err != nil {
			t.Fatalf("Serve() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not stop")
	}

	if _, err := client.Get("http://" + coreServer.Address()); err == nil {
		t.Fatal("request after shutdown should fail")
	}
}
