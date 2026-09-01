package webrtctunnel

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	maxControlBodySize     = 64 * 1024
	controlProtocolVersion = "1.0.0"
	controlClockSkew       = 5 * time.Minute
)

var controlRequestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)

type controlMetadata struct {
	requestID string
	timestamp int64
}

type Handler struct {
	service *Service
	logger  *slog.Logger
}

func NewHandler(service *Service, logger *slog.Logger) *Handler {
	return &Handler{service: service, logger: logger}
}

func (h *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	// 这些控制接口会接收服务端 Token 或完整邀请凭据，只允许原生宿主调用。
	// 游戏 HTML 的 fetch 会携带 Origin，不能借助宽松 CORS 读取或创建隧道。
	if strings.TrimSpace(request.Header.Get("Origin")) != "" {
		h.writeError(writer, controlMetadata{}, http.StatusForbidden, "native_host_required", "WebRTC 隧道控制接口只允许原生宿主调用")
		return
	}
	metadata, err := parseControlMetadata(request)
	if err != nil {
		h.writeError(writer, controlMetadata{}, http.StatusBadRequest, "invalid_control_metadata", err.Error())
		return
	}
	writeControlHeaders(writer, metadata)
	path := strings.TrimPrefix(request.URL.Path, "/v1/relay/")
	segments := strings.Split(strings.Trim(path, "/"), "/")
	if len(segments) == 1 && request.Method == http.MethodPost {
		switch segments[0] {
		case "host":
			h.createHost(writer, request, metadata)
			return
		case "client":
			h.createClient(writer, request, metadata)
			return
		}
	}
	if len(segments) == 2 {
		kind, id := segments[0], segments[1]
		switch request.Method {
		case http.MethodGet:
			h.get(writer, kind, id, metadata)
			return
		case http.MethodDelete:
			h.delete(writer, kind, id, metadata)
			return
		}
	}
	h.writeError(writer, metadata, http.StatusNotFound, "not_found", "WebRTC 隧道控制接口不存在")
}

func (h *Handler) createHost(writer http.ResponseWriter, request *http.Request, metadata controlMetadata) {
	var body HostRequest
	if err := decodeControlBody(writer, request, &body); err != nil {
		h.writeError(writer, metadata, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	snapshot, err := h.service.CreateHost(request.Context(), body)
	h.writeResult(writer, metadata, snapshot, err, http.StatusCreated)
}

func (h *Handler) createClient(writer http.ResponseWriter, request *http.Request, metadata controlMetadata) {
	var body ClientRequest
	if err := decodeControlBody(writer, request, &body); err != nil {
		h.writeError(writer, metadata, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	snapshot, err := h.service.CreateClient(request.Context(), body)
	h.writeResult(writer, metadata, snapshot, err, http.StatusCreated)
}

func (h *Handler) get(writer http.ResponseWriter, kind, id string, metadata controlMetadata) {
	var snapshot SessionSnapshot
	var err error
	switch kind {
	case "host":
		snapshot, err = h.service.Host(id)
	case "client":
		snapshot, err = h.service.Client(id)
	default:
		err = ErrSessionNotFound
	}
	h.writeResult(writer, metadata, snapshot, err, http.StatusOK)
}

func (h *Handler) delete(writer http.ResponseWriter, kind, id string, metadata controlMetadata) {
	var err error
	switch kind {
	case "host":
		err = h.service.DeleteHost(id)
	case "client":
		err = h.service.DeleteClient(id)
	default:
		err = ErrSessionNotFound
	}
	if err != nil {
		h.writeResult(writer, metadata, SessionSnapshot{}, err, http.StatusNoContent)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (h *Handler) writeResult(writer http.ResponseWriter, metadata controlMetadata, snapshot SessionSnapshot, err error, successStatus int) {
	if err == nil {
		snapshot.Type = "playmesh.webrtc-tunnel.snapshot"
		snapshot.ProtocolVersion = controlProtocolVersion
		snapshot.Timestamp = time.Now().UnixMilli()
		snapshot.RequestID = metadata.requestID
		writer.WriteHeader(successStatus)
		_ = json.NewEncoder(writer).Encode(snapshot)
		return
	}
	if errors.Is(err, ErrSessionNotFound) {
		h.writeError(writer, metadata, http.StatusNotFound, "session_not_found", err.Error())
		return
	}
	h.logger.Warn(
		"WebRTC 隧道控制操作失败",
		"component", "webrtc-tunnel",
		"requestId", metadata.requestID,
		"error", err,
	)
	h.writeError(writer, metadata, http.StatusBadGateway, "webrtc_tunnel_failed", err.Error())
}

func (h *Handler) writeError(writer http.ResponseWriter, metadata controlMetadata, status int, code, message string) {
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(map[string]any{
		"type": "playmesh.webrtc-tunnel.error", "protocolVersion": controlProtocolVersion,
		"timestamp": time.Now().UnixMilli(), "requestId": metadata.requestID,
		"error": code, "message": message,
	})
}

func parseControlMetadata(request *http.Request) (controlMetadata, error) {
	if request.Header.Get("X-Playmesh-Control-Version") != controlProtocolVersion {
		return controlMetadata{}, errors.New("WebRTC 隧道控制协议版本不受支持")
	}
	requestID := strings.TrimSpace(request.Header.Get("X-Playmesh-Request-ID"))
	if !controlRequestIDPattern.MatchString(requestID) {
		return controlMetadata{}, errors.New("WebRTC 隧道 requestId 无效")
	}
	timestamp, err := strconv.ParseInt(request.Header.Get("X-Playmesh-Timestamp"), 10, 64)
	if err != nil {
		return controlMetadata{}, errors.New("WebRTC 隧道时间戳无效")
	}
	difference := time.Since(time.UnixMilli(timestamp))
	if difference < -controlClockSkew || difference > controlClockSkew {
		return controlMetadata{}, errors.New("WebRTC 隧道时间戳已过期")
	}
	return controlMetadata{requestID: requestID, timestamp: timestamp}, nil
}

func writeControlHeaders(writer http.ResponseWriter, metadata controlMetadata) {
	writer.Header().Set("X-Playmesh-Control-Version", controlProtocolVersion)
	writer.Header().Set("X-Playmesh-Request-ID", metadata.requestID)
	writer.Header().Set("X-Playmesh-Timestamp", strconv.FormatInt(time.Now().UnixMilli(), 10))
}

func decodeControlBody(writer http.ResponseWriter, request *http.Request, target any) error {
	request.Body = http.MaxBytesReader(writer, request.Body, maxControlBodySize)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return errors.New("请求 JSON 无效")
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("请求 JSON 只能包含一个对象")
	}
	return nil
}
