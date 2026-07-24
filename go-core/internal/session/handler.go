package session

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const maxMessageBytes = 64 * 1024

type Handler struct {
	store  *Store
	logger *slog.Logger
	mutex  sync.Mutex
	rooms  map[string]map[string]*peer
	binary *binaryHub
}

type peer struct {
	player Player
	conn   *websocket.Conn
	mutex  sync.Mutex
}

type clientMessage struct {
	Type            string          `json:"type"`
	Sequence        uint64          `json:"sequence"`
	TargetPlayerIDs []string        `json:"targetPlayerIds"`
	Payload         json.RawMessage `json:"payload"`
}

type serverMessage struct {
	Type           string          `json:"type"`
	Sequence       uint64          `json:"sequence,omitempty"`
	SenderPlayerID string          `json:"senderPlayerId,omitempty"`
	Payload        json.RawMessage `json:"payload,omitempty"`
	Session        *Snapshot       `json:"session,omitempty"`
}

type sessionResponse struct {
	Session         Snapshot    `json:"session"`
	Credential      Credentials `json:"credential"`
	WebSocket       string      `json:"webSocketPath"`
	BinaryWebSocket string      `json:"binaryWebSocketPath"`
}

func NewHandler(store *Store, logger *slog.Logger) *Handler {
	return &Handler{
		store: store, logger: logger, rooms: make(map[string]map[string]*peer),
		binary: newBinaryHub(logger),
	}
}

func (h *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	path := strings.TrimPrefix(request.URL.Path, "/v1/sessions")
	switch {
	case path == "" && request.Method == http.MethodPost:
		h.create(writer, request)
	case path == "/join" && request.Method == http.MethodPost:
		h.join(writer, request)
	case strings.HasSuffix(path, "/start") && request.Method == http.MethodPost:
		h.start(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/start"))
	case strings.HasSuffix(path, "/reset") && request.Method == http.MethodPost:
		h.reset(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/reset"))
	case strings.HasSuffix(path, "/finish") && request.Method == http.MethodPost:
		h.finish(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/finish"))
	case strings.HasSuffix(path, "/players/me") && request.Method == http.MethodPatch:
		h.updateNickname(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/players/me"))
	case strings.HasSuffix(path, "/share") && request.Method == http.MethodPost:
		h.openShare(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/share"))
	case strings.HasSuffix(path, "/share") && request.Method == http.MethodDelete:
		h.closeShare(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/share"))
	case strings.HasSuffix(path, "/ws") && request.Method == http.MethodGet:
		h.connect(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/ws"))
	case strings.HasSuffix(path, "/binary") && request.Method == http.MethodGet:
		h.connectBinary(writer, request, strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/binary"))
	case strings.HasPrefix(path, "/") && request.Method == http.MethodGet:
		h.snapshot(writer, request, strings.TrimPrefix(path, "/"))
	default:
		writeError(writer, http.StatusNotFound, "route_not_found", "会话接口不存在")
	}
}

func (h *Handler) create(writer http.ResponseWriter, request *http.Request) {
	var body struct {
		GameID      string `json:"gameId"`
		DisplayMode string `json:"displayMode"`
		MinPlayers  int    `json:"minPlayers"`
		MaxPlayers  int    `json:"maxPlayers"`
		Nickname    string `json:"nickname"`
	}
	if !decodeBody(writer, request, &body) {
		return
	}
	snapshot, credential, err := h.store.Create(CreateInput{
		GameID: body.GameID, DisplayMode: body.DisplayMode, MinPlayers: body.MinPlayers,
		MaxPlayers: body.MaxPlayers, Nickname: body.Nickname,
	})
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusCreated, sessionResponse{
		Session: snapshot, Credential: credential,
		WebSocket:       "/v1/sessions/" + snapshot.ID + "/ws",
		BinaryWebSocket: "/v1/sessions/" + snapshot.ID + "/binary",
	})
}

func (h *Handler) join(writer http.ResponseWriter, request *http.Request) {
	var body struct {
		JoinCode   string `json:"joinCode"`
		Nickname   string `json:"nickname"`
		ShareToken string `json:"shareToken"`
		PlayerID   string `json:"playerId"`
	}
	if !decodeBody(writer, request, &body) {
		return
	}
	snapshot, credential, err := h.store.Join(JoinInput{
		JoinCode: body.JoinCode, Nickname: body.Nickname,
		ShareToken: body.ShareToken, PlayerID: body.PlayerID,
	})
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, sessionResponse{
		Session: snapshot, Credential: credential,
		WebSocket:       "/v1/sessions/" + snapshot.ID + "/ws",
		BinaryWebSocket: "/v1/sessions/" + snapshot.ID + "/binary",
	})
	h.broadcast(snapshot.ID, serverMessage{Type: "session.state", Session: &snapshot})
}

func (h *Handler) openShare(writer http.ResponseWriter, request *http.Request, sessionID string) {
	grant, err := h.store.OpenShare(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusCreated, grant)
}

func (h *Handler) closeShare(writer http.ResponseWriter, request *http.Request, sessionID string) {
	if err := h.store.CloseShare(sessionID, bearerToken(request)); err != nil {
		writeStoreError(writer, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (h *Handler) start(writer http.ResponseWriter, request *http.Request, sessionID string) {
	snapshot, err := h.store.Start(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, snapshot)
	h.broadcast(snapshot.ID, serverMessage{Type: "session.state", Session: &snapshot})
}

func (h *Handler) reset(writer http.ResponseWriter, request *http.Request, sessionID string) {
	snapshot, err := h.store.Reset(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, snapshot)
	h.broadcast(snapshot.ID, serverMessage{Type: "session.state", Session: &snapshot})
}

func (h *Handler) finish(writer http.ResponseWriter, request *http.Request, sessionID string) {
	snapshot, err := h.store.Finish(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, snapshot)
	h.broadcast(snapshot.ID, serverMessage{Type: "session.state", Session: &snapshot})
}

func (h *Handler) updateNickname(writer http.ResponseWriter, request *http.Request, sessionID string) {
	var body struct {
		Nickname string `json:"nickname"`
	}
	if !decodeBody(writer, request, &body) {
		return
	}
	snapshot, player, err := h.store.UpdateNickname(sessionID, bearerToken(request), body.Nickname)
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, map[string]any{"session": snapshot, "player": player})
	h.broadcast(snapshot.ID, serverMessage{Type: "session.state", Session: &snapshot})
}

func (h *Handler) snapshot(writer http.ResponseWriter, request *http.Request, sessionID string) {
	snapshot, err := h.store.Snapshot(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, snapshot)
}

func (h *Handler) connect(writer http.ResponseWriter, request *http.Request, sessionID string) {
	record, player, err := h.store.Authenticate(sessionID, request.URL.Query().Get("token"))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	if player.Connected {
		writeStoreError(writer, ErrPlayerConnected)
		return
	}
	connection, err := websocket.Accept(writer, request, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		h.logger.Warn("WebSocket 握手失败", "event", "session.ws_rejected", "error", err)
		return
	}
	connection.SetReadLimit(maxMessageBytes)
	client := &peer{player: player, conn: connection}
	snapshot, connected := h.store.TryConnect(record, player.ID)
	if !connected {
		_ = connection.Close(websocket.StatusPolicyViolation, "玩家身份已有在线连接")
		return
	}
	h.addPeer(sessionID, client)
	h.broadcast(sessionID, serverMessage{Type: "session.state", Session: &snapshot})

	defer func() {
		if h.removePeer(sessionID, player.ID, client) {
			h.binary.disconnect(sessionID, player.ID)
			snapshot := h.store.SetConnected(record, player.ID, false)
			h.broadcast(sessionID, serverMessage{Type: "session.state", Session: &snapshot})
		}
		_ = connection.Close(websocket.StatusNormalClosure, "连接已关闭")
	}()
	h.readLoop(request.Context(), record, client)
}

func (h *Handler) readLoop(ctx context.Context, record *record, client *peer) {
	var lastSequence uint64
	windowStarted, messageCount := time.Now(), 0
	for {
		_, data, err := client.conn.Read(ctx)
		if err != nil {
			return
		}
		if time.Since(windowStarted) >= time.Second {
			windowStarted, messageCount = time.Now(), 0
		}
		messageCount++
		if messageCount > 30 {
			_ = client.conn.Close(websocket.StatusPolicyViolation, "消息频率过高")
			return
		}

		var message clientMessage
		if json.Unmarshal(data, &message) != nil || message.Sequence <= lastSequence {
			_ = client.conn.Close(websocket.StatusPolicyViolation, "消息格式或序号无效")
			return
		}
		lastSequence = message.Sequence
		snapshot := record.snapshot()
		switch message.Type {
		case "session.ping":
			var probe map[string]any
			if json.Unmarshal(message.Payload, &probe) != nil {
				_ = client.conn.Close(websocket.StatusUnsupportedData, "延迟探测格式无效")
				return
			}
			probe["serverReceivedAt"] = time.Now().UnixMilli()
			payload, err := json.Marshal(probe)
			if err != nil {
				return
			}
			if client.player.ID == snapshot.AuthorityClientID {
				probe["authorityAvailable"] = true
				probe["serverSentAt"] = time.Now().UnixMilli()
				payload, _ = json.Marshal(probe)
				h.send(snapshot.ID, client.player.ID, serverMessage{
					Type: "session.pong", Sequence: message.Sequence, Payload: payload,
				})
			} else if record.authorityConnected() {
				h.send(snapshot.ID, snapshot.AuthorityClientID, serverMessage{
					Type: "authority.ping", Sequence: message.Sequence,
					SenderPlayerID: client.player.ID, Payload: payload,
				})
			} else {
				probe["authorityAvailable"] = false
				probe["serverSentAt"] = time.Now().UnixMilli()
				payload, _ = json.Marshal(probe)
				h.send(snapshot.ID, client.player.ID, serverMessage{
					Type: "session.pong", Sequence: message.Sequence, Payload: payload,
				})
			}
		case "authority.pong":
			if client.player.ID != snapshot.AuthorityClientID ||
				len(message.TargetPlayerIDs) != 1 ||
				!validTargets(snapshot, message.TargetPlayerIDs) {
				_ = client.conn.Close(websocket.StatusPolicyViolation, "延迟探测响应目标无效")
				return
			}
			var probe map[string]any
			if json.Unmarshal(message.Payload, &probe) != nil {
				_ = client.conn.Close(websocket.StatusUnsupportedData, "延迟探测响应格式无效")
				return
			}
			probe["authorityAvailable"] = true
			probe["serverSentAt"] = time.Now().UnixMilli()
			payload, _ := json.Marshal(probe)
			h.send(snapshot.ID, message.TargetPlayerIDs[0], serverMessage{
				Type: "session.pong", Sequence: message.Sequence, Payload: payload,
			})
		case "game.action":
			h.send(snapshot.ID, snapshot.AuthorityClientID, serverMessage{
				Type: "authority.action", Sequence: message.Sequence,
				SenderPlayerID: client.player.ID, Payload: message.Payload, Session: &snapshot,
			})
		case "authority.result":
			if client.player.ID != snapshot.AuthorityClientID || !validTargets(snapshot, message.TargetPlayerIDs) {
				_ = client.conn.Close(websocket.StatusPolicyViolation, "权威结果目标无效")
				return
			}
			outgoing := serverMessage{Type: "game.message", Sequence: message.Sequence,
				SenderPlayerID: client.player.ID, Payload: message.Payload}
			for _, target := range message.TargetPlayerIDs {
				h.send(snapshot.ID, target, outgoing)
			}
		default:
			_ = client.conn.Close(websocket.StatusUnsupportedData, "未知消息类型")
			return
		}
	}
}

func validTargets(snapshot Snapshot, targets []string) bool {
	if len(targets) == 0 || len(targets) > snapshot.MaxPlayers+1 {
		return false
	}
	seen := make(map[string]bool, len(targets))
	for _, target := range targets {
		if target == "" || seen[target] {
			return false
		}
		seen[target] = true
	}
	return true
}

func (h *Handler) addPeer(sessionID string, client *peer) {
	h.mutex.Lock()
	defer h.mutex.Unlock()
	if h.rooms[sessionID] == nil {
		h.rooms[sessionID] = make(map[string]*peer)
	}
	if previous := h.rooms[sessionID][client.player.ID]; previous != nil {
		_ = previous.conn.Close(websocket.StatusPolicyViolation, "玩家连接已被替换")
	}
	h.rooms[sessionID][client.player.ID] = client
}

func (h *Handler) removePeer(sessionID, playerID string, client *peer) bool {
	h.mutex.Lock()
	defer h.mutex.Unlock()
	if h.rooms[sessionID][playerID] == client {
		delete(h.rooms[sessionID], playerID)
		return true
	}
	return false
}

func (h *Handler) send(sessionID, playerID string, message serverMessage) {
	h.mutex.Lock()
	client := h.rooms[sessionID][playerID]
	h.mutex.Unlock()
	if client == nil {
		return
	}
	client.mutex.Lock()
	defer client.mutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	data, err := json.Marshal(message)
	if err == nil {
		err = client.conn.Write(ctx, websocket.MessageText, data)
	}
	if err != nil {
		h.logger.Debug("WebSocket 消息发送失败", "event", "session.ws_write_failed", "error", err)
	}
}

func (h *Handler) broadcast(sessionID string, message serverMessage) {
	h.mutex.Lock()
	ids := make([]string, 0, len(h.rooms[sessionID]))
	for id := range h.rooms[sessionID] {
		ids = append(ids, id)
	}
	h.mutex.Unlock()
	for _, id := range ids {
		h.send(sessionID, id, message)
	}
}

func decodeBody(writer http.ResponseWriter, request *http.Request, target any) bool {
	request.Body = http.MaxBytesReader(writer, request.Body, maxMessageBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_request", "请求格式无效")
		return false
	}
	return true
}

func bearerToken(request *http.Request) string {
	return strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer ")
}

func writeStoreError(writer http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrUnauthorized):
		writeError(writer, http.StatusUnauthorized, "unauthorized", err.Error())
	case errors.Is(err, ErrNotFound):
		writeError(writer, http.StatusNotFound, "session_not_found", err.Error())
	case errors.Is(err, ErrPlayerConnected):
		writeError(writer, http.StatusConflict, "player_connected", err.Error())
	case errors.Is(err, ErrSessionFull), errors.Is(err, ErrSessionStarted),
		errors.Is(err, ErrTooFewPlayers), errors.Is(err, ErrNotAuthority):
		writeError(writer, http.StatusConflict, "session_conflict", err.Error())
	default:
		writeError(writer, http.StatusBadRequest, "invalid_request", err.Error())
	}
}

func writeError(writer http.ResponseWriter, status int, code, message string) {
	writeJSON(writer, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
