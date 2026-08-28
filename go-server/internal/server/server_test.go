package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"go-server/internal/config"
	"go-server/internal/store"
)

func TestCatalogInfoUsesGlobalTokenMiddleware(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	httpServer := httptest.NewServer(app.Engine)
	defer httpServer.Close()

	response, err := http.Get(httpServer.URL + "/apps/info")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未鉴权状态 = %d", response.StatusCode)
	}
	reviewRequest, _ := http.NewRequest(http.MethodGet, httpServer.URL+"/apps/info", nil)
	reviewRequest.Header.Set(
		"Authorization", "Bearer test-review-token-at-least-32-bytes",
	)
	reviewResponse, err := http.DefaultClient.Do(reviewRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer reviewResponse.Body.Close()
	if reviewResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("待审核 Token 读取 Catalog 状态 = %d", reviewResponse.StatusCode)
	}

	request, _ := http.NewRequest(http.MethodGet, httpServer.URL+"/apps/info", nil)
	request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("声明状态 = %d", response.StatusCode)
	}
	var declaration map[string]any
	if err := json.NewDecoder(response.Body).Decode(&declaration); err != nil {
		t.Fatal(err)
	}
	if declaration["supportsGameRelay"] != true {
		t.Fatalf("声明 = %#v", declaration)
	}
	if declaration["catalogApiVersion"] != "3.0.0" ||
		response.Header.Get("X-Playmesh-Catalog-Version") != "3.0.0" {
		t.Fatalf(
			"Catalog 版本 = body:%#v header:%q",
			declaration["catalogApiVersion"],
			response.Header.Get("X-Playmesh-Catalog-Version"),
		)
	}
	upload, ok := declaration["userUpload"].(map[string]any)
	if !ok || upload["supported"] != true || upload["protocolVersion"] != "1.0.0" {
		t.Fatalf("用户上传声明 = %#v", declaration["userUpload"])
	}
	relay, ok := declaration["relay"].(map[string]any)
	if !ok || relay["transport"] != "playmesh-webrtc-datachannel" {
		t.Fatalf("中转声明 = %#v", declaration["relay"])
	}
	if relay["publicBaseUrl"] != "https://relay.example.com" {
		t.Fatalf("公共中转地址 = %#v", relay["publicBaseUrl"])
	}
	if relay["protocolVersion"] != "4.0.0" {
		t.Fatalf("中转协议版本 = %#v", relay["protocolVersion"])
	}
	if relay["maxConnectionsPerTunnel"] != float64(cfg.Relay.MaxConnectionsPerTunnel) {
		t.Fatalf("单隧道连接上限 = %#v", relay["maxConnectionsPerTunnel"])
	}
}

type countingReadCloser struct {
	reads int
}

func (r *countingReadCloser) Read(buffer []byte) (int, error) {
	r.reads++
	return 0, io.EOF
}

func (r *countingReadCloser) Close() error { return nil }

func TestUploadRateLimitRunsBeforeReadingRequestBody(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()

	first := httptest.NewRequest(http.MethodPost, "/api/user/uploads", nil)
	first.RemoteAddr = "192.0.2.10:1234"
	firstResult := httptest.NewRecorder()
	app.Engine.ServeHTTP(firstResult, first)
	if firstResult.Code != http.StatusUnauthorized {
		t.Fatalf("首次上传状态 = %d", firstResult.Code)
	}

	body := &countingReadCloser{}
	second := httptest.NewRequest(
		http.MethodPost,
		"/api/user/games/uploads",
		body,
	)
	second.RemoteAddr = "192.0.2.10:5678"
	secondResult := httptest.NewRecorder()
	app.Engine.ServeHTTP(secondResult, second)
	if secondResult.Code != http.StatusTooManyRequests {
		t.Fatalf("限流上传状态 = %d", secondResult.Code)
	}
	if body.reads != 0 {
		t.Fatalf("限流响应读取了请求体 %d 次", body.reads)
	}
	retryAfter, err := time.ParseDuration(
		secondResult.Header().Get("Retry-After") + "s",
	)
	if err != nil || retryAfter < time.Second || retryAfter > 2*time.Second {
		t.Fatalf(
			"上传限流 Retry-After = %q, err = %v",
			secondResult.Header().Get("Retry-After"),
			err,
		)
	}
}

func TestCatalogListKeepsPagingContract(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/apps/list?page=3&size=7", nil)
	request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
	app.Engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态 = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		Total   int   `json:"total"`
		Current int   `json:"current"`
		Size    int   `json:"size"`
		Data    []any `json:"data"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Total != 0 || payload.Current != 3 || payload.Size != 7 || len(payload.Data) != 0 {
		t.Fatalf("分页响应 = %#v", payload)
	}
}

func TestCatalogDownloadRequiresVersion(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodGet, "/apps/download?id=com.example.game", nil,
	)
	setRelayProtocolHeaders(request.Header)
	request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
	app.Engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest ||
		!strings.Contains(recorder.Body.String(), "invalid_version") {
		t.Fatalf("缺少版本响应 = %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestRegistrationDisabledBeforeCaptchaValidation(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	settings, err := app.store.GetSettings(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	settings.AllowUserRegistration = false
	if err := app.store.UpdateSettings(
		context.Background(), settings, store.AdminReviewActor(cfg.AdminUsername),
	); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/user/auth/register",
		strings.NewReader(`{"email":"user@example.com","password":"Password1!","confirmPassword":"Password1!"}`),
	)
	request.Header.Set("Content-Type", "application/json")
	app.Engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusForbidden ||
		!strings.Contains(recorder.Body.String(), "registration_disabled") {
		t.Fatalf("关闭注册响应 = %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestUserDataRoutesRequireSession(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	for _, path := range []string{
		"/api/user/me",
		"/api/user/upload-key",
		"/api/user/notifications",
	} {
		recorder := httptest.NewRecorder()
		app.Engine.ServeHTTP(
			recorder,
			httptest.NewRequest(http.MethodGet, path, nil),
		)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("匿名访问 %s 状态 = %d", path, recorder.Code)
		}
	}
}

func TestCaptchaChallengeAndVerificationEndpointsAreRateLimited(t *testing.T) {
	cfg := testConfig(t)
	cfg.Admin.CaptchaIntervalMilliseconds = 60_000
	cfg.Admin.LoginIntervalMilliseconds = 60_000
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()

	assertSecondRequestLimited := func(
		engine http.Handler,
		method string,
		path string,
		body string,
	) {
		t.Helper()
		for attempt := 0; attempt < 2; attempt++ {
			recorder := httptest.NewRecorder()
			request := httptest.NewRequest(method, path, strings.NewReader(body))
			if body != "" {
				request.Header.Set("Content-Type", "application/json")
			}
			engine.ServeHTTP(recorder, request)
			if attempt == 0 && recorder.Code == http.StatusTooManyRequests {
				t.Fatalf("%s %s 首次请求意外被限流", method, path)
			}
			if attempt == 1 && recorder.Code != http.StatusTooManyRequests {
				t.Fatalf(
					"%s %s 第二次请求状态 = %d, want 429",
					method,
					path,
					recorder.Code,
				)
			}
		}
	}

	assertSecondRequestLimited(
		app.Engine,
		http.MethodGet,
		"/api/user/auth/captcha?purpose=login",
		"",
	)
	assertSecondRequestLimited(
		app.Engine,
		http.MethodPost,
		"/api/user/auth/captcha/verify?purpose=login",
		`{"id":"missing","answer":"slide:0,0"}`,
	)
	assertSecondRequestLimited(
		app.AdminEngine,
		http.MethodGet,
		cfg.AdminPath+"/api/auth/captcha",
		"",
	)
	assertSecondRequestLimited(
		app.AdminEngine,
		http.MethodPost,
		cfg.AdminPath+"/api/auth/captcha/verify",
		`{"id":"missing","answer":"slide:0,0"}`,
	)
}

func TestRelayRoutesOpaqueWebRTCSignalsForMultiplePeers(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	httpServer := httptest.NewServer(app.Engine)
	defer httpServer.Close()

	credentials := createTunnel(t, httpServer.URL)
	host := openSignalWebSocket(t, httpServer.URL, "/relay/v1/host?tunnelId="+credentials.TunnelID, map[string]string{
		"Authorization":         "Bearer test-source-secret-at-least-32-bytes",
		"X-Playmesh-Host-Lease": credentials.HostLease,
	})
	defer host.CloseNow()
	first := openSignalWebSocket(t, httpServer.URL, "/relay/v1/client?tunnelId="+credentials.TunnelID, map[string]string{
		"X-Playmesh-Join-Capability": credentials.JoinCapability,
	})
	defer first.CloseNow()
	second := openSignalWebSocket(t, httpServer.URL, "/relay/v1/client?tunnelId="+credentials.TunnelID, map[string]string{
		"X-Playmesh-Join-Capability": credentials.JoinCapability,
	})
	defer second.CloseNow()

	firstConnected := readSignalFrame(t, first, "connected")
	secondConnected := readSignalFrame(t, second, "connected")
	if firstConnected.PeerID == "" || secondConnected.PeerID == "" ||
		firstConnected.PeerID == secondConnected.PeerID {
		t.Fatalf("peer ids = %q, %q", firstConnected.PeerID, secondConnected.PeerID)
	}
	readSignalFrame(t, host, "peer.joined")
	readSignalFrame(t, host, "peer.joined")

	writeSignalFrame(t, first, map[string]any{
		"type": "description", "payload": map[string]any{"type": "offer", "sdp": "opaque-one"},
	})
	firstOffer := readSignalFrame(t, host, "description")
	if firstOffer.PeerID != firstConnected.PeerID ||
		!bytes.Contains(firstOffer.Payload, []byte(`"opaque-one"`)) {
		t.Fatalf("first offer = %#v payload=%s", firstOffer, firstOffer.Payload)
	}
	writeSignalFrame(t, host, map[string]any{
		"type": "candidate", "peerId": secondConnected.PeerID,
		"payload": map[string]any{"candidate": "opaque-two"},
	})
	secondCandidate := readSignalFrame(t, second, "candidate")
	if secondCandidate.PeerID != secondConnected.PeerID ||
		!bytes.Contains(secondCandidate.Payload, []byte(`"opaque-two"`)) {
		t.Fatalf("second candidate = %#v payload=%s", secondCandidate, secondCandidate.Payload)
	}
}

func TestRelayClientWhitelistStillRequiresCapability(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(
		http.MethodGet,
		"/relay/v1/client?tunnelId=missing",
		nil,
	)
	setRelayProtocolHeaders(request.Header)
	app.Engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("状态 = %d, body = %s", recorder.Code, recorder.Body.String())
	}
}

func TestRelayRoutesAreAbsentWhenDeclarationDisablesRelay(t *testing.T) {
	cfg := testConfig(t)
	cfg.SupportsGameRelay = false
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()

	for _, path := range []string{
		"/relay/v1/host",
		"/relay/v1/client",
		"/app/index.html",
	} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
		app.Engine.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d, body = %s", path, recorder.Code, recorder.Body.String())
		}
	}
}

type relayCredentials struct {
	Type            string `json:"type"`
	ProtocolVersion string `json:"protocolVersion"`
	Timestamp       int64  `json:"timestamp"`
	RequestID       string `json:"requestId"`
	TunnelID        string `json:"tunnelId"`
	HostLease       string `json:"hostLease"`
	JoinCapability  string `json:"joinCapability"`
}

func createTunnel(t *testing.T, baseURL string) relayCredentials {
	t.Helper()
	request, _ := http.NewRequest(http.MethodPost, baseURL+"/relay/v1/host", bytes.NewReader(nil))
	request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
	setRelayProtocolHeaders(request.Header)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("创建状态 = %d, body = %s", response.StatusCode, body)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		t.Fatal(err)
	}
	allowed := map[string]bool{
		"type":            true,
		"protocolVersion": true,
		"timestamp":       true,
		"requestId":       true,
		"tunnelId":        true,
		"hostLease":       true,
		"joinCapability":  true,
		"expiresAt":       true,
		"iceServers":      true,
	}
	for name := range fields {
		if !allowed[name] {
			t.Fatalf("创建隧道响应包含未允许字段 %q", name)
		}
	}
	var credentials relayCredentials
	if err := json.Unmarshal(body, &credentials); err != nil {
		t.Fatal(err)
	}
	return credentials
}

func openSignalWebSocket(
	t *testing.T,
	baseURL string,
	path string,
	headers map[string]string,
) *websocket.Conn {
	t.Helper()
	header := make(http.Header, len(headers))
	for name, value := range headers {
		header.Set(name, value)
	}
	setRelayProtocolHeaders(header)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, response, err := websocket.Dial(
		ctx,
		strings.Replace(baseURL, "http", "ws", 1)+path,
		&websocket.DialOptions{HTTPHeader: header},
	)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("WebSocket 状态 = %d, error = %v", status, err)
	}
	return connection
}

type relaySignalFrame struct {
	Type            string          `json:"type"`
	ProtocolVersion string          `json:"protocolVersion"`
	Timestamp       int64           `json:"timestamp"`
	RequestID       string          `json:"requestId"`
	PeerID          string          `json:"peerId"`
	Payload         json.RawMessage `json:"payload"`
}

func writeSignalFrame(t *testing.T, connection *websocket.Conn, value map[string]any) {
	t.Helper()
	value["protocolVersion"] = config.RelayProtocolVersion
	value["timestamp"] = time.Now().UnixMilli()
	value["requestId"] = "relay-signal-test"
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func setRelayProtocolHeaders(header http.Header) {
	header.Set("X-Playmesh-Relay-Version", config.RelayProtocolVersion)
	header.Set("X-Playmesh-Request-ID", "relay-http-test")
	header.Set("X-Playmesh-Timestamp", fmt.Sprintf("%d", time.Now().UnixMilli()))
}

func readSignalFrame(t *testing.T, connection *websocket.Conn, expected string) relaySignalFrame {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		_, data, err := connection.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var frame relaySignalFrame
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatal(err)
		}
		if frame.Type == expected {
			return frame
		}
	}
}

func testConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := config.Default()
	root := t.TempDir()
	cfg.Storage.DatabasePath = filepath.Join(root, "playmesh-server.db")
	cfg.Storage.GamesDirectory = filepath.Join(root, "games")
	cfg.Storage.QuarantineDirectory = filepath.Join(root, "quarantine")
	// Unit tests must not depend on the default remote CAPTCHA image service.
	cfg.Admin.CaptchaImageSource = "local"
	cfg.Admin.CaptchaImageDirectory = filepath.Join(root, "captcha-images")
	cfg.Auth.Token = "test-source-secret-at-least-32-bytes"
	cfg.Relay.PublicBaseURL = "https://relay.example.com"
	return cfg
}
