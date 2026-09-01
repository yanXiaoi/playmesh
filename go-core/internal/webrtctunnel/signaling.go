package webrtctunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type iceServer = ICEServer

type signalFrame struct {
	Type            string          `json:"type"`
	ProtocolVersion string          `json:"protocolVersion"`
	Timestamp       int64           `json:"timestamp"`
	RequestID       string          `json:"requestId"`
	PeerID          string          `json:"peerId,omitempty"`
	Payload         json.RawMessage `json:"payload,omitempty"`
	Reason          string          `json:"reason,omitempty"`
}

const (
	relaySignalProtocolVersion = "4.0.0"
	relaySignalClockSkew       = 5 * time.Minute
)

type signalSocket struct {
	connection     *websocket.Conn
	writeMutex     sync.Mutex
	lastWriteType  string
	lastWriteBytes int
}

func dialSignal(
	ctx context.Context,
	serverBaseURL *url.URL,
	path string,
	query url.Values,
	headers http.Header,
) (*signalSocket, error) {
	endpoint := *serverBaseURL
	switch endpoint.Scheme {
	case "http":
		endpoint.Scheme = "ws"
	case "https":
		endpoint.Scheme = "wss"
	default:
		return nil, errors.New("WebRTC 信令服务器协议无效")
	}
	endpoint.Path = path
	endpoint.RawQuery = query.Encode()
	endpoint.Fragment = ""
	requestID, err := randomRelayRequestID()
	if err != nil {
		return nil, err
	}
	headers.Set("X-Playmesh-Relay-Version", relaySignalProtocolVersion)
	headers.Set("X-Playmesh-Request-ID", requestID)
	headers.Set("X-Playmesh-Timestamp", strconv.FormatInt(time.Now().UnixMilli(), 10))
	connection, response, err := websocket.Dial(ctx, endpoint.String(), &websocket.DialOptions{HTTPHeader: headers})
	if err != nil {
		if response != nil {
			body := []byte(nil)
			var bodyError error
			if response.Body != nil {
				body, bodyError = io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
				_ = response.Body.Close()
			}
			return nil, fmt.Errorf(
				"WebRTC 信令连接被服务器拒绝: status=%s body=%s bodyError=%v: %w",
				response.Status, body, bodyError, err,
			)
		}
		return nil, err
	}
	connection.SetReadLimit(256 * 1024)
	return &signalSocket{connection: connection}, nil
}

func (s *signalSocket) write(ctx context.Context, frame signalFrame) error {
	var err error
	frame, err = normalizeSignalFrame(frame)
	if err != nil {
		return err
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	s.writeMutex.Lock()
	defer s.writeMutex.Unlock()
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	err = s.connection.Write(writeCtx, websocket.MessageText, data)
	if err == nil {
		s.lastWriteType = frame.Type
		s.lastWriteBytes = len(data)
	}
	return err
}

func (s *signalSocket) read(ctx context.Context) (signalFrame, error) {
	_, data, err := s.connection.Read(ctx)
	if err != nil {
		s.writeMutex.Lock()
		lastWriteType := s.lastWriteType
		lastWriteBytes := s.lastWriteBytes
		s.writeMutex.Unlock()
		return signalFrame{}, fmt.Errorf(
			"读取 WebRTC 信令失败（lastSentType=%s lastSentBytes=%d）: %w",
			lastWriteType,
			lastWriteBytes,
			err,
		)
	}
	var frame signalFrame
	if json.Unmarshal(data, &frame) != nil {
		return signalFrame{}, errors.New("WebRTC 信令消息无效")
	}
	difference := time.Since(time.UnixMilli(frame.Timestamp))
	if strings.TrimSpace(frame.Type) == "" ||
		frame.ProtocolVersion != relaySignalProtocolVersion || frame.Timestamp <= 0 ||
		strings.TrimSpace(frame.RequestID) == "" ||
		difference < -relaySignalClockSkew || difference > relaySignalClockSkew {
		return signalFrame{}, errors.New("WebRTC 信令消息无效")
	}
	return frame, nil
}

func normalizeSignalFrame(frame signalFrame) (signalFrame, error) {
	if frame.ProtocolVersion == "" {
		frame.ProtocolVersion = relaySignalProtocolVersion
	}
	if frame.Timestamp == 0 {
		frame.Timestamp = time.Now().UnixMilli()
	}
	if frame.RequestID == "" {
		requestID, err := randomRelayRequestID()
		if err != nil {
			return signalFrame{}, err
		}
		frame.RequestID = requestID
	}
	return frame, nil
}

func (s *signalSocket) close(reason string) {
	_ = s.connection.Close(websocket.StatusNormalClosure, reason)
}
