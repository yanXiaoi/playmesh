package webrtctunnel

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestCreateRelaySessionPreservesRawServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusBadRequest)
		_, _ = writer.Write([]byte(`{"error":"expired_timestamp","message":"raw clock failure"}`))
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = createRelaySession(context.Background(), serverURL, HostRequest{
		HostPath:    "/relay/v1/host",
		SourceToken: "source-token",
	})
	if err == nil {
		t.Fatal("createRelaySession error = nil")
	}
	for _, expected := range []string{
		"400 Bad Request",
		`"expired_timestamp"`,
		"raw clock failure",
	} {
		if !strings.Contains(err.Error(), expected) {
			t.Fatalf("error %q does not contain %q", err, expected)
		}
	}
}
