package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	if declaration["catalogApiVersion"] != "2.0.0" ||
		response.Header.Get("X-Playmesh-Catalog-Version") != "2.0.0" {
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
	if !ok || relay["transport"] != "playmesh-tcp-upgrade" {
		t.Fatalf("中转声明 = %#v", declaration["relay"])
	}
	if relay["publicBaseUrl"] != "https://relay.example.com" {
		t.Fatalf("公共中转地址 = %#v", relay["publicBaseUrl"])
	}
	if relay["protocolVersion"] != "2.0.0" {
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
	if err != nil || retryAfter <= time.Second || retryAfter > 30*time.Second {
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
	recorder := httptest.NewRecorder()
	app.Engine.ServeHTTP(
		recorder,
		httptest.NewRequest(http.MethodGet, "/api/user/me", nil),
	)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("匿名资料读取状态 = %d", recorder.Code)
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

func TestRelayPairsOpaqueBidirectionalStreams(t *testing.T) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	httpServer := httptest.NewServer(app.Engine)
	defer httpServer.Close()

	credentials := createTunnel(t, httpServer.URL)
	host := openUpgrade(t, httpServer.URL, "/relay/v1/host?tunnelId="+credentials.TunnelID, map[string]string{
		"Authorization":         "Bearer test-source-secret-at-least-32-bytes",
		"X-Playmesh-Host-Lease": credentials.HostLease,
	})
	defer host.Close()
	client := openUpgrade(t, httpServer.URL, "/relay/v1/client?tunnelId="+credentials.TunnelID, map[string]string{
		"X-Playmesh-Join-Capability": credentials.JoinCapability,
	})
	defer client.Close()

	assertTunnelCopy(t, client, host, []byte{0, 1, 2, 3, 255})
	assertTunnelCopy(t, host, client, []byte("authority-response"))
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
	TunnelID       string `json:"tunnelId"`
	HostLease      string `json:"hostLease"`
	JoinCapability string `json:"joinCapability"`
}

func createTunnel(t *testing.T, baseURL string) relayCredentials {
	t.Helper()
	request, _ := http.NewRequest(http.MethodPost, baseURL+"/relay/v1/host", bytes.NewReader(nil))
	request.Header.Set("Authorization", "Bearer test-source-secret-at-least-32-bytes")
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
		"tunnelId":       true,
		"hostLease":      true,
		"joinCapability": true,
		"expiresAt":      true,
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

func openUpgrade(
	t *testing.T,
	baseURL string,
	path string,
	headers map[string]string,
) net.Conn {
	t.Helper()
	endpoint, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.DialTimeout("tcp", endpoint.Host, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	var request strings.Builder
	fmt.Fprintf(&request, "GET %s HTTP/1.1\r\n", path)
	fmt.Fprintf(&request, "Host: %s\r\n", endpoint.Host)
	request.WriteString("Connection: Upgrade\r\n")
	request.WriteString("Upgrade: playmesh-tunnel\r\n")
	for name, value := range headers {
		fmt.Fprintf(&request, "%s: %s\r\n", name, value)
	}
	request.WriteString("\r\n")
	if _, err := io.WriteString(conn, request.String()); err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		body, _ := io.ReadAll(response.Body)
		_ = conn.Close()
		t.Fatalf("Upgrade 状态 = %d, body = %s", response.StatusCode, body)
	}
	_ = conn.SetDeadline(time.Time{})
	return &bufferedConn{Conn: conn, reader: reader}
}

func assertTunnelCopy(t *testing.T, source, destination net.Conn, value []byte) {
	t.Helper()
	_ = source.SetWriteDeadline(time.Now().Add(3 * time.Second))
	if _, err := source.Write(value); err != nil {
		t.Fatal(err)
	}
	_ = destination.SetReadDeadline(time.Now().Add(3 * time.Second))
	received := make([]byte, len(value))
	if _, err := io.ReadFull(destination, received); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, value) {
		t.Fatalf("收到 %v, 期望 %v", received, value)
	}
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(buffer []byte) (int, error) {
	return c.reader.Read(buffer)
}

func testConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := config.Default()
	root := t.TempDir()
	cfg.Storage.DatabasePath = filepath.Join(root, "playmesh-server.db")
	cfg.Storage.GamesDirectory = filepath.Join(root, "games")
	cfg.Storage.QuarantineDirectory = filepath.Join(root, "quarantine")
	cfg.Auth.Token = "test-source-secret-at-least-32-bytes"
	cfg.Relay.PublicBaseURL = "https://relay.example.com"
	cfg.Relay.PendingConnectionTimeoutSeconds = 1
	cfg.Relay.IdleTimeoutSeconds = 5
	return cfg
}
