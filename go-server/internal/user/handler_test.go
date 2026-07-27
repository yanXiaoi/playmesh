package user

import (
	"bytes"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"go-server/internal/version"
)

func TestUploadKeyComplexity(t *testing.T) {
	valid := []string{"Abcdef1!23", "Playmesh-Key_2026"}
	for _, value := range valid {
		if !validUploadKey(value) {
			t.Fatalf("合法上传密钥被拒绝: %q", value)
		}
	}
	invalid := []string{
		"short1!A", "alllowercase1!", "ALLUPPERCASE1!",
		"NoDigitsHere!", "NoSpecial123A", "Has Space1!A",
	}
	for _, value := range invalid {
		if validUploadKey(value) {
			t.Fatalf("非法上传密钥被接受: %q", value)
		}
	}
}

func TestNormalizeEmailIsCaseInsensitive(t *testing.T) {
	value, err := normalizeEmail("User@Example.COM")
	if err != nil {
		t.Fatal(err)
	}
	if value != "user@example.com" {
		t.Fatalf("规范化邮箱 = %q", value)
	}
}

func TestUploadKeyAuthenticationRejectsBearerScheme(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := &Handler{}
	engine := gin.New()
	engine.POST("/upload", handler.RequireUploadKey(), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/upload", nil)
	request.Header.Set("Authorization", "Bearer Abcdef1!23")
	engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("Bearer 上传密钥状态 = %d", recorder.Code)
	}
}

func TestUploadRequiresPackageMultipartField(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := &Handler{}
	engine := gin.New()
	engine.POST("/upload", handler.BrowserUpload)

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "game.zip")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("not-used")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/upload", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	engine.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("错误 multipart 字段状态 = %d", recorder.Code)
	}
}

func TestInvalidVersionUsesStableHTTPContract(t *testing.T) {
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	contextValue, _ := gin.CreateTestContext(recorder)
	(&Handler{}).writeUploadError(contextValue, version.ErrInvalid)
	if recorder.Code != http.StatusBadRequest ||
		!strings.Contains(recorder.Body.String(), `"code":"invalid_version"`) {
		t.Fatalf(
			"非法版本 HTTP 响应 = %d %s",
			recorder.Code,
			recorder.Body.String(),
		)
	}
}
