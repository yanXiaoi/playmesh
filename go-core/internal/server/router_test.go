package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestGameSDKCORSAndPrivateNetworkPreflight(t *testing.T) {
	calls := 0
	handler := http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		calls++
		writer.WriteHeader(http.StatusOK)
	})
	router := NewRouter(handler, handler)
	request := httptest.NewRequest(http.MethodOptions, "/v1/sessions/join", nil)
	request.Header.Set("Origin", "http://127.0.0.1:4567")
	request.Header.Set("Access-Control-Request-Private-Network", "true")
	response := httptest.NewRecorder()

	router.ServeHTTP(response, request)

	if response.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d, want %d", response.Code, http.StatusNoContent)
	}
	if calls != 0 {
		t.Fatalf("preflight reached session handler %d times", calls)
	}
	if value := response.Header().Get("Access-Control-Allow-Origin"); value != "*" {
		t.Fatalf("Access-Control-Allow-Origin = %q", value)
	}
	if value := response.Header().Get("Access-Control-Allow-Private-Network"); value != "true" {
		t.Fatalf("Access-Control-Allow-Private-Network = %q", value)
	}
	if value := response.Header().Get("Access-Control-Allow-Methods"); value != "GET, POST, PATCH, DELETE, OPTIONS" {
		t.Fatalf("Access-Control-Allow-Methods = %q", value)
	}
}
