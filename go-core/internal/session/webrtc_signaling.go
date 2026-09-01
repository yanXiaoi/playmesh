package session

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	webRTCSignalingTicketTTL       = 30 * time.Second
	webRTCSignalingMaxMessageBytes = 64 * 1024
	webRTCSignalingMaxMessages     = 240
	webRTCSignalingRateWindow      = time.Second
	webRTCSignalingMaxPlayerSlots  = 32
	webRTCSignalingMaxTickets      = 4096
)

var webRTCSignalingIdentifierPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$`)

type webRTCSignalingBroker struct {
	handler *Handler

	mutex   sync.Mutex
	tickets map[[32]byte]webRTCSignalingTicket
	rooms   map[string]map[string]map[string]*webRTCSignalingPeer
}

type webRTCSignalingTicket struct {
	sessionID  string
	identifier string
	player     Player
	expiresAt  time.Time
}

type webRTCSignalingPeer struct {
	player Player
	conn   *websocket.Conn
	mutex  sync.Mutex
}

type webRTCSignalingEndpointRequest struct {
	Type       string `json:"type"`
	Version    int    `json:"version"`
	Timestamp  int64  `json:"timestamp"`
	RequestID  string `json:"requestId"`
	Identifier string `json:"identifier"`
}

type webRTCSignalingEndpointResponse struct {
	Type          string            `json:"type"`
	Version       int               `json:"version"`
	Timestamp     int64             `json:"timestamp"`
	RequestID     string            `json:"requestId"`
	Identifier    string            `json:"identifier"`
	WebSocketPath string            `json:"webSocketPath"`
	ExpiresAt     time.Time         `json:"expiresAt"`
	PlayerID      string            `json:"playerId"`
	Role          string            `json:"role"`
	ICEServers    []WebRTCICEServer `json:"iceServers"`
}

type webRTCSignalingClientFrame struct {
	Type           string          `json:"type"`
	Version        int             `json:"version"`
	Timestamp      int64           `json:"timestamp"`
	RequestID      string          `json:"requestId"`
	TargetPlayerID string          `json:"targetPlayerId,omitempty"`
	Payload        json.RawMessage `json:"payload"`
}

type webRTCSignalingServerFrame struct {
	Type           string          `json:"type"`
	Version        int             `json:"version"`
	Timestamp      int64           `json:"timestamp"`
	RequestID      string          `json:"requestId"`
	SenderPlayerID string          `json:"senderPlayerId,omitempty"`
	PlayerID       string          `json:"playerId,omitempty"`
	TargetPlayerID string          `json:"targetPlayerId,omitempty"`
	Payload        json.RawMessage `json:"payload,omitempty"`
}

func newWebRTCSignalingBroker(handler *Handler) *webRTCSignalingBroker {
	return &webRTCSignalingBroker{
		handler: handler,
		tickets: make(map[[32]byte]webRTCSignalingTicket),
		rooms:   make(map[string]map[string]map[string]*webRTCSignalingPeer),
	}
}

func (b *webRTCSignalingBroker) createEndpoint(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
) {
	_, player, err := b.handler.store.Authenticate(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	var body webRTCSignalingEndpointRequest
	if !decodeBody(writer, request, &body) {
		return
	}
	difference := time.Since(time.UnixMilli(body.Timestamp))
	if body.Type != "playmesh.webrtc-signaling-endpoint.request" || body.Version != 1 ||
		!webRTCSignalingIdentifierPattern.MatchString(body.RequestID) ||
		body.Timestamp <= 0 || difference < -5*time.Minute || difference > 5*time.Minute {
		writeError(writer, http.StatusBadRequest, "invalid_signaling_request", "信令端点请求元数据无效")
		return
	}
	if !webRTCSignalingIdentifierPattern.MatchString(body.Identifier) {
		writeError(writer, http.StatusBadRequest, "invalid_identifier", "identifier 必须是 1～128 位安全通道标识")
		return
	}
	if !b.handler.hasSessionPeer(sessionID, player.ID) {
		writeError(writer, http.StatusConflict, "session_connection_required", "主会话连接尚未建立")
		return
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		writeError(writer, http.StatusInternalServerError, "ticket_unavailable", "无法签发信令票据")
		return
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes)
	ticketHash := sha256.Sum256([]byte(token))
	expiresAt := time.Now().Add(webRTCSignalingTicketTTL).UTC()
	b.mutex.Lock()
	b.deleteExpiredTicketsLocked(time.Now())
	if len(b.tickets) >= webRTCSignalingMaxTickets ||
		b.playerSlotCountLocked(sessionID, player.ID) >= webRTCSignalingMaxPlayerSlots {
		b.mutex.Unlock()
		writeError(writer, http.StatusTooManyRequests, "signaling_limit", "当前玩家的 WebRTC 信令端点过多")
		return
	}
	b.tickets[ticketHash] = webRTCSignalingTicket{
		sessionID: sessionID, identifier: body.Identifier,
		player: player, expiresAt: expiresAt,
	}
	b.mutex.Unlock()
	iceServers := []WebRTCICEServer{}
	if b.handler.webRTCICEServerProvider != nil {
		iceServers = b.handler.webRTCICEServerProvider(sessionID, player.ID, body.Identifier)
		if iceServers == nil {
			iceServers = []WebRTCICEServer{}
		}
	}
	writeJSON(writer, http.StatusCreated, webRTCSignalingEndpointResponse{
		Type: "playmesh.webrtc-signaling-endpoint", Version: 1,
		Timestamp: time.Now().UnixMilli(), RequestID: body.RequestID,
		Identifier:    body.Identifier,
		WebSocketPath: "/v1/sessions/" + sessionID + "/webrtc/signaling?ticket=" + token,
		ExpiresAt:     expiresAt, PlayerID: player.ID, Role: player.Role,
		ICEServers: iceServers,
	})
}

func (b *webRTCSignalingBroker) connect(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
) {
	ticket, err := b.consumeTicket(sessionID, request.URL.Query().Get("ticket"))
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "invalid_signaling_ticket", err.Error())
		return
	}
	if !b.handler.hasSessionPeer(sessionID, ticket.player.ID) {
		writeError(writer, http.StatusConflict, "session_connection_required", "主会话连接已关闭")
		return
	}
	connection, err := websocket.Accept(
		writer,
		request,
		&websocket.AcceptOptions{InsecureSkipVerify: true},
	)
	if err != nil {
		return
	}
	connection.SetReadLimit(webRTCSignalingMaxMessageBytes)
	peer := &webRTCSignalingPeer{player: ticket.player, conn: connection}
	b.addPeer(sessionID, ticket.identifier, peer)
	defer func() {
		b.removePeer(sessionID, ticket.identifier, ticket.player.ID, peer)
		_ = connection.Close(websocket.StatusNormalClosure, "信令通道已关闭")
	}()
	b.readLoop(request.Context(), sessionID, ticket.identifier, peer)
}

func (b *webRTCSignalingBroker) consumeTicket(
	sessionID string,
	token string,
) (webRTCSignalingTicket, error) {
	if len(token) != 43 {
		return webRTCSignalingTicket{}, errors.New("信令票据无效或已过期")
	}
	hash := sha256.Sum256([]byte(token))
	now := time.Now()
	b.mutex.Lock()
	defer b.mutex.Unlock()
	b.deleteExpiredTicketsLocked(now)
	ticket, ok := b.tickets[hash]
	delete(b.tickets, hash)
	if !ok || ticket.sessionID != sessionID || now.After(ticket.expiresAt) {
		return webRTCSignalingTicket{}, errors.New("信令票据无效或已过期")
	}
	return ticket, nil
}

func (b *webRTCSignalingBroker) deleteExpiredTicketsLocked(now time.Time) {
	for hash, ticket := range b.tickets {
		if now.After(ticket.expiresAt) {
			delete(b.tickets, hash)
		}
	}
}

func (b *webRTCSignalingBroker) playerSlotCountLocked(sessionID string, playerID string) int {
	count := 0
	for _, ticket := range b.tickets {
		if ticket.sessionID == sessionID && ticket.player.ID == playerID {
			count++
		}
	}
	for _, channel := range b.rooms[sessionID] {
		if channel[playerID] != nil {
			count++
		}
	}
	return count
}

func (b *webRTCSignalingBroker) readLoop(
	ctx context.Context,
	sessionID string,
	identifier string,
	peer *webRTCSignalingPeer,
) {
	windowStarted := time.Now()
	messagesInWindow := 0
	for {
		_, data, err := peer.conn.Read(ctx)
		if err != nil {
			return
		}
		now := time.Now()
		if now.Sub(windowStarted) >= webRTCSignalingRateWindow {
			windowStarted, messagesInWindow = now, 0
		}
		messagesInWindow++
		if messagesInWindow > webRTCSignalingMaxMessages {
			_ = peer.conn.Close(websocket.StatusPolicyViolation, "信令发送速率过高")
			return
		}
		var frame webRTCSignalingClientFrame
		if json.Unmarshal(data, &frame) != nil ||
			frame.Type != "signal" || frame.Version != 1 ||
			!webRTCSignalingIdentifierPattern.MatchString(frame.RequestID) ||
			frame.Timestamp <= 0 || time.Since(time.UnixMilli(frame.Timestamp)) < -5*time.Minute ||
			time.Since(time.UnixMilli(frame.Timestamp)) > 5*time.Minute || len(frame.Payload) == 0 ||
			!json.Valid(frame.Payload) {
			_ = peer.conn.Close(websocket.StatusUnsupportedData, "信令消息格式无效")
			return
		}
		target, valid := b.resolveTarget(sessionID, identifier, peer.player, frame.TargetPlayerID)
		if !valid {
			_ = peer.conn.Close(websocket.StatusPolicyViolation, "信令目标无效")
			return
		}
		if target == nil {
			b.write(peer, webRTCSignalingServerFrame{
				Type: "delivery.error", RequestID: frame.RequestID,
				TargetPlayerID: frame.TargetPlayerID,
			})
			continue
		}
		b.write(target, webRTCSignalingServerFrame{
			Type: "signal", RequestID: frame.RequestID,
			SenderPlayerID: peer.player.ID, Payload: frame.Payload,
		})
	}
}

func (b *webRTCSignalingBroker) resolveTarget(
	sessionID string,
	identifier string,
	sender Player,
	requested string,
) (*webRTCSignalingPeer, bool) {
	record, err := b.handler.store.get(sessionID)
	if err != nil {
		return nil, false
	}
	snapshot := record.snapshot()
	targetID := requested
	if sender.ID != snapshot.AuthorityClientID {
		if targetID != "" && targetID != snapshot.AuthorityClientID {
			return nil, false
		}
		targetID = snapshot.AuthorityClientID
	} else if targetID == "" || targetID == sender.ID {
		return nil, false
	}
	b.mutex.Lock()
	target := b.rooms[sessionID][identifier][targetID]
	b.mutex.Unlock()
	return target, true
}

func (b *webRTCSignalingBroker) addPeer(
	sessionID string,
	identifier string,
	peer *webRTCSignalingPeer,
) {
	b.mutex.Lock()
	if b.rooms[sessionID] == nil {
		b.rooms[sessionID] = make(map[string]map[string]*webRTCSignalingPeer)
	}
	if b.rooms[sessionID][identifier] == nil {
		b.rooms[sessionID][identifier] = make(map[string]*webRTCSignalingPeer)
	}
	previous := b.rooms[sessionID][identifier][peer.player.ID]
	b.rooms[sessionID][identifier][peer.player.ID] = peer
	record, _ := b.handler.store.get(sessionID)
	authorityID := ""
	if record != nil {
		authorityID = record.snapshot().AuthorityClientID
	}
	others := make([]*webRTCSignalingPeer, 0, len(b.rooms[sessionID][identifier]))
	for playerID, other := range b.rooms[sessionID][identifier] {
		if playerID != peer.player.ID &&
			(peer.player.ID == authorityID || playerID == authorityID) {
			others = append(others, other)
		}
	}
	b.mutex.Unlock()
	if previous != nil {
		_ = previous.conn.Close(websocket.StatusPolicyViolation, "信令连接已被替换")
	}
	for _, other := range others {
		b.write(other, webRTCSignalingServerFrame{Type: "peer.joined", PlayerID: peer.player.ID})
		b.write(peer, webRTCSignalingServerFrame{Type: "peer.joined", PlayerID: other.player.ID})
	}
}

func (b *webRTCSignalingBroker) removePeer(
	sessionID string,
	identifier string,
	playerID string,
	peer *webRTCSignalingPeer,
) {
	b.mutex.Lock()
	channel := b.rooms[sessionID][identifier]
	if channel[playerID] != peer {
		b.mutex.Unlock()
		return
	}
	delete(channel, playerID)
	others := make([]*webRTCSignalingPeer, 0, len(channel))
	for _, other := range channel {
		others = append(others, other)
	}
	if len(channel) == 0 {
		delete(b.rooms[sessionID], identifier)
	}
	if len(b.rooms[sessionID]) == 0 {
		delete(b.rooms, sessionID)
	}
	b.mutex.Unlock()
	for _, other := range others {
		b.write(other, webRTCSignalingServerFrame{Type: "peer.left", PlayerID: playerID})
	}
}

func (b *webRTCSignalingBroker) disconnectPlayer(sessionID, playerID, reason string) {
	b.mutex.Lock()
	peers := make([]*webRTCSignalingPeer, 0)
	for _, channel := range b.rooms[sessionID] {
		if peer := channel[playerID]; peer != nil {
			peers = append(peers, peer)
		}
	}
	b.mutex.Unlock()
	for _, peer := range peers {
		_ = peer.conn.Close(websocket.StatusNormalClosure, reason)
	}
}

func (b *webRTCSignalingBroker) disconnectSession(sessionID, reason string) {
	b.mutex.Lock()
	peers := make([]*webRTCSignalingPeer, 0)
	for _, channel := range b.rooms[sessionID] {
		for _, peer := range channel {
			peers = append(peers, peer)
		}
	}
	for hash, ticket := range b.tickets {
		if ticket.sessionID == sessionID {
			delete(b.tickets, hash)
		}
	}
	b.mutex.Unlock()
	for _, peer := range peers {
		_ = peer.conn.Close(websocket.StatusNormalClosure, reason)
	}
}

func (b *webRTCSignalingBroker) write(peer *webRTCSignalingPeer, frame webRTCSignalingServerFrame) {
	frame.Version = 1
	frame.Timestamp = time.Now().UnixMilli()
	if frame.RequestID == "" {
		frame.RequestID = newWebRTCSignalingRequestID()
	}
	peer.mutex.Lock()
	defer peer.mutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = wsjsonWrite(ctx, peer.conn, frame)
}

func newWebRTCSignalingRequestID() string {
	value := make([]byte, 12)
	if _, err := rand.Read(value); err == nil {
		return base64.RawURLEncoding.EncodeToString(value)
	}
	return "signal-" + time.Now().UTC().Format("20060102T150405.000000000")
}

func wsjsonWrite(ctx context.Context, connection *websocket.Conn, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return connection.Write(ctx, websocket.MessageText, data)
}

func (h *Handler) hasSessionPeer(sessionID, playerID string) bool {
	h.mutex.Lock()
	defer h.mutex.Unlock()
	return h.rooms[sessionID][playerID] != nil
}
