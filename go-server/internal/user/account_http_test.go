package user

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
)

type accountTestCaptcha struct {
	accept bool
	calls  int
}

func (c *accountTestCaptcha) Challenge(*gin.Context, string) {}

func (c *accountTestCaptcha) Verify(*gin.Context, string) {}

func (c *accountTestCaptcha) ConsumeVerification(_, _ string) bool {
	c.calls++
	return c.accept
}

type accountTestHarness struct {
	handler *Handler
	store   *store.Store
	engine  *gin.Engine
	config  config.Config
	captcha *accountTestCaptcha
	dbPath  string
}

func newAccountTestHarness(
	t *testing.T,
	requireVerification bool,
) *accountTestHarness {
	t.Helper()
	gin.SetMode(gin.TestMode)
	root := t.TempDir()
	cfg := config.Default()
	cfg.Storage.DatabasePath = filepath.Join(root, "server.db")
	cfg.Storage.GamesDirectory = filepath.Join(root, "games")
	cfg.Storage.QuarantineDirectory = filepath.Join(root, "quarantine")
	cfg.Relay.PublicBaseURL = "http://source.example"
	cfg.Auth.PublishedToken = "published-token"
	cfg.UploadKeyPepper = "upload-key-pepper-for-tests"
	database, err := store.Open(cfg.Storage, store.Settings{
		AllowUserRegistration:    true,
		RequireEmailVerification: requireVerification,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	captcha := &accountTestCaptcha{accept: true}
	handler := New(
		cfg,
		database,
		nil,
		mailer.New(config.Mail{}),
		captcha,
	)
	engine := gin.New()
	engine.POST("/register", handler.Register)
	engine.POST("/login", handler.Login)
	engine.GET("/verify", handler.VerifyEmail)
	engine.POST("/resend", handler.ResendVerification)
	engine.GET("/me", handler.RequireSession(false), handler.Me)
	engine.PATCH("/me", handler.RequireSession(true), handler.UpdateMe)
	engine.POST("/logout", handler.RequireSession(true), handler.Logout)
	return &accountTestHarness{
		handler: handler, store: database, engine: engine, config: cfg,
		captcha: captcha, dbPath: cfg.Storage.DatabasePath,
	}
}

func TestPrivateSourceConfigurationIncludesUploadKey(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	payload, err := harness.handler.sourceConfigurationURL("upload-secret")
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(payload)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "http" ||
		parsed.Host != "source.example" ||
		parsed.Query().Get("token") != "published-token" ||
		parsed.Query().Get("uploadKey") != "upload-secret" {
		t.Fatalf("专属游戏源二维码载荷 = %q", payload)
	}
	png, err := harness.handler.sourceQRCode("upload-secret")
	if err != nil {
		t.Fatal(err)
	}
	if len(png) < 4 || string(png[:4]) != "\x89PNG" {
		t.Fatalf("专属游戏源二维码不是 PNG: %x", png[:min(4, len(png))])
	}
}

func accountJSONRequest(
	t *testing.T,
	engine http.Handler,
	method string,
	path string,
	body string,
	cookies []*http.Cookie,
	csrf string,
) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	for _, cookie := range cookies {
		request.AddCookie(cookie)
	}
	if csrf != "" {
		request.Header.Set("X-CSRF-Token", csrf)
	}
	recorder := httptest.NewRecorder()
	engine.ServeHTTP(recorder, request)
	return recorder
}

func TestVerifiedAccountHTTPFlowPersistsSessionAndCSRF(t *testing.T) {
	harness := newAccountTestHarness(t, true)
	register := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/register",
		`{"email":"User@Example.COM","password":"Password1!","confirmPassword":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if register.Code != http.StatusAccepted ||
		register.Body.String() != `{"status":"registration_received"}` {
		t.Fatalf("注册状态 = %d, body = %s", register.Code, register.Body.String())
	}
	account, _, err := harness.store.GetUserByEmail(
		context.Background(),
		"user@example.com",
	)
	if err != nil {
		t.Fatal(err)
	}
	if account.Email != "user@example.com" ||
		account.DisplayName != "user@example.com" ||
		account.Status != "pending_verification" {
		t.Fatalf("注册账号 = %#v", account)
	}

	pendingLogin := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/login",
		`{"email":"user@example.com","password":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if pendingLogin.Code != http.StatusForbidden ||
		!strings.Contains(pendingLogin.Body.String(), "email_verification_required") {
		t.Fatalf(
			"待验证登录响应 = %d %s",
			pendingLogin.Code,
			pendingLogin.Body.String(),
		)
	}

	if err := harness.store.CreateEmailVerificationToken(
		context.Background(),
		account.ID,
		hashToken("old-token"),
		time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if err := harness.store.CreateEmailVerificationToken(
		context.Background(),
		account.ID,
		hashToken("current-token"),
		time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	oldToken := accountJSONRequest(
		t, harness.engine, http.MethodGet, "/verify?token=old-token", "", nil, "",
	)
	if oldToken.Code != http.StatusSeeOther ||
		oldToken.Header().Get("Location") != "/my?emailVerification=failed" {
		t.Fatalf("被替换 Token 状态 = %d", oldToken.Code)
	}
	currentToken := accountJSONRequest(
		t, harness.engine, http.MethodGet, "/verify?token=current-token", "", nil, "",
	)
	if currentToken.Code != http.StatusSeeOther ||
		currentToken.Header().Get("Location") != "/my?emailVerification=success" {
		t.Fatalf("当前 Token 状态 = %d, body = %s", currentToken.Code, currentToken.Body.String())
	}
	reusedToken := accountJSONRequest(
		t, harness.engine, http.MethodGet, "/verify?token=current-token", "", nil, "",
	)
	if reusedToken.Code != http.StatusSeeOther ||
		reusedToken.Header().Get("Location") != "/my?emailVerification=failed" {
		t.Fatalf("重复使用 Token 状态 = %d", reusedToken.Code)
	}

	login := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/login",
		`{"email":"USER@example.com","password":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if login.Code != http.StatusOK {
		t.Fatalf("登录状态 = %d, body = %s", login.Code, login.Body.String())
	}
	var loginBody struct {
		CSRFToken string `json:"csrfToken"`
	}
	if err := json.Unmarshal(login.Body.Bytes(), &loginBody); err != nil {
		t.Fatal(err)
	}
	var sessionCookie, csrfCookie *http.Cookie
	for _, cookie := range login.Result().Cookies() {
		switch cookie.Name {
		case sessionCookieName:
			sessionCookie = cookie
		case csrfCookieName:
			csrfCookie = cookie
		}
	}
	if sessionCookie == nil || !sessionCookie.HttpOnly || sessionCookie.Secure ||
		sessionCookie.SameSite != http.SameSiteLaxMode {
		t.Fatalf("会话 Cookie = %#v", sessionCookie)
	}
	if csrfCookie == nil || csrfCookie.HttpOnly || csrfCookie.Secure ||
		csrfCookie.SameSite != http.SameSiteLaxMode ||
		csrfCookie.Value != loginBody.CSRFToken {
		t.Fatalf("CSRF Cookie = %#v, body token = %q", csrfCookie, loginBody.CSRFToken)
	}

	me := accountJSONRequest(
		t, harness.engine, http.MethodGet, "/me", "", []*http.Cookie{sessionCookie}, "",
	)
	if me.Code != http.StatusOK {
		t.Fatalf("读取账号状态 = %d", me.Code)
	}
	missingCSRF := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPatch,
		"/me",
		`{"displayName":"原样玩家 en-GB"}`,
		[]*http.Cookie{sessionCookie},
		"",
	)
	if missingCSRF.Code != http.StatusForbidden {
		t.Fatalf("缺少 CSRF 的写请求状态 = %d", missingCSRF.Code)
	}
	update := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPatch,
		"/me",
		`{"displayName":"原样玩家 en-GB"}`,
		[]*http.Cookie{sessionCookie},
		loginBody.CSRFToken,
	)
	if update.Code != http.StatusOK ||
		!strings.Contains(update.Body.String(), "原样玩家 en-GB") {
		t.Fatalf("资料更新响应 = %d %s", update.Code, update.Body.String())
	}
	logout := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/logout",
		"",
		[]*http.Cookie{sessionCookie},
		loginBody.CSRFToken,
	)
	if logout.Code != http.StatusNoContent {
		t.Fatalf("退出状态 = %d", logout.Code)
	}
	afterLogout := accountJSONRequest(
		t, harness.engine, http.MethodGet, "/me", "", []*http.Cookie{sessionCookie}, "",
	)
	if afterLogout.Code != http.StatusUnauthorized {
		t.Fatalf("退出后旧会话状态 = %d", afterLogout.Code)
	}
}

func TestSessionCookiesAreSecureForHTTPS(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	for _, test := range []struct {
		name      string
		target    string
		forwarded string
	}{
		{name: "TLS request", target: "https://source.example/login"},
		{name: "TLS proxy", target: "http://source.example/login", forwarded: "https"},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, test.target, nil)
			if test.forwarded != "" {
				request.Header.Set("X-Forwarded-Proto", test.forwarded)
			}
			recorder := httptest.NewRecorder()
			context, _ := gin.CreateTestContext(recorder)
			context.Request = request
			harness.handler.setSessionCookie(context, "session", 60)
			harness.handler.setCSRFCookie(context, "csrf", 60)
			cookies := recorder.Result().Cookies()
			if len(cookies) != 2 || !cookies[0].Secure || !cookies[1].Secure {
				t.Fatalf("HTTPS Cookies = %#v", cookies)
			}
		})
	}
}

func TestRegistrationResponseDoesNotEnumerateExistingEmail(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	body := `{"email":"user@example.com","password":"Password1!","confirmPassword":"Password1!","captchaToken":"verified"}`
	first := accountJSONRequest(
		t, harness.engine, http.MethodPost, "/register", body, nil, "",
	)
	second := accountJSONRequest(
		t, harness.engine, http.MethodPost, "/register", body, nil, "",
	)
	const expected = `{"status":"registration_received"}`
	for name, response := range map[string]*httptest.ResponseRecorder{
		"new": first, "existing": second,
	} {
		if response.Code != http.StatusAccepted ||
			response.Body.String() != expected {
			t.Fatalf(
				"%s 注册响应 = %d %q",
				name,
				response.Code,
				response.Body.String(),
			)
		}
	}
	if _, _, err := harness.store.GetUserByEmail(
		context.Background(),
		"user@example.com",
	); err != nil {
		t.Fatalf("统一响应后账号未创建: %v", err)
	}
}

func TestDisabledAccountCannotLogin(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	passwordHash, err := hashPassword("Password1!")
	if err != nil {
		t.Fatal(err)
	}
	account, err := harness.store.CreateUser(
		context.Background(), "disabled@example.com", passwordHash, "active",
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := harness.store.SetUserDisabled(
		context.Background(), account.ID, true, "测试禁用",
	); err != nil {
		t.Fatal(err)
	}
	response := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/login",
		`{"email":"disabled@example.com","password":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if response.Code != http.StatusForbidden ||
		!strings.Contains(response.Body.String(), `"code":"user_disabled"`) {
		t.Fatalf("禁用用户登录响应 = %d %s", response.Code, response.Body.String())
	}
}

func TestDisabledAccountCannotUploadWithExistingKey(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	account, err := harness.store.CreateUser(
		context.Background(), "upload-disabled@example.com", "hash", "active",
	)
	if err != nil {
		t.Fatal(err)
	}
	const uploadKey = "Upload!Key123"
	if err := harness.store.PutUploadCredential(
		context.Background(), account.ID, harness.handler.uploadKeyHMAC(uploadKey),
	); err != nil {
		t.Fatal(err)
	}
	if err := harness.store.SetUserDisabled(
		context.Background(), account.ID, true, "禁止继续上传",
	); err != nil {
		t.Fatal(err)
	}
	engine := gin.New()
	engine.POST("/upload", harness.handler.RequireUploadKey(), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})
	request := httptest.NewRequest(http.MethodPost, "/upload", nil)
	request.Header.Set("Authorization", "UploadKey "+uploadKey)
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden ||
		!strings.Contains(response.Body.String(), `"code":"user_disabled"`) {
		t.Fatalf("禁用用户上传响应 = %d %s", response.Code, response.Body.String())
	}
}

func TestResendVerificationIsRateLimitedAndNonEnumerating(t *testing.T) {
	harness := newAccountTestHarness(t, true)
	register := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/register",
		`{"email":"pending@example.com","password":"Password1!","confirmPassword":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if register.Code != http.StatusAccepted ||
		register.Body.String() != `{"status":"registration_received"}` {
		t.Fatalf("注册状态 = %d, body = %s", register.Code, register.Body.String())
	}
	account, _, err := harness.store.GetUserByEmail(
		context.Background(),
		"pending@example.com",
	)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	_, sent, err := harness.store.VerificationSendStats(
		context.Background(),
		account.ID,
		now,
	)
	if err != nil || sent != 1 {
		t.Fatalf("初始发送统计 = %d, err = %v", sent, err)
	}

	existing := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/resend",
		`{"email":"PENDING@example.com"}`,
		nil,
		"",
	)
	unknown := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/resend",
		`{"email":"missing@example.com"}`,
		nil,
		"",
	)
	malformed := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/resend",
		`{"email":"not-an-email"}`,
		nil,
		"",
	)
	for name, response := range map[string]*httptest.ResponseRecorder{
		"existing":  existing,
		"unknown":   unknown,
		"malformed": malformed,
	} {
		if response.Code != http.StatusAccepted ||
			response.Body.String() != `{"status":"verification_requested"}` {
			t.Fatalf("%s 重发响应 = %d %q", name, response.Code, response.Body.String())
		}
	}
	_, sent, err = harness.store.VerificationSendStats(
		context.Background(),
		account.ID,
		time.Now(),
	)
	if err != nil || sent != 1 {
		t.Fatalf("60 秒内重复发送统计 = %d, err = %v", sent, err)
	}

	raw, err := sql.Open("sqlite", harness.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	if _, err := raw.Exec(
		"UPDATE email_verification_tokens SET created_at = ? WHERE user_id = ?",
		time.Now().Add(-61*time.Second).UnixMilli(),
		account.ID,
	); err != nil {
		t.Fatal(err)
	}
	afterInterval := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/resend",
		`{"email":"pending@example.com"}`,
		nil,
		"",
	)
	if afterInterval.Code != http.StatusAccepted {
		t.Fatalf("超过最短间隔后的重发状态 = %d", afterInterval.Code)
	}
	_, sent, err = harness.store.VerificationSendStats(
		context.Background(),
		account.ID,
		time.Now(),
	)
	if err != nil || sent != 2 {
		t.Fatalf("超过最短间隔后的发送统计 = %d, err = %v", sent, err)
	}

	for index := 0; index < 3; index++ {
		if err := harness.store.CreateEmailVerificationToken(
			context.Background(),
			account.ID,
			hashToken("hourly-token-"+string(rune('a'+index))),
			time.Now().Add(time.Hour),
		); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := raw.Exec(
		"UPDATE email_verification_tokens SET created_at = ? WHERE user_id = ?",
		time.Now().Add(-2*time.Minute).UnixMilli(),
		account.ID,
	); err != nil {
		t.Fatal(err)
	}
	atHourlyCap := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/resend",
		`{"email":"pending@example.com"}`,
		nil,
		"",
	)
	if atHourlyCap.Code != http.StatusAccepted ||
		atHourlyCap.Body.String() != unknown.Body.String() {
		t.Fatalf("小时上限响应 = %d %q", atHourlyCap.Code, atHourlyCap.Body.String())
	}
	_, sent, err = harness.store.VerificationSendStats(
		context.Background(),
		account.ID,
		time.Now(),
	)
	if err != nil || sent != 5 {
		t.Fatalf("小时上限后的发送统计 = %d, err = %v", sent, err)
	}
}

func TestRegistrationSwitchDoesNotDisableExistingLogin(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	passwordHash, err := hashPassword("Password1!")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := harness.store.CreateUser(
		context.Background(),
		"existing@example.com",
		passwordHash,
		"active",
	); err != nil {
		t.Fatal(err)
	}
	settings, err := harness.store.GetSettings(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	settings.AllowUserRegistration = false
	if err := harness.store.UpdateSettings(
		context.Background(), settings, store.AdminReviewActor("test-admin"),
	); err != nil {
		t.Fatal(err)
	}
	harness.captcha.calls = 0
	register := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/register",
		`{"email":"new@example.com","password":"Password1!","confirmPassword":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if register.Code != http.StatusForbidden ||
		harness.captcha.calls != 0 {
		t.Fatalf(
			"关闭注册响应 = %d, captcha calls = %d",
			register.Code,
			harness.captcha.calls,
		)
	}
	login := accountJSONRequest(
		t,
		harness.engine,
		http.MethodPost,
		"/login",
		`{"email":"existing@example.com","password":"Password1!","captchaToken":"verified"}`,
		nil,
		"",
	)
	if login.Code != http.StatusOK {
		t.Fatalf("关闭注册后的既有账号登录 = %d %s", login.Code, login.Body.String())
	}
}

func TestDeletePackageUsesUnifiedGameIDBounds(t *testing.T) {
	harness := newAccountTestHarness(t, false)
	owner, err := harness.store.CreateUser(
		context.Background(),
		"owner@example.com",
		"hash",
		"active",
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := harness.store.CreateOwnedGame(
		context.Background(),
		store.CreateGameInput{
			PackageID:        "a",
			Name:             "One Character ID",
			Author:           "Owner",
			Version:          "1.0.0",
			OwnerUserID:      owner.ID,
			Status:           store.StatusPending,
			OriginalFilename: "a.zip",
			ManifestJSON:     `{"id":"a","version":"1.0.0"}`,
			ScanStatus:       "clean",
			ScanReport:       "{}",
		},
	); err != nil {
		t.Fatal(err)
	}
	engine := gin.New()
	engine.DELETE("/games/:gameId", func(c *gin.Context) {
		c.Set(userContextKey, owner)
		harness.handler.DeletePackage(c)
	})
	accepted := accountJSONRequest(
		t,
		engine,
		http.MethodDelete,
		"/games/a",
		"",
		nil,
		"",
	)
	if accepted.Code != http.StatusNoContent {
		t.Fatalf("单字符 gameId 删除状态 = %d %s", accepted.Code, accepted.Body.String())
	}
	tooLong := accountJSONRequest(
		t,
		engine,
		http.MethodDelete,
		"/games/"+strings.Repeat("a", 65),
		"",
		nil,
		"",
	)
	if tooLong.Code != http.StatusBadRequest ||
		!strings.Contains(tooLong.Body.String(), "invalid_game_id") {
		t.Fatalf("超长 gameId 删除状态 = %d %s", tooLong.Code, tooLong.Body.String())
	}
}
