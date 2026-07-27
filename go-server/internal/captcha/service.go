package captcha

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"image"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wenlng/go-captcha/v2/click"
	"github.com/wenlng/go-captcha/v2/rotate"
	"github.com/wenlng/go-captcha/v2/slide"
)

const (
	maxPendingCaptchas   = 10000
	verificationTokenTTL = 2 * time.Minute
)

type Options struct {
	Mode                 string
	ImageSource          string
	LocalImageDirectory  string
	RemoteImageURL       string
	RemoteImageCacheSize int
}

type Service struct {
	options       Options
	images        *imageProvider
	mutex         sync.Mutex
	captchas      map[string]captchaRecord
	verifications map[string]verificationRecord
}

type verificationRecord struct {
	scope     string
	expiresAt time.Time
}

func New(
	ctx context.Context,
	options Options,
	logger *slog.Logger,
) (*Service, error) {
	service := &Service{
		options:       options,
		images:        newImageProvider(options, logger),
		captchas:      make(map[string]captchaRecord),
		verifications: make(map[string]verificationRecord),
	}
	switch options.Mode {
	case "text", "slide":
		if err := service.images.Warm(
			ctx, clickCaptchaWidth, clickCaptchaHeight,
		); err != nil {
			if logger != nil {
				logger.Warn("captcha image pre-cache unavailable", "error", err)
			}
		}
	case "rotate":
		if err := service.images.Warm(
			ctx, clickCaptchaHeight, clickCaptchaHeight,
		); err != nil {
			if logger != nil {
				logger.Warn("captcha image pre-cache unavailable", "error", err)
			}
		}
	}
	return service, nil
}

// Challenge creates a one-time CAPTCHA challenge bound to the supplied scope.
// The scope is server-defined (for example user-login or admin-login) and is
// never accepted from an untrusted request body.
func (s *Service) Challenge(c *gin.Context, scope string) {
	generated, err := s.generate(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error":   "captcha_failed",
			"message": "验证码图片暂时不可用",
		})
		return
	}
	generated.record.scope = scope
	s.mutex.Lock()
	s.cleanupLocked()
	if len(s.captchas) >= maxPendingCaptchas {
		s.mutex.Unlock()
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "captcha_capacity"})
		return
	}
	s.captchas[generated.response.ID] = generated.record
	s.mutex.Unlock()
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.JSON(http.StatusOK, generated.response)
}

// Verify consumes a challenge and, on success, returns a short-lived one-time
// token. Authentication endpoints must consume that token for the same scope.
func (s *Service) Verify(c *gin.Context, scope string) {
	var body struct {
		ID     string `json:"id"`
		Answer string `json:"answer"`
	}
	if err := c.ShouldBindJSON(&body); err != nil ||
		len(body.ID) > 128 || len(body.Answer) > 1024 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "验证码参数无效",
		})
		return
	}
	if !s.validate(body.ID, body.Answer, scope) {
		c.JSON(http.StatusUnauthorized, gin.H{
			"error": "captcha_invalid", "message": "验证码错误或已过期",
		})
		return
	}
	token, err := newVerificationToken()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "captcha_failed", "message": "无法签发验证码凭证",
		})
		return
	}
	expiresAt := time.Now().Add(verificationTokenTTL)
	s.mutex.Lock()
	s.cleanupLocked()
	if len(s.verifications) >= maxPendingCaptchas {
		s.mutex.Unlock()
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "captcha_capacity"})
		return
	}
	s.verifications[verificationTokenHash(token)] = verificationRecord{
		scope: scope, expiresAt: expiresAt,
	}
	s.mutex.Unlock()
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.JSON(http.StatusOK, gin.H{
		"captchaToken": token,
		"expiresIn":    int(verificationTokenTTL.Seconds()),
	})
}

// ConsumeVerification accepts a verification token exactly once and only for
// the same server-defined scope used to create and verify its challenge.
func (s *Service) ConsumeVerification(token, scope string) bool {
	token = strings.TrimSpace(token)
	if token == "" || len(token) > 128 {
		return false
	}
	tokenHash := verificationTokenHash(token)
	s.mutex.Lock()
	record, ok := s.verifications[tokenHash]
	delete(s.verifications, tokenHash)
	s.mutex.Unlock()
	return ok && record.scope == scope && time.Now().Before(record.expiresAt)
}

func (s *Service) validate(id, answer, scope string) bool {
	s.mutex.Lock()
	record, ok := s.captchas[id]
	delete(s.captchas, id)
	s.mutex.Unlock()
	if !ok || record.scope != scope || time.Now().After(record.expiresAt) {
		return false
	}
	switch record.mode {
	case "text":
		return validateClickCaptcha(record.points, answer)
	case "slide":
		return validateSlideCaptcha(record.targetX, record.targetY, answer)
	case "rotate":
		return validateRotateCaptcha(record.targetAngle, answer)
	}
	return false
}

func (s *Service) generate(ctx context.Context) (generatedCaptcha, error) {
	var clickGenerator click.Captcha
	var slideGenerator slide.Captcha
	var rotateGenerator rotate.Captcha
	switch s.options.Mode {
	case "text", "slide":
		background, err := s.images.Take(
			ctx, clickCaptchaWidth, clickCaptchaHeight,
		)
		if err != nil {
			return generatedCaptcha{}, err
		}
		if s.options.Mode == "text" {
			clickGenerator, err = makeClickGenerator([]image.Image{background})
			if err != nil {
				return generatedCaptcha{}, err
			}
		} else {
			slideGenerator, err = makeSlideGenerator([]image.Image{background})
			if err != nil {
				return generatedCaptcha{}, err
			}
		}
	case "rotate":
		background, err := s.images.Take(
			ctx, clickCaptchaHeight, clickCaptchaHeight,
		)
		if err != nil {
			return generatedCaptcha{}, err
		}
		rotateGenerator = makeRotateGenerator([]image.Image{background})
	}
	return generateCaptcha(
		s.options.Mode,
		clickGenerator,
		slideGenerator,
		rotateGenerator,
	)
}

func (s *Service) cleanupLocked() {
	now := time.Now()
	for id, record := range s.captchas {
		if now.After(record.expiresAt) {
			delete(s.captchas, id)
		}
	}
	for tokenHash, record := range s.verifications {
		if now.After(record.expiresAt) {
			delete(s.verifications, tokenHash)
		}
	}
}

func newVerificationToken() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func verificationTokenHash(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}
