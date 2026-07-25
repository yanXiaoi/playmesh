package middleware

import (
	"crypto/subtle"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
)

const sourceAuthenticatedKey = "playmesh.source_authenticated"

func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		requestID := strings.TrimSpace(c.GetHeader("X-Request-ID"))
		if requestID == "" {
			requestID = time.Now().UTC().Format("20060102T150405.000000000")
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

func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Headers",
			"Authorization, Content-Type, X-Playmesh-Host-Lease, X-Playmesh-Join-Capability")
		c.Header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

func SourceToken(auth config.Auth) gin.HandlerFunc {
	token := strings.TrimSpace(auth.Token)
	whitelist := make(map[string]struct{}, len(auth.Whitelist))
	for _, entry := range auth.Whitelist {
		whitelist[strings.ToUpper(strings.TrimSpace(entry.Method))+" "+entry.Path] = struct{}{}
	}
	return func(c *gin.Context) {
		if token == "" {
			c.Set(sourceAuthenticatedKey, true)
			c.Next()
			return
		}
		if _, ok := whitelist[c.Request.Method+" "+c.Request.URL.Path]; ok {
			c.Next()
			return
		}
		provided := strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer ")
		if !secureEqual(provided, token) {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{
				"error":   "unauthorized",
				"message": "需要有效的 Bearer Token",
			})
			return
		}
		c.Set(sourceAuthenticatedKey, true)
		c.Next()
	}
}

func secureEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
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
