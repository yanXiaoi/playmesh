package middleware

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
)

const (
	sourceAuthenticatedKey = "playmesh.source_authenticated"
)

func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		requestID := strings.TrimSpace(c.GetHeader("X-Request-ID"))
		if requestID == "" || len(requestID) > 128 {
			value := make([]byte, 16)
			if _, err := rand.Read(value); err == nil {
				requestID = hex.EncodeToString(value)
			} else {
				requestID = time.Now().UTC().Format("20060102T150405.000000000")
			}
		}
		c.Header("X-Request-ID", requestID)
		c.Set("requestID", requestID)
		c.Next()
	}
}

func AccessLog(logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		started := time.Now()
		c.Next()
		logger.Info("HTTP 请求",
			"requestId", c.GetString("requestID"),
			"method", c.Request.Method,
			"path", c.Request.URL.Path,
			"status", c.Writer.Status(),
			"durationMs", time.Since(started).Milliseconds(),
			"clientIp", c.ClientIP(),
		)
	}
}

func SecurityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("X-Content-Type-Options", "nosniff")
		c.Header("X-Frame-Options", "DENY")
		c.Header("Referrer-Policy", "no-referrer")
		c.Header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		c.Header("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "+
				"img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; "+
				"base-uri 'none'; form-action 'self'")
		c.Next()
	}
}

func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Headers",
			"Authorization, Content-Type, X-Playmesh-Host-Lease, X-Playmesh-Join-Capability")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

// CatalogToken 保留 Relay 既有的双 Token 鉴权行为。
func CatalogToken(auth config.Auth) gin.HandlerFunc {
	publishedToken := strings.TrimSpace(auth.PublishedToken)
	if publishedToken == "" {
		publishedToken = strings.TrimSpace(auth.Token)
	}
	reviewToken := strings.TrimSpace(auth.ReviewToken)
	whitelist := make(map[string]struct{}, len(auth.Whitelist))
	for _, entry := range auth.Whitelist {
		whitelist[strings.ToUpper(strings.TrimSpace(entry.Method))+" "+entry.Path] = struct{}{}
	}
	return func(c *gin.Context) {
		if _, ok := whitelist[c.Request.Method+" "+c.Request.URL.Path]; ok {
			c.Next()
			return
		}
		provided, ok := bearerToken(c.GetHeader("Authorization"))
		switch {
		case ok && SecureEqual(provided, publishedToken):
		case ok && SecureEqual(provided, reviewToken):
		default:
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error":   "unauthorized",
				"message": "需要有效的正式发布或待审核 Bearer Token",
			})
			return
		}
		c.Set(sourceAuthenticatedKey, true)
		c.Next()
	}
}

func SourceToken(auth config.Auth) gin.HandlerFunc {
	return CatalogToken(auth)
}

func CatalogReadToken(auth config.Auth) gin.HandlerFunc {
	publishedToken := strings.TrimSpace(auth.PublishedToken)
	if publishedToken == "" {
		publishedToken = strings.TrimSpace(auth.Token)
	}
	whitelist := make(map[string]struct{}, len(auth.Whitelist))
	for _, entry := range auth.Whitelist {
		whitelist[strings.ToUpper(strings.TrimSpace(entry.Method))+" "+entry.Path] = struct{}{}
	}
	return func(c *gin.Context) {
		if _, ok := whitelist[c.Request.Method+" "+c.Request.URL.Path]; ok {
			c.Next()
			return
		}
		provided, ok := bearerToken(c.GetHeader("Authorization"))
		if !ok || !SecureEqual(provided, publishedToken) {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"code": "unauthorized", "message": "需要有效的 Catalog 读取 Token",
			})
			return
		}
		c.Set(sourceAuthenticatedKey, true)
		c.Next()
	}
}

func BearerToken(c *gin.Context) (string, bool) {
	return bearerToken(c.GetHeader("Authorization"))
}

func bearerToken(header string) (string, bool) {
	scheme, token, ok := strings.Cut(strings.TrimSpace(header), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

func SecureEqual(left, right string) bool {
	if len(left) != len(right) || len(left) == 0 {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func SecureBytesEqual(left, right []byte) bool {
	return len(left) == len(right) && len(left) > 0 &&
		subtle.ConstantTimeCompare(left, right) == 1
}

func NoStore() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
		c.Header("Pragma", "no-cache")
		c.Next()
	}
}

type IntervalLimiter struct {
	mutex    sync.Mutex
	interval time.Duration
	lastSeen map[string]time.Time
}

type windowRecord struct {
	count     int
	expiresAt time.Time
}

type WindowLimiter struct {
	mutex   sync.Mutex
	limit   int
	window  time.Duration
	records map[string]windowRecord
}

func NewWindowLimiter(limit int, window time.Duration) *WindowLimiter {
	return &WindowLimiter{
		limit: limit, window: window, records: make(map[string]windowRecord),
	}
}

func (l *WindowLimiter) Allow(key string) bool {
	now := time.Now()
	l.mutex.Lock()
	defer l.mutex.Unlock()
	record := l.records[key]
	if record.expiresAt.IsZero() || !now.Before(record.expiresAt) {
		record = windowRecord{expiresAt: now.Add(l.window)}
	}
	if record.count >= l.limit {
		l.records[key] = record
		return false
	}
	record.count++
	l.records[key] = record
	if len(l.records) > 10000 {
		for candidate, value := range l.records {
			if !now.Before(value.expiresAt) {
				delete(l.records, candidate)
			}
		}
	}
	return true
}

func WindowRateLimit(limiter *WindowLimiter, scope string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !limiter.Allow(scope + ":" + c.ClientIP()) {
			c.Header("Retry-After", "1")
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"error":   "rate_limited",
				"message": "请求过于频繁，请稍后重试",
			})
			return
		}
		c.Next()
	}
}

func NewIntervalLimiter(interval time.Duration) *IntervalLimiter {
	return &IntervalLimiter{interval: interval, lastSeen: make(map[string]time.Time)}
}

func (l *IntervalLimiter) Allow(key string) bool {
	allowed, _ := l.AllowWithRetryAfter(key)
	return allowed
}

func (l *IntervalLimiter) AllowWithRetryAfter(key string) (bool, time.Duration) {
	now := time.Now()
	l.mutex.Lock()
	defer l.mutex.Unlock()
	if previous, ok := l.lastSeen[key]; ok {
		remaining := l.interval - now.Sub(previous)
		if remaining > 0 {
			return false, remaining
		}
	}
	l.lastSeen[key] = now
	if len(l.lastSeen) > 10000 {
		cutoff := now.Add(-10 * l.interval)
		for candidate, seen := range l.lastSeen {
			if seen.Before(cutoff) {
				delete(l.lastSeen, candidate)
			}
		}
	}
	return true, 0
}

func RateLimit(limiter *IntervalLimiter, scope string) gin.HandlerFunc {
	return func(c *gin.Context) {
		allowed, retryAfter := limiter.AllowWithRetryAfter(
			scope + ":" + c.ClientIP(),
		)
		if !allowed {
			retryAfterSeconds := int64(
				(retryAfter + time.Second - 1) / time.Second,
			)
			if retryAfterSeconds < 1 {
				retryAfterSeconds = 1
			}
			c.Header("Retry-After", strconv.FormatInt(retryAfterSeconds, 10))
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"error":   "rate_limited",
				"message": "请求过于频繁，请稍后重试",
			})
			return
		}
		c.Next()
	}
}

type IPLimiter struct {
	mutex sync.Mutex
	limit int
	inUse map[string]int
}

func NewIPLimiter(limit int) *IPLimiter {
	return &IPLimiter{limit: limit, inUse: make(map[string]int)}
}

// Acquire protects long-lived Upgrade requests. Call the returned release after
// the detached connection closes.
func (l *IPLimiter) Acquire(ip string) (func(), bool) {
	l.mutex.Lock()
	defer l.mutex.Unlock()
	if l.inUse[ip] >= l.limit {
		return nil, false
	}
	l.inUse[ip]++
	var once sync.Once
	return func() {
		once.Do(func() {
			l.mutex.Lock()
			defer l.mutex.Unlock()
			l.inUse[ip]--
			if l.inUse[ip] <= 0 {
				delete(l.inUse, ip)
			}
		})
	}, true
}

func (l *IPLimiter) Current() int {
	l.mutex.Lock()
	defer l.mutex.Unlock()
	total := 0
	for _, count := range l.inUse {
		total += count
	}
	return total
}
