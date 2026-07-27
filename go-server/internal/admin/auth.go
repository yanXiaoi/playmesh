package admin

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	captchamodule "go-server/internal/captcha"
	"go-server/internal/config"
	"go-server/internal/middleware"
	"go-server/internal/store"
)

type AuthHandler struct {
	config  config.Config
	store   *store.Store
	captcha *captchamodule.Service
}

const adminLoginCaptchaScope = "admin-login"

func NewAuthHandler(cfg config.Config, database *store.Store) *AuthHandler {
	service, _ := captchamodule.New(
		context.Background(),
		captchaOptions(cfg),
		nil,
	)
	return NewAuthHandlerWithCaptchaService(cfg, database, service)
}

func NewAuthHandlerWithCaptchaService(
	cfg config.Config,
	database *store.Store,
	service *captchamodule.Service,
) *AuthHandler {
	return &AuthHandler{
		config:  cfg,
		store:   database,
		captcha: service,
	}
}

func (h *AuthHandler) Captcha(c *gin.Context) {
	if h.captcha == nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error":   "captcha_failed",
			"message": "验证码模块未初始化",
		})
		return
	}
	h.captcha.Challenge(c, adminLoginCaptchaScope)
}

func (h *AuthHandler) VerifyCaptcha(c *gin.Context) {
	if h.captcha == nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error":   "captcha_failed",
			"message": "验证码模块未初始化",
		})
		return
	}
	h.captcha.Verify(c, adminLoginCaptchaScope)
}

func (h *AuthHandler) Login(c *gin.Context) {
	var body struct {
		Username     string `json:"username"`
		Password     string `json:"password"`
		CaptchaToken string `json:"captchaToken"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "登录参数无效",
		})
		return
	}
	if len(body.Username) > 128 || len(body.CaptchaToken) > 128 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "登录参数过长",
		})
		return
	}
	if h.captcha == nil ||
		!h.captcha.ConsumeVerification(body.CaptchaToken, adminLoginCaptchaScope) {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": "captcha_invalid", "message": "验证码错误或已过期",
		})
		return
	}
	if !middleware.SecureEqual(strings.TrimSpace(body.Username), h.config.AdminUsername) ||
		!passwordMatches(body.Password, h.config.AdminPassword) {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": "credentials_invalid", "message": "管理员账号或密码错误",
		})
		return
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "session_failed"})
		return
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes)
	expiresAt := time.Now().Add(
		time.Duration(h.config.Admin.SessionTTLMinutes) * time.Minute,
	)
	if err := h.store.CreateAdminSession(
		c.Request.Context(), hashToken(token), expiresAt,
	); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "session_failed"})
		return
	}
	_ = h.store.CleanupAdminSessions(c.Request.Context(), time.Now())
	c.JSON(http.StatusOK, gin.H{
		"token": token, "expiresAt": expiresAt.UnixMilli(),
	})
}

func (h *AuthHandler) Logout(c *gin.Context) {
	token, ok := middleware.BearerToken(c)
	if ok {
		_ = h.store.DeleteAdminSession(c.Request.Context(), hashToken(token))
	}
	c.Status(http.StatusNoContent)
}

func (h *AuthHandler) RequireSession() gin.HandlerFunc {
	return func(c *gin.Context) {
		token, ok := middleware.BearerToken(c)
		if !ok || len(token) != 43 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": "admin_unauthorized", "message": "需要管理员登录",
			})
			return
		}
		valid, err := h.store.AdminSessionValid(
			c.Request.Context(), hashToken(token), time.Now(),
		)
		if err != nil || !valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error": "admin_unauthorized", "message": "管理员会话无效或已过期",
			})
			return
		}
		c.Next()
	}
}

func passwordMatches(provided, configured string) bool {
	if strings.HasPrefix(configured, "$2a$") ||
		strings.HasPrefix(configured, "$2b$") ||
		strings.HasPrefix(configured, "$2y$") {
		return bcrypt.CompareHashAndPassword(
			[]byte(configured), []byte(provided),
		) == nil
	}
	return middleware.SecureEqual(provided, configured)
}

func hashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func captchaOptions(cfg config.Config) captchamodule.Options {
	return captchamodule.Options{
		Mode:                 cfg.Admin.CaptchaMode,
		ImageSource:          cfg.Admin.CaptchaImageSource,
		LocalImageDirectory:  cfg.Admin.CaptchaImageDirectory,
		RemoteImageURL:       cfg.Admin.CaptchaImageURL,
		RemoteImageCacheSize: cfg.Admin.CaptchaImageCacheSize,
	}
}
