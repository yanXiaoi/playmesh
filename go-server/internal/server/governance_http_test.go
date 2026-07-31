package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"go-server/internal/store"
)

func TestGameDeletionEnforcesOwnershipAndRetriesPersistedDeletingState(
	t *testing.T,
) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	ctx := context.Background()
	owner, err := app.store.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	other, err := app.store.CreateUser(ctx, "other@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	ownerCookie, ownerCSRF := createUserTestSession(t, app, owner.ID, "owner")
	otherCookie, otherCSRF := createUserTestSession(t, app, other.ID, "other")

	blockingPath := filepath.Join(cfg.Storage.GamesDirectory, "blocked.zip")
	if err := os.Mkdir(blockingPath, 0o750); err != nil {
		t.Fatal(err)
	}
	blocker := filepath.Join(blockingPath, "child")
	if err := os.WriteFile(blocker, []byte("block deletion"), 0o600); err != nil {
		t.Fatal(err)
	}
	game, err := app.store.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID:        "com.example.retry",
		Name:             "原样游戏名称",
		Author:           "原样发布者",
		Version:          "1.0.0",
		OwnerUserID:      owner.ID,
		Status:           store.StatusPending,
		OriginalFilename: "retry.zip",
		StoredPath:       blockingPath,
		ManifestJSON:     `{"id":"com.example.retry","version":"1.0.0"}`,
		ScanStatus:       "clean",
		ScanReport:       "{}",
	})
	if err != nil {
		t.Fatal(err)
	}

	otherPublish := authenticatedUserRequest(
		app.Engine,
		http.MethodPost,
		"/api/user/games/"+gameID(game.ID)+"/publish",
		otherCookie,
		otherCSRF,
	)
	if otherPublish.Code != http.StatusNotFound {
		t.Fatalf(
			"其他账号发布状态 = %d, body = %s",
			otherPublish.Code,
			otherPublish.Body.String(),
		)
	}
	otherAttempt := authenticatedUserRequest(
		app.Engine,
		http.MethodDelete,
		"/api/user/games/"+gameID(game.ID),
		otherCookie,
		otherCSRF,
	)
	if otherAttempt.Code != http.StatusNotFound {
		t.Fatalf(
			"其他账号删除状态 = %d, body = %s",
			otherAttempt.Code,
			otherAttempt.Body.String(),
		)
	}
	stillPending, err := app.store.GetGame(ctx, game.ID)
	if err != nil || stillPending.Status != store.StatusPending {
		t.Fatalf("越权删除改变了记录 = %#v, err = %v", stillPending, err)
	}

	deferred := authenticatedUserRequest(
		app.Engine,
		http.MethodDelete,
		"/api/user/games/"+gameID(game.ID),
		ownerCookie,
		ownerCSRF,
	)
	if deferred.Code != http.StatusAccepted ||
		!strings.Contains(deferred.Body.String(), "deletion_pending") {
		t.Fatalf("首次删除响应 = %d %s", deferred.Code, deferred.Body.String())
	}
	deleting, err := app.store.GetGame(ctx, game.ID)
	if err != nil || deleting.Status != store.StatusDeleting {
		t.Fatalf("延迟删除记录 = %#v, err = %v", deleting, err)
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(blockingPath); err != nil {
		t.Fatal(err)
	}
	retried := authenticatedUserRequest(
		app.Engine,
		http.MethodDelete,
		"/api/user/games/"+gameID(game.ID),
		ownerCookie,
		ownerCSRF,
	)
	if retried.Code != http.StatusNoContent {
		t.Fatalf("重试删除响应 = %d %s", retried.Code, retried.Body.String())
	}
	if _, err := app.store.GetGame(ctx, game.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("重试后记录仍存在: %v", err)
	}
}

func TestManagementRoutesAreIsolatedAndAdminCanDeleteAnyUnpublishedGame(
	t *testing.T,
) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	ctx := context.Background()
	owner, err := app.store.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	game, err := app.store.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID:        "com.example.admin-delete",
		Name:             "Admin Delete",
		Author:           "Owner",
		Version:          "1.0.0",
		OwnerUserID:      owner.ID,
		Status:           store.StatusPending,
		OriginalFilename: "admin-delete.zip",
		ManifestJSON:     `{"id":"com.example.admin-delete","version":"1.0.0"}`,
		ScanStatus:       "clean",
		ScanReport:       "{}",
	})
	if err != nil {
		t.Fatal(err)
	}
	adminGamesPath := cfg.AdminPath + "/api/admin/games"
	external := httptest.NewRecorder()
	app.Engine.ServeHTTP(
		external,
		httptest.NewRequest(http.MethodGet, adminGamesPath, nil),
	)
	if external.Code != http.StatusNotFound {
		t.Fatalf("外部端口暴露管理 API，状态 = %d", external.Code)
	}
	unauthorized := httptest.NewRecorder()
	app.AdminEngine.ServeHTTP(
		unauthorized,
		httptest.NewRequest(http.MethodGet, adminGamesPath, nil),
	)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("匿名管理 API 状态 = %d", unauthorized.Code)
	}
	adminUsersPath := cfg.AdminPath + "/api/admin/users"
	externalUsers := httptest.NewRecorder()
	app.Engine.ServeHTTP(
		externalUsers,
		httptest.NewRequest(http.MethodGet, adminUsersPath, nil),
	)
	if externalUsers.Code != http.StatusNotFound {
		t.Fatalf("外部端口暴露用户管理 API，状态 = %d", externalUsers.Code)
	}
	unauthorizedUsers := httptest.NewRecorder()
	app.AdminEngine.ServeHTTP(
		unauthorizedUsers,
		httptest.NewRequest(http.MethodGet, adminUsersPath, nil),
	)
	if unauthorizedUsers.Code != http.StatusUnauthorized {
		t.Fatalf("匿名用户管理 API 状态 = %d", unauthorizedUsers.Code)
	}

	adminToken := strings.Repeat("a", 43)
	if err := app.store.CreateAdminSession(
		ctx,
		testTokenHash(adminToken),
		time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	deleteRequest := httptest.NewRequest(
		http.MethodDelete,
		adminGamesPath+"/"+gameID(game.ID),
		nil,
	)
	deleteRequest.Header.Set("Authorization", "Bearer "+adminToken)
	deleted := httptest.NewRecorder()
	app.AdminEngine.ServeHTTP(deleted, deleteRequest)
	if deleted.Code != http.StatusNoContent {
		t.Fatalf("管理员删除状态 = %d, body = %s", deleted.Code, deleted.Body.String())
	}
	if _, err := app.store.GetGame(ctx, game.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("管理员删除后记录仍存在: %v", err)
	}
}

func TestAPIPayloadIgnoresAcceptLanguageAndKeepsDynamicValuesVerbatim(
	t *testing.T,
) {
	cfg := testConfig(t)
	app, err := New(cfg, DiscardLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	ctx := context.Background()
	owner, err := app.store.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	owner, err = app.store.UpdateDisplayName(ctx, owner.ID, "原样 Publisher en-GB")
	if err != nil {
		t.Fatal(err)
	}
	game, err := app.store.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID:        "com.example.dynamic",
		Name:             "用户自定义 Game 名称",
		Author:           owner.DisplayName,
		Version:          "1.2.3",
		Remarks:          "API 原样 description",
		OwnerUserID:      owner.ID,
		Status:           store.StatusPending,
		OriginalFilename: "dynamic.zip",
		StoredPath:       "packages/com.example.dynamic/1.2.3.zip",
		PackageSizeBytes: 987654,
		ManifestJSON:     `{"id":"com.example.dynamic","version":"1.2.3","author":"上传时昵称"}`,
		ScanStatus:       "clean",
		ScanReport:       "{}",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := app.store.UpdateGameStatus(
		ctx,
		game.ID,
		store.StatusApproved,
		"",
		store.AdminReviewActor(cfg.AdminUsername),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := app.store.SetPublished(
		ctx,
		game.ID,
		store.AdminReviewActor(cfg.AdminUsername),
		true,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := app.store.UpdateDisplayName(
		ctx, owner.ID, "更新后 Publisher en-GB",
	); err != nil {
		t.Fatal(err)
	}

	requestCatalog := func(language, remoteAddr string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(
			http.MethodGet,
			"/api/public/games?page=1&size=12",
			nil,
		)
		request.Header.Set("Accept-Language", language)
		request.RemoteAddr = remoteAddr
		recorder := httptest.NewRecorder()
		app.Engine.ServeHTTP(recorder, request)
		return recorder
	}
	english := requestCatalog("en-GB,en;q=0.9", "192.0.2.21:1000")
	chinese := requestCatalog("zh-CN,zh;q=0.9", "192.0.2.22:1000")
	if english.Code != http.StatusOK || chinese.Code != http.StatusOK {
		t.Fatalf(
			"API 状态 en=%d zh=%d",
			english.Code,
			chinese.Code,
		)
	}
	if english.Body.String() != chinese.Body.String() {
		t.Fatalf(
			"Accept-Language 改写了 API JSON\nen=%s\nzh=%s",
			english.Body.String(),
			chinese.Body.String(),
		)
	}
	var payload struct {
		Data []struct {
			ID      string `json:"id"`
			Name    string `json:"name"`
			Author  string `json:"author"`
			Remarks string `json:"remarks"`
			Size    int64  `json:"packageSizeBytes"`
		} `json:"data"`
	}
	if err := json.Unmarshal(english.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Data) != 1 ||
		payload.Data[0].ID != "com.example.dynamic" ||
		payload.Data[0].Name != "用户自定义 Game 名称" ||
		payload.Data[0].Author != "更新后 Publisher en-GB" ||
		payload.Data[0].Remarks != "API 原样 description" ||
		payload.Data[0].Size != 987654 {
		t.Fatalf("动态字段被改写 = %#v", payload.Data)
	}

	catalogRequest := httptest.NewRequest(
		http.MethodGet,
		"/apps/list?page=1&size=12",
		nil,
	)
	catalogRequest.Header.Set(
		"Authorization",
		"Bearer test-source-secret-at-least-32-bytes",
	)
	catalogResponse := httptest.NewRecorder()
	app.Engine.ServeHTTP(catalogResponse, catalogRequest)
	if catalogResponse.Code != http.StatusOK {
		t.Fatalf(
			"Catalog API 状态 = %d, body = %s",
			catalogResponse.Code,
			catalogResponse.Body.String(),
		)
	}
	var catalogPayload struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(catalogResponse.Body.Bytes(), &catalogPayload); err != nil {
		t.Fatal(err)
	}
	if len(catalogPayload.Data) != 1 ||
		catalogPayload.Data[0]["packageSizeBytes"] != float64(987654) {
		t.Fatalf("Catalog 游戏包大小 = %#v", catalogPayload.Data)
	}

	requestInvalidToken := func(language string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(
			http.MethodGet,
			"/api/user/auth/verify-email?token=invalid",
			nil,
		)
		request.Header.Set("Accept-Language", language)
		recorder := httptest.NewRecorder()
		app.Engine.ServeHTTP(recorder, request)
		return recorder
	}
	englishError := requestInvalidToken("en-GB")
	chineseError := requestInvalidToken("zh-CN")
	if englishError.Code != http.StatusSeeOther ||
		chineseError.Code != http.StatusSeeOther ||
		englishError.Header().Get("Location") != "/my?emailVerification=failed" ||
		chineseError.Header().Get("Location") != "/my?emailVerification=failed" {
		t.Fatalf(
			"Accept-Language 改写了邮箱验证跳转\nen=%d %s\nzh=%d %s",
			englishError.Code, englishError.Header().Get("Location"),
			chineseError.Code, chineseError.Header().Get("Location"),
		)
	}
}

func createUserTestSession(
	t *testing.T,
	app *Server,
	userID int64,
	label string,
) (*http.Cookie, string) {
	t.Helper()
	sessionToken := "session-token-" + label
	csrfToken := "csrf-token-" + label
	if err := app.store.CreateUserSession(
		context.Background(),
		userID,
		testTokenHash(sessionToken),
		testTokenHash(csrfToken),
		time.Now().Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	return &http.Cookie{
		Name:  "playmesh_user_session",
		Value: sessionToken,
		Path:  "/",
	}, csrfToken
}

func authenticatedUserRequest(
	engine http.Handler,
	method string,
	path string,
	cookie *http.Cookie,
	csrf string,
) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	request.AddCookie(cookie)
	request.Header.Set("X-CSRF-Token", csrf)
	recorder := httptest.NewRecorder()
	engine.ServeHTTP(recorder, request)
	return recorder
}

func testTokenHash(value string) string {
	hash := sha256.Sum256([]byte(value))
	return hex.EncodeToString(hash[:])
}

func gameID(value int64) string {
	return strconv.FormatInt(value, 10)
}
