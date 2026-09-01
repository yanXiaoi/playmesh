package webrtctunnel

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"
)

func TestHostSnapshotIncludesZeroConnectionCount(t *testing.T) {
	session := &HostSession{
		id:        "host-session",
		status:    "connected",
		joinURL:   &url.URL{Scheme: "https", Host: "relay.example", Path: "/j/tunnel"},
		expiresAt: time.Now().Add(time.Minute),
	}

	payload, err := json.Marshal(session.snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	connectionCount, exists := decoded["connectionCount"]
	if !exists || connectionCount != float64(0) {
		t.Fatalf("connectionCount = %#v, exists = %v; want 0", connectionCount, exists)
	}
}

func TestControlHandlerDoesNotExposeICERestart(t *testing.T) {
	service := NewService()
	defer service.Close()
	handler := NewHandler(
		service,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	request := httptest.NewRequest(
		http.MethodPost,
		"http://127.0.0.1/v1/relay/client/client-id/ice-restart",
		nil,
	)
	request.Header.Set("X-Playmesh-Control-Version", controlProtocolVersion)
	request.Header.Set("X-Playmesh-Request-ID", "manual-reconnect-only")
	request.Header.Set("X-Playmesh-Timestamp", strconv.FormatInt(time.Now().UnixMilli(), 10))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("ICE restart status = %d, want %d", response.Code, http.StatusNotFound)
	}
	var payload map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["error"] != "not_found" {
		t.Fatalf("ICE restart error = %#v", payload["error"])
	}
}
