package relay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/middleware"
)

const (
	tunnelContextKey      = "playmesh.relay.tunnel"
	maxSignalMessageSize  = 256 * 1024
	maxSignalMessages     = 480
	relayClockSkew        = 5 * time.Minute
	relayHeartbeat        = 30 * time.Second
	relayHeartbeatTimeout = 10 * time.Second
)

var relayRequestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

type Handler struct {
	manager *Manager
	limiter *middleware.IPLimiter
	logger  *slog.Logger
}

func NewHandler(manager *Manager, limiter *middleware.IPLimiter, logger *slog.Logger) *Handler {
	return &Handler{manager: manager, limiter: limiter, logger: logger}
}

func (h *Handler) HostLease() gin.HandlerFunc {
	return func(c *gin.Context) {
		if _, ok := relayProtocolMetadata(c); !ok {
			return
		}
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
		if _, ok := relayProtocolMetadata(c); !ok {
			return
		}
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
	requestID, ok := relayProtocolMetadata(c)
	if !ok {
		return
	}
	credentials, err := h.manager.Create(requestID)
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
	connection, release, ok := h.accept(c)
	if !ok {
		return
	}
	defer release()
	peer, err := h.manager.AttachHost(tunnel, connection)
	if err != nil {
		_ = connection.Close(websocket.StatusPolicyViolation, err.Error())
		return
	}
	defer h.manager.DetachHost(tunnel, peer)
	stopHeartbeat := h.monitorConnection(connection)
	defer stopHeartbeat()
	h.readSignals(c.Request.Context(), connection, func(frame SignalFrame, size int) bool {
		return h.manager.RouteFromHost(tunnel, frame, size)
	})
}

func (h *Handler) Client(c *gin.Context) {
	tunnel := c.MustGet(tunnelContextKey).(*Tunnel)
	connection, release, ok := h.accept(c)
	if !ok {
		return
	}
	defer release()
	peerID, peer, err := h.manager.AttachClient(tunnel, connection)
	if err != nil {
		_ = connection.Close(websocket.StatusPolicyViolation, err.Error())
		return
	}
	defer h.manager.DetachClient(tunnel, peerID, peer)
	stopHeartbeat := h.monitorConnection(connection)
	defer stopHeartbeat()
	h.readSignals(c.Request.Context(), connection, func(frame SignalFrame, size int) bool {
		return h.manager.RouteFromClient(tunnel, peerID, frame, size)
	})
}

func (h *Handler) monitorConnection(connection *websocket.Conn) context.CancelFunc {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		ticker := time.NewTicker(relayHeartbeat)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				pingCtx, pingCancel := context.WithTimeout(ctx, relayHeartbeatTimeout)
				err := connection.Ping(pingCtx)
				pingCancel()
				if err != nil {
					_ = connection.CloseNow()
					return
				}
			case <-ctx.Done():
				return
			}
		}
	}()
	return cancel
}

func (h *Handler) accept(c *gin.Context) (*websocket.Conn, func(), bool) {
	release, allowed := h.limiter.Acquire(c.ClientIP())
	if !allowed {
		c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "connection_limit"})
		return nil, func() {}, false
	}
	connection, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		release()
		return nil, func() {}, false
	}
	connection.SetReadLimit(maxSignalMessageSize)
	return connection, release, true
}

func (h *Handler) readSignals(
	ctx context.Context,
	connection *websocket.Conn,
	route func(SignalFrame, int) bool,
) {
	windowStart := time.Now()
	messageCount := 0
	for {
		_, data, err := connection.Read(ctx)
		if err != nil {
			return
		}
		now := time.Now()
		if now.Sub(windowStart) >= time.Second {
			windowStart, messageCount = now, 0
		}
		messageCount++
		if messageCount > maxSignalMessages {
			_ = connection.Close(websocket.StatusPolicyViolation, "信令发送速率过高")
			return
		}
		var frame SignalFrame
		if json.Unmarshal(data, &frame) != nil ||
			frame.ProtocolVersion != config.RelayProtocolVersion ||
			!relayRequestIDPattern.MatchString(frame.RequestID) ||
			frame.Timestamp <= 0 ||
			time.Since(time.UnixMilli(frame.Timestamp)) < -relayClockSkew ||
			time.Since(time.UnixMilli(frame.Timestamp)) > relayClockSkew ||
			!json.Valid(frame.Payload) || !route(frame, len(data)) {
			_ = connection.Close(websocket.StatusUnsupportedData, "信令消息格式无效")
			return
		}
	}
}

func relayProtocolMetadata(c *gin.Context) (string, bool) {
	if c.GetHeader("X-Playmesh-Relay-Version") != config.RelayProtocolVersion {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "unsupported_relay_version"})
		return "", false
	}
	requestID := strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID"))
	if !relayRequestIDPattern.MatchString(requestID) {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "invalid_request_id"})
		return "", false
	}
	timestamp, err := strconv.ParseInt(c.GetHeader("X-Playmesh-Timestamp"), 10, 64)
	if err != nil {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "invalid_timestamp"})
		return "", false
	}
	difference := time.Since(time.UnixMilli(timestamp))
	if difference < -relayClockSkew || difference > relayClockSkew {
		c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{"error": "expired_timestamp"})
		return "", false
	}
	c.Header("X-Playmesh-Relay-Version", config.RelayProtocolVersion)
	c.Header("X-Playmesh-Request-ID", requestID)
	c.Header("X-Playmesh-Timestamp", strconv.FormatInt(time.Now().UnixMilli(), 10))
	return requestID, true
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
