package health

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
	"unicode"
)

const protocolVersion = "1.5.0"

var fallbackRequestCounter atomic.Uint64

type Handler struct {
	checker Checker
	logger  *slog.Logger
	now     func() time.Time
}

type responseEnvelope struct {
	Type            string         `json:"type"`
	ProtocolVersion string         `json:"protocolVersion"`
	Timestamp       int64          `json:"timestamp"`
	RequestID       string         `json:"requestId"`
	Data            *Snapshot      `json:"data,omitempty"`
	Error           *responseError `json:"error,omitempty"`
}

type responseError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func NewHandler(checker Checker, logger *slog.Logger) *Handler {
	return &Handler{
		checker: checker,
		logger:  logger,
		now:     time.Now,
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	startedAt := h.now()
	requestID := normalizeRequestID(r.Header.Get("X-Request-ID"))
	w.Header().Set("X-Request-ID", requestID)

	if r.Method != http.MethodGet {
		h.writeError(
			w,
			http.StatusMethodNotAllowed,
			requestID,
			"method_not_allowed",
			"该接口只支持 GET 请求",
		)
		h.logRequest("warn", "core.health.rejected", requestID, startedAt, http.StatusMethodNotAllowed)
		return
	}

	snapshot, err := h.checker.Check(r.Context())
	if err != nil {
		h.writeError(
			w,
			http.StatusServiceUnavailable,
			requestID,
			"health_unavailable",
			"Go Core 暂时不可用",
		)
		h.logger.Error(
			"健康检查失败",
			"component", "health-handler",
			"event", "core.health.failed",
			"requestId", requestID,
			"statusCode", http.StatusServiceUnavailable,
			"durationMs", h.now().Sub(startedAt).Milliseconds(),
			"error", err,
		)
		return
	}

	h.writeJSON(w, http.StatusOK, responseEnvelope{
		Type:            "core.health",
		ProtocolVersion: protocolVersion,
		Timestamp:       h.now().UnixMilli(),
		RequestID:       requestID,
		Data:            &snapshot,
	})
	h.logRequest("info", "core.health.succeeded", requestID, startedAt, http.StatusOK)
}

func (h *Handler) writeError(
	w http.ResponseWriter,
	statusCode int,
	requestID string,
	code string,
	message string,
) {
	h.writeJSON(w, statusCode, responseEnvelope{
		Type:            "core.error",
		ProtocolVersion: protocolVersion,
		Timestamp:       h.now().UnixMilli(),
		RequestID:       requestID,
		Error: &responseError{
			Code:    code,
			Message: message,
		},
	})
}

func (h *Handler) writeJSON(w http.ResponseWriter, statusCode int, response responseEnvelope) {
	payload, err := json.Marshal(response)
	if err != nil {
		h.logger.Error(
			"响应编码失败",
			"component", "health-handler",
			"event", "core.health.encode_failed",
			"requestId", response.RequestID,
			"error", err,
		)
		http.Error(w, "响应编码失败", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(statusCode)
	_, _ = w.Write(payload)
}

func (h *Handler) logRequest(
	level string,
	event string,
	requestID string,
	startedAt time.Time,
	statusCode int,
) {
	args := []any{
		"component", "health-handler",
		"event", event,
		"requestId", requestID,
		"statusCode", statusCode,
		"durationMs", h.now().Sub(startedAt).Milliseconds(),
	}

	if level == "warn" {
		h.logger.Warn("健康检查请求被拒绝", args...)
		return
	}

	h.logger.Info("健康检查成功", args...)
}

func normalizeRequestID(value string) string {
	value = strings.TrimSpace(value)
	if value != "" && len(value) <= 128 && isSafeRequestID(value) {
		return value
	}

	bytes := make([]byte, 12)
	if _, err := rand.Read(bytes); err == nil {
		return "req-" + hex.EncodeToString(bytes)
	}

	// 随机源异常时仍需生成可回溯 ID，避免请求失去关联信息。
	return fmt.Sprintf(
		"req-%d-%d",
		time.Now().UnixMilli(),
		fallbackRequestCounter.Add(1),
	)
}

func isSafeRequestID(value string) bool {
	for _, char := range value {
		if unicode.IsLetter(char) || unicode.IsDigit(char) {
			continue
		}
		if char != '-' && char != '_' && char != '.' {
			return false
		}
	}
	return true
}
