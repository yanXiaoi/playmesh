package health

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

type stubChecker struct {
	snapshot Snapshot
	err      error
}

func (s stubChecker) Check(context.Context) (Snapshot, error) {
	return s.snapshot, s.err
}

func TestHandlerReturnsHealthAndEchoesRequestID(t *testing.T) {
	handler := newTestHandler(stubChecker{snapshot: Snapshot{
		Status:      OnlineStatus,
		CoreVersion: "0.1.0",
		StartedAt:   1234,
	}})
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	request.Header.Set("X-Request-ID", "req-handler-1")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if response.Header().Get("X-Request-ID") != "req-handler-1" {
		t.Fatalf("X-Request-ID = %q", response.Header().Get("X-Request-ID"))
	}

	var payload responseEnvelope
	decodeResponse(t, response, &payload)
	if payload.Type != "core.health" {
		t.Fatalf("type = %q, want core.health", payload.Type)
	}
	if payload.ProtocolVersion != protocolVersion {
		t.Fatalf("protocolVersion = %q, want %q", payload.ProtocolVersion, protocolVersion)
	}
	if payload.RequestID != "req-handler-1" {
		t.Fatalf("requestId = %q, want req-handler-1", payload.RequestID)
	}
	if payload.Data == nil || payload.Data.Status != OnlineStatus {
		t.Fatalf("data = %#v, want online snapshot", payload.Data)
	}
}

func TestHandlerReturnsStructuredServiceError(t *testing.T) {
	handler := newTestHandler(stubChecker{err: errors.New("dependency failed")})
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	request.Header.Set("X-Request-ID", "req-handler-error")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusServiceUnavailable)
	}

	var payload responseEnvelope
	decodeResponse(t, response, &payload)
	if payload.Type != "core.error" {
		t.Fatalf("type = %q, want core.error", payload.Type)
	}
	if payload.Error == nil || payload.Error.Code != "health_unavailable" {
		t.Fatalf("error = %#v, want health_unavailable", payload.Error)
	}
	if payload.RequestID != "req-handler-error" {
		t.Fatalf("requestId = %q, want req-handler-error", payload.RequestID)
	}
}

func TestHandlerRejectsUnsupportedMethod(t *testing.T) {
	handler := newTestHandler(stubChecker{})
	request := httptest.NewRequest(http.MethodPost, "/health", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusMethodNotAllowed)
	}

	var payload responseEnvelope
	decodeResponse(t, response, &payload)
	if payload.Error == nil || payload.Error.Code != "method_not_allowed" {
		t.Fatalf("error = %#v, want method_not_allowed", payload.Error)
	}
	if payload.RequestID == "" {
		t.Fatal("requestId should be generated")
	}
}

func TestHandlerReplacesUnsafeRequestID(t *testing.T) {
	handler := newTestHandler(stubChecker{snapshot: Snapshot{Status: OnlineStatus}})
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	request.Header.Set("X-Request-ID", "unsafe request id")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	requestID := response.Header().Get("X-Request-ID")
	if requestID == "" || requestID == "unsafe request id" {
		t.Fatalf("X-Request-ID = %q, want generated safe ID", requestID)
	}
}

func newTestHandler(checker Checker) *Handler {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return NewHandler(checker, logger)
}

func decodeResponse(t *testing.T, response *httptest.ResponseRecorder, target any) {
	t.Helper()
	if err := json.Unmarshal(response.Body.Bytes(), target); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}
