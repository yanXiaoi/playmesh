package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"

	"go-server/internal/config"
	"go-server/internal/middleware"
	"go-server/internal/store"
)

type AuthHandler struct {
	config   config.Config
	store    *store.Store
	mutex    sync.Mutex
	captchas map[string]captchaRecord
}

const maxPendingCaptchas = 10000

func NewAuthHandler(cfg config.Config, database *store.Store) *AuthHandler {
	return &AuthHandler{
		config: cfg, store: database, captchas: make(map[string]captchaRecord),
	}
}

func (h *AuthHandler) Captcha(c *gin.Context) {
	generated, err := generateCaptcha(h.config.Admin.CaptchaMode)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "captcha_failed"})
		return
	}
	h.mutex.Lock()
	h.cleanupCaptchasLocked()
	if len(h.captchas) >= maxPendingCaptchas {
		h.mutex.Unlock()
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "captcha_capacity"})
		return
	}
	h.captchas[generated.response.ID] = generated.record
	h.mutex.Unlock()
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.JSON(http.StatusOK, generated.response)
}

func (h *AuthHandler) Login(c *gin.Context) {
	var body struct {
		Username      string `json:"username"`
		Password      string `json:"password"`
		CaptchaID     string `json:"captchaId"`
		CaptchaAnswer string `json:"captchaAnswer"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "登录参数无效",
		})
		return
	}
	if len(body.Username) > 128 ||
		len(body.CaptchaID) > 128 || len(body.CaptchaAnswer) > 1024 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "登录参数过长",
		})
		return
	}
	if !h.ValidateCaptcha(body.CaptchaID, body.CaptchaAnswer) {
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

func (h *AuthHandler) ValidateCaptcha(id, answer string) bool {
	h.mutex.Lock()
	record, ok := h.captchas[id]
	delete(h.captchas, id)
	h.mutex.Unlock()
	if !ok || time.Now().After(record.expiresAt) {
		return false
	}
	if record.mode == "text" {
		return validateClickCaptcha(record.points, answer)
	}
	actual := captchaHash(id, strings.TrimSpace(answer))
	return middleware.SecureBytesEqual(actual[:], record.answerHash[:])
}

func (h *AuthHandler) cleanupCaptchasLocked() {
	now := time.Now()
	for id, record := range h.captchas {
		if now.After(record.expiresAt) {
			delete(h.captchas, id)
		}
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

func captchaHash(id, answer string) [32]byte {
	return sha256.Sum256([]byte(id + "\x00" + strings.ToLower(strings.TrimSpace(answer))))
}
