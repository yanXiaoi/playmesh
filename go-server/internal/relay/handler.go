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

type signalConnectionMetadata struct {
	role                string
	tunnelID            string
	peerID              string
	clientIP            string
	connectionRequestID string
}

type signalFrameValidationError struct {
	code    string
	message string
}

func (e *signalFrameValidationError) Error() string {
	return e.message
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
		h.logger.Warn(
			"Relay Authority 信令附着失败",
			"component", "relay-signaling",
			"event", "relay.host_attach_failed",
			"tunnelId", tunnel.id,
			"clientIp", c.ClientIP(),
			"connectionRequestId", strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
			"error", err,
		)
		_ = connection.Close(websocket.StatusPolicyViolation, err.Error())
		return
	}
	defer h.manager.DetachHost(tunnel, peer)
	stopHeartbeat := h.monitorConnection(connection)
	defer stopHeartbeat()
	h.readSignals(c.Request.Context(), connection, signalConnectionMetadata{
		role: "host", tunnelID: tunnel.id, clientIP: c.ClientIP(),
		connectionRequestID: strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
	}, func(frame SignalFrame, size int) error {
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
		h.logger.Warn(
			"Relay 加入端信令附着失败",
			"component", "relay-signaling",
			"event", "relay.client_attach_failed",
			"tunnelId", tunnel.id,
			"clientIp", c.ClientIP(),
			"connectionRequestId", strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
			"error", err,
		)
		_ = connection.Close(websocket.StatusPolicyViolation, err.Error())
		return
	}
	defer h.manager.DetachClient(tunnel, peerID, peer)
	stopHeartbeat := h.monitorConnection(connection)
	defer stopHeartbeat()
	h.readSignals(c.Request.Context(), connection, signalConnectionMetadata{
		role: "client", tunnelID: tunnel.id, peerID: peerID, clientIP: c.ClientIP(),
		connectionRequestID: strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
	}, func(frame SignalFrame, size int) error {
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
		h.logger.Warn(
			"Relay WebSocket 连接被并发限制拒绝",
			"component", "relay-signaling",
			"event", "relay.websocket_rejected",
			"failureCode", "ip_connection_limit",
			"clientIp", c.ClientIP(),
			"connectionRequestId", strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
		)
		c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "connection_limit"})
		return nil, func() {}, false
	}
	connection, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		release()
		h.logger.Warn(
			"Relay WebSocket 升级失败",
			"component", "relay-signaling",
			"event", "relay.websocket_upgrade_failed",
			"clientIp", c.ClientIP(),
			"connectionRequestId", strings.TrimSpace(c.GetHeader("X-Playmesh-Request-ID")),
			"error", err,
		)
		return nil, func() {}, false
	}
	connection.SetReadLimit(maxSignalMessageSize)
	return connection, release, true
}

func (h *Handler) readSignals(
	ctx context.Context,
	connection *websocket.Conn,
	metadata signalConnectionMetadata,
	route func(SignalFrame, int) error,
) {
	windowStart := time.Now()
	messageCount := 0
	for {
		_, data, err := connection.Read(ctx)
		if err != nil {
			h.logSignalReadFailure(metadata, err)
			return
		}
		now := time.Now()
		if now.Sub(windowStart) >= time.Second {
			windowStart, messageCount = now, 0
		}
		messageCount++
		if messageCount > maxSignalMessages {
			h.logSignalFailure(
				metadata, SignalFrame{}, len(data), "signal_rate_limited",
				"信令发送速率超过限制", nil,
			)
			_ = connection.Close(websocket.StatusPolicyViolation, "信令发送速率过高")
			return
		}
		frame, validationError := decodeSignalFrame(data, now)
		if validationError != nil {
			h.logSignalFailure(
				metadata, frame, len(data), validationError.code,
				validationError.message, validationError,
			)
			_ = connection.Close(websocket.StatusUnsupportedData, validationError.message)
			return
		}
		if routeError := route(frame, len(data)); routeError != nil {
			failureCode := "signal_route_failed"
			closeReason := "信令路由失败"
			var typedRouteError *SignalRouteError
			if errors.As(routeError, &typedRouteError) {
				failureCode = typedRouteError.Code
				closeReason = typedRouteError.Message
			}
			h.logSignalFailure(
				metadata, frame, len(data), failureCode,
				closeReason, routeError,
			)
			_ = connection.Close(websocket.StatusUnsupportedData, closeReason)
			return
		}
	}
}

func decodeSignalFrame(data []byte, now time.Time) (SignalFrame, *signalFrameValidationError) {
	var frame SignalFrame
	if err := json.Unmarshal(data, &frame); err != nil {
		return frame, &signalFrameValidationError{
			code: "signal_json_invalid", message: "信令消息 JSON 无效",
		}
	}
	if frame.ProtocolVersion != config.RelayProtocolVersion {
		return frame, &signalFrameValidationError{
			code: "signal_protocol_version_unsupported", message: "信令协议版本不受支持",
		}
	}
	if !relayRequestIDPattern.MatchString(frame.RequestID) {
		return frame, &signalFrameValidationError{
			code: "signal_request_id_invalid", message: "信令 requestId 无效",
		}
	}
	if frame.Timestamp <= 0 {
		return frame, &signalFrameValidationError{
			code: "signal_timestamp_invalid", message: "信令时间戳无效",
		}
	}
	difference := now.Sub(time.UnixMilli(frame.Timestamp))
	if difference < -relayClockSkew || difference > relayClockSkew {
		return frame, &signalFrameValidationError{
			code: "signal_timestamp_out_of_range", message: "信令时间戳超出允许范围",
		}
	}
	if !json.Valid(frame.Payload) {
		return frame, &signalFrameValidationError{
			code: "signal_payload_invalid", message: "信令 payload 不是有效 JSON",
		}
	}
	return frame, nil
}

func (h *Handler) logSignalReadFailure(metadata signalConnectionMetadata, err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	status := websocket.CloseStatus(err)
	if status == websocket.StatusNormalClosure || status == websocket.StatusGoingAway {
		return
	}
	h.logger.Warn(
		"Relay 信令读取失败",
		"component", "relay-signaling",
		"event", "relay.signal_read_failed",
		"role", metadata.role,
		"tunnelId", metadata.tunnelID,
		"peerId", metadata.peerID,
		"clientIp", metadata.clientIP,
		"connectionRequestId", metadata.connectionRequestID,
		"closeStatus", int(status),
		"error", err,
	)
}

func (h *Handler) logSignalFailure(
	metadata signalConnectionMetadata,
	frame SignalFrame,
	messageBytes int,
	failureCode string,
	message string,
	err error,
) {
	frameRequestID := ""
	if frame.RequestID != "" && relayRequestIDPattern.MatchString(frame.RequestID) {
		frameRequestID = frame.RequestID
	} else if frame.RequestID != "" {
		frameRequestID = "[invalid redacted]"
	}
	attributes := []any{
		"component", "relay-signaling",
		"event", "relay.signal_rejected",
		"failureCode", failureCode,
		"message", message,
		"role", metadata.role,
		"tunnelId", metadata.tunnelID,
		"peerId", metadata.peerID,
		"targetPeerId", boundedSignalLogValue(frame.PeerID, 128),
		"clientIp", metadata.clientIP,
		"connectionRequestId", metadata.connectionRequestID,
		"frameType", boundedSignalLogValue(frame.Type, 64),
		"frameTypeLength", len(frame.Type),
		"frameProtocolVersion", boundedSignalLogValue(frame.ProtocolVersion, 32),
		"frameRequestId", frameRequestID,
		"frameRequestIdLength", len(frame.RequestID),
		"frameRequestIdIssue", signalRequestIDIssue(frame.RequestID),
		"frameTimestamp", frame.Timestamp,
		"messageBytes", messageBytes,
		"payloadBytes", len(frame.Payload),
	}
	if err != nil {
		attributes = append(attributes, "error", err)
	}
	h.logger.Warn("Relay 信令被拒绝", attributes...)
}

func boundedSignalLogValue(value string, maximumRunes int) string {
	runes := []rune(value)
	if len(runes) <= maximumRunes {
		return value
	}
	return string(runes[:maximumRunes]) + "[truncated]"
}

func signalRequestIDIssue(value string) string {
	if value == "" {
		return "empty"
	}
	if len(value) > 128 {
		return "too_long"
	}
	first := value[0]
	if !((first >= 'A' && first <= 'Z') ||
		(first >= 'a' && first <= 'z') ||
		(first >= '0' && first <= '9')) {
		return "first_character_not_alphanumeric"
	}
	if !relayRequestIDPattern.MatchString(value) {
		return "invalid_characters"
	}
	return ""
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
