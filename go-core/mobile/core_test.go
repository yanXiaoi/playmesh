package mobile

import (
	"encoding/json"
	"net"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func TestMobileCoreStartsReportsAndStops(t *testing.T) {
	address, err := Start("")
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if address == "" || Address() != address || !IsRunning() {
		t.Fatalf("running state is inconsistent: address=%q current=%q", address, Address())
	}
	_, portText, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("SplitHostPort(%q): %v", address, err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port == 0 {
		t.Fatalf("Start() should report a dynamic non-zero port, address=%q", address)
	}

	client := &http.Client{Timeout: time.Second}
	request, err := http.NewRequest(http.MethodGet, "http://"+address+"/health", nil)
	if err != nil {
		t.Fatalf("NewRequest() error = %v", err)
	}
	request.Header.Set("X-Request-ID", "req-mobile-test")
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("GET /health error = %v", err)
	}
	defer response.Body.Close()

	var payload struct {
		Type      string `json:"type"`
		RequestID string `json:"requestId"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.Type != "core.health" || payload.RequestID != "req-mobile-test" {
		t.Fatalf("payload = %#v", payload)
	}

	if err := Stop(); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}
	if IsRunning() || Address() != "" {
		t.Fatal("core should be stopped")
	}
}
