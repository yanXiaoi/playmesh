package captcha

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestVerificationTokenIsScopedAndOneTime(t *testing.T) {
	gin.SetMode(gin.TestMode)
	service := &Service{
		captchas:      make(map[string]captchaRecord),
		verifications: make(map[string]verificationRecord),
	}
	issue := func(id, scope string) string {
		t.Helper()
		service.captchas[id] = captchaRecord{
			expiresAt: time.Now().Add(time.Minute),
			scope:     scope,
			mode:      "slide",
			targetX:   120,
			targetY:   80,
		}
		engine := gin.New()
		engine.POST("/verify", func(c *gin.Context) {
			service.Verify(c, scope)
		})
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(
			http.MethodPost,
			"/verify",
			strings.NewReader(`{"id":"`+id+`","answer":"slide:120,80"}`),
		)
		request.Header.Set("Content-Type", "application/json")
		engine.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("验证码验证状态 = %d, body = %s", recorder.Code, recorder.Body.String())
		}
		var result struct {
			CaptchaToken string `json:"captchaToken"`
		}
		if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if result.CaptchaToken == "" {
			t.Fatal("验证码验证未签发临时 Token")
		}
		return result.CaptchaToken
	}

	wrongScopeToken := issue("challenge-one", "user-login")
	if service.ConsumeVerification(wrongScopeToken, "admin-login") {
		t.Fatal("用户验证码 Token 被管理员登录作用域接受")
	}
	if service.ConsumeVerification(wrongScopeToken, "user-login") {
		t.Fatal("作用域错误的消费尝试后 Token 仍可再次使用")
	}

	token := issue("challenge-two", "user-register")
	if !service.ConsumeVerification(token, "user-register") {
		t.Fatal("正确作用域的一次性验证码 Token 被拒绝")
	}
	if service.ConsumeVerification(token, "user-register") {
		t.Fatal("验证码 Token 被重复使用")
	}
}

func TestFailedChallengeIsConsumed(t *testing.T) {
	gin.SetMode(gin.TestMode)
	service := &Service{
		captchas: map[string]captchaRecord{
			"challenge": {
				expiresAt: time.Now().Add(time.Minute),
				scope:     "user-login",
				mode:      "slide",
				targetX:   120,
				targetY:   80,
			},
		},
		verifications: make(map[string]verificationRecord),
	}
	verify := func(answer string) int {
		engine := gin.New()
		engine.POST("/verify", func(c *gin.Context) {
			service.Verify(c, "user-login")
		})
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(
			http.MethodPost,
			"/verify",
			strings.NewReader(`{"id":"challenge","answer":"`+answer+`"}`),
		)
		request.Header.Set("Content-Type", "application/json")
		engine.ServeHTTP(recorder, request)
		return recorder.Code
	}
	if status := verify("slide:200,80"); status != http.StatusUnauthorized {
		t.Fatalf("错误答案状态 = %d", status)
	}
	if status := verify("slide:120,80"); status != http.StatusUnauthorized {
		t.Fatalf("失败后重复使用挑战状态 = %d", status)
	}
}
