package target

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDecodeAPIErrorPreservesStructuredCode(t *testing.T) {
	response := &http.Response{
		StatusCode: http.StatusNotFound,
		Body: io.NopCloser(strings.NewReader(
			`{"error":{"code":"not_found","message":"当前项目没有活动的开发资源会话"}}`,
		)),
	}
	err := DecodeAPIError(response)
	if !IsAPIErrorCode(err, "not_found") {
		t.Fatalf("structured API error code was lost: %T %v", err, err)
	}
	if !strings.Contains(err.Error(), "当前项目没有活动的开发资源会话") {
		t.Fatalf("structured API error message was lost: %v", err)
	}
}

func TestDecodeAPIErrorPrintsValidationDiagnostics(t *testing.T) {
	response := &http.Response{
		StatusCode: http.StatusUnprocessableEntity,
		Body: io.NopCloser(strings.NewReader(`{
		  "error": {
		    "code": "package_validation_failed",
		    "message": "项目校验未通过，不能启动游戏"
		  },
		  "validation": {
		    "errorCount": 1,
		    "warningCount": 0,
		    "diagnostics": [{
		      "code": "resource_missing",
		      "severity": "error",
		      "message": "引用的本地资源不存在：./missing.js",
		      "path": "app/index.html",
		      "line": 12,
		      "column": 5,
		      "hint": "补充 app/missing.js，或修正当前引用路径。"
		    }]
		  }
		}`)),
	}
	err := DecodeAPIError(response)
	message := err.Error()
	for _, expected := range []string{
		"Developer API package_validation_failed",
		"项目校验明细（1 个错误，0 个警告）",
		"[resource_missing] app/index.html:12:5",
		"引用的本地资源不存在：./missing.js",
		"建议：补充 app/missing.js，或修正当前引用路径。",
	} {
		if !strings.Contains(message, expected) {
			t.Fatalf("validation detail %q was lost:\n%s", expected, message)
		}
	}
}

func TestClientUsesNoTotalTimeoutForStreamingRequests(t *testing.T) {
	client := NewClient(
		Config{BaseURL: "http://127.0.0.1:16666", Token: "test-token"},
		"test",
	)
	if client.http.Timeout != 30*time.Second {
		t.Fatalf(
			"ordinary API timeout changed unexpectedly: %s",
			client.http.Timeout,
		)
	}
	if client.streamHTTP.Timeout != 0 {
		t.Fatalf(
			"streaming requests must not have a total timeout: %s",
			client.streamHTTP.Timeout,
		)
	}
}

func TestStreamRequestOutlivesOrdinaryRequestTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(
		response http.ResponseWriter,
		request *http.Request,
	) {
		response.Header().Set("Content-Type", "text/event-stream")
		response.WriteHeader(http.StatusOK)
		response.(http.Flusher).Flush()
		time.Sleep(75 * time.Millisecond)
		_, _ = io.WriteString(response, "data: {\"type\":\"runtime.log\"}\n\n")
	}))
	t.Cleanup(server.Close)

	client := NewClient(
		Config{BaseURL: server.URL, Token: "test-token"},
		"test",
	)
	client.http.Timeout = 10 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	response, err := client.StreamRequest(ctx, "GET", "/events", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("stream inherited ordinary request timeout: %v", err)
	}
	if !strings.Contains(string(body), "runtime.log") {
		t.Fatalf("stream response was incomplete: %q", body)
	}
}
