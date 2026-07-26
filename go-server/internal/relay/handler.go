package relay

import (
	"bufio"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"

	"go-server/internal/middleware"
)

const (
	tunnelContextKey = "playmesh.relay.tunnel"
	upgradeProtocol  = "playmesh-tunnel"
)

type Handler struct {
	manager *Manager
	limiter *middleware.IPLimiter
	logger  *slog.Logger
}

func NewHandler(
	manager *Manager,
	limiter *middleware.IPLimiter,
	logger *slog.Logger,
) *Handler {
	return &Handler{manager: manager, limiter: limiter, logger: logger}
}

func (h *Handler) HostLease() gin.HandlerFunc {
	return func(c *gin.Context) {
		tunnel, err := h.manager.AuthenticateHost(
			strings.TrimSpace(c.Query("tunnelId")),
			strings.TrimSpace(c.GetHeader("X-Playmesh-Host-Lease")),
		)
		if err != nil {
			abortRelayError(c, err)
			return
		}
		c.Set(tunnelContextKey, tunnel)
		c.Next()
	}
}

func (h *Handler) ClientCapability() gin.HandlerFunc {
	return func(c *gin.Context) {
		tunnel, err := h.manager.AuthenticateClient(
			strings.TrimSpace(c.Query("tunnelId")),
			strings.TrimSpace(c.GetHeader("X-Playmesh-Join-Capability")),
		)
		if err != nil {
			abortRelayError(c, err)
			return
		}
		c.Set(tunnelContextKey, tunnel)
		c.Next()
	}
}

func (h *Handler) Create(c *gin.Context) {
	credentials, err := h.manager.Create()
	if err != nil {
		abortRelayError(c, err)
		return
	}
	c.JSON(http.StatusCreated, credentials)
}

func (h *Handler) Delete(c *gin.Context) {
	tunnel := c.MustGet(tunnelContextKey).(*Tunnel)
	h.manager.Delete(strings.TrimSpace(c.Query("tunnelId")), tunnel)
	c.Status(http.StatusNoContent)
}

func (h *Handler) Host(c *gin.Context) {
	tunnel := c.MustGet(tunnelContextKey).(*Tunnel)
	conn, _, err := h.upgrade(c)
	if err != nil {
		return
	}
	if err := h.manager.AddHost(tunnel, conn); err != nil {
		_ = conn.Close()
	}
}

func (h *Handler) Client(c *gin.Context) {
	tunnel := c.MustGet(tunnelContextKey).(*Tunnel)
	conn, _, err := h.upgrade(c)
	if err != nil {
		return
	}
	if err := h.manager.PairClient(tunnel, conn); err != nil {
		_ = conn.Close()
	}
}

func (h *Handler) upgrade(c *gin.Context) (net.Conn, func(), error) {
	if !headerContainsToken(c.GetHeader("Connection"), "Upgrade") ||
		!strings.EqualFold(c.GetHeader("Upgrade"), upgradeProtocol) {
		c.AbortWithStatusJSON(http.StatusUpgradeRequired, gin.H{
			"error":   "upgrade_required",
			"message": "需要 playmesh-tunnel Upgrade",
		})
		return nil, nil, errors.New("缺少 Upgrade")
	}
	release, ok := h.limiter.Acquire(c.ClientIP())
	if !ok {
		c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
			"error": "connection_limit",
		})
		return nil, nil, errors.New("连接数量超限")
	}
	hijacker, ok := c.Writer.(http.Hijacker)
	if !ok {
		release()
		c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{
			"error": "hijack_unsupported",
		})
		return nil, nil, errors.New("服务不支持 Hijack")
	}
	conn, buffer, err := hijacker.Hijack()
	if err != nil {
		release()
		c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{
			"error": "upgrade_failed",
		})
		return nil, nil, err
	}
	if err := writeUpgradeResponse(buffer); err != nil {
		release()
		_ = conn.Close()
		return nil, nil, err
	}
	return &releaseConn{Conn: conn, release: release}, release, nil
}

func headerContainsToken(value, expected string) bool {
	for _, token := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(token), expected) {
			return true
		}
	}
	return false
}

func writeUpgradeResponse(writer *bufio.ReadWriter) error {
	if _, err := fmt.Fprintf(writer,
		"HTTP/1.1 101 Switching Protocols\r\n"+
			"Connection: Upgrade\r\n"+
			"Upgrade: %s\r\n\r\n", upgradeProtocol); err != nil {
		return err
	}
	return writer.Flush()
}

type releaseConn struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *releaseConn) Close() error {
	c.once.Do(c.release)
	return c.Conn.Close()
}

func abortRelayError(c *gin.Context, err error) {
	status := http.StatusBadRequest
	code := "relay_error"
	switch {
	case errors.Is(err, ErrUnauthorized):
		status, code = http.StatusUnauthorized, "unauthorized"
	case errors.Is(err, ErrTunnelNotFound):
		status, code = http.StatusNotFound, "tunnel_not_found"
	case errors.Is(err, ErrTunnelLimit), errors.Is(err, ErrConnectionLimit):
		status, code = http.StatusTooManyRequests, "relay_limit"
	case errors.Is(err, ErrHostUnavailable):
		status, code = http.StatusServiceUnavailable, "host_unavailable"
	}
	c.AbortWithStatusJSON(status, gin.H{"error": code, "message": err.Error()})
}
