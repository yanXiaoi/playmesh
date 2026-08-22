package session

import (
	"container/list"
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	maxBinaryFrameBytes          = 4 * 1024 * 1024
	maxBinaryFramesPerSecond     = 2000
	maxBinaryBytesPerSecond      = 64 * 1024 * 1024
	maxBinaryQueuedBytes         = 32 * 1024 * 1024
	maxBinaryChannels            = 1024
	maxBinaryPendingReviews      = 1024
	maxBinaryPendingBytes        = 128 * 1024 * 1024
	maxBinaryPendingRPC          = 256
	maxBinaryPendingRPCPerPlayer = 32
	maxBinaryPendingRPCBytes     = 32 * 1024 * 1024
	minBinaryRPCTimeout          = 100 * time.Millisecond
	maxBinaryRPCTimeout          = 60 * time.Second
	binaryAuthorityTimeout       = 15 * time.Second
	binaryWriteTimeout           = 5 * time.Second
)

var (
	errBinaryPrimaryOffline     = errors.New("主会话连接尚未建立")
	errBinaryChannelNotFound    = errors.New("二进制 Channel 不存在")
	errBinaryChannelLimit       = errors.New("二进制 Channel 数量达到上限")
	errBinaryNotJoined          = errors.New("当前玩家尚未加入二进制 Channel")
	errBinaryTargetNotJoined    = errors.New("目标玩家尚未加入二进制 Channel")
	errBinaryTargetOffline      = errors.New("目标玩家二进制连接不在线")
	errBinaryAuthorityOffline   = errors.New("Authority 二进制连接不在线")
	errBinaryAuthorityNotJoined = errors.New("Authority 尚未加入二进制 Channel")
	errBinaryReviewLimit        = errors.New("Authority 待审核二进制消息达到上限")
	errBinaryReviewBytes        = errors.New("Authority 待审核二进制数据达到上限")
	errBinarySendQueueFull      = errors.New("目标玩家二进制发送队列已满")
	errBinaryAuthorityOnly      = errors.New("只有 Authority 可以创建或关闭二进制 Channel")
	errBinaryReviewExpired      = errors.New("Authority 二进制审核超时")
)

const (
	binaryRPCCodeAuthorityOffline = "rpc_authority_offline"
	binaryRPCCodeBusy             = "rpc_busy"
	binaryRPCCodeDuplicate        = "rpc_duplicate_request"
	binaryRPCCodeInvalidRequest   = "rpc_request_invalid"
	binaryRPCCodePayloadTooLarge  = "rpc_payload_too_large"
	binaryRPCCodeTimeout          = "rpc_timeout"
)

type binaryLatestKey struct {
	kind      byte
	channelID binaryChannelID
	senderID  string
	targetID  string
}

type binaryQueuedFrame struct {
	data      []byte
	latestKey *binaryLatestKey
}

type binarySendQueue struct {
	mutex       sync.Mutex
	ready       *sync.Cond
	messages    *list.List
	latest      map[binaryLatestKey]*list.Element
	queuedBytes int
	closed      bool
}

func newBinarySendQueue() *binarySendQueue {
	queue := &binarySendQueue{
		messages: list.New(),
		latest:   make(map[binaryLatestKey]*list.Element),
	}
	queue.ready = sync.NewCond(&queue.mutex)
	return queue
}

func (q *binarySendQueue) push(frame binaryQueuedFrame) error {
	_, err := q.pushWithReplacement(frame)
	return err
}

func (q *binarySendQueue) pushWithReplacement(
	frame binaryQueuedFrame,
) (bool, error) {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	if q.closed {
		return false, errBinaryTargetOffline
	}
	var previous *list.Element
	if frame.latestKey != nil {
		previous = q.latest[*frame.latestKey]
	}
	nextBytes := q.queuedBytes + len(frame.data)
	if previous != nil {
		nextBytes -= len(previous.Value.(binaryQueuedFrame).data)
	}
	if nextBytes > maxBinaryQueuedBytes {
		return false, errBinarySendQueueFull
	}
	if previous != nil {
		q.messages.Remove(previous)
	}
	element := q.messages.PushBack(frame)
	if frame.latestKey != nil {
		q.latest[*frame.latestKey] = element
	}
	q.queuedBytes = nextBytes
	q.ready.Signal()
	return previous != nil, nil
}

func (q *binarySendQueue) pop() (binaryQueuedFrame, bool) {
	q.mutex.Lock()
	defer q.mutex.Unlock()
	for q.messages.Len() == 0 && !q.closed {
		q.ready.Wait()
	}
	if q.messages.Len() == 0 {
		return binaryQueuedFrame{}, false
	}
	element := q.messages.Front()
	frame := element.Value.(binaryQueuedFrame)
	q.messages.Remove(element)
	q.queuedBytes -= len(frame.data)
	if frame.latestKey != nil && q.latest[*frame.latestKey] == element {
		delete(q.latest, *frame.latestKey)
	}
	return frame, true
}

func (q *binarySendQueue) close() {
	q.mutex.Lock()
	q.closed = true
	q.messages.Init()
	clear(q.latest)
	q.queuedBytes = 0
	q.ready.Broadcast()
	q.mutex.Unlock()
}

type binaryPeer struct {
	sessionID string
	player    Player
	conn      *websocket.Conn
	queue     *binarySendQueue
	closeOnce sync.Once
}

func newBinaryPeer(sessionID string, player Player, conn *websocket.Conn) *binaryPeer {
	return &binaryPeer{
		sessionID: sessionID,
		player:    player,
		conn:      conn,
		queue:     newBinarySendQueue(),
	}
}

func (p *binaryPeer) enqueue(data []byte, latestKey *binaryLatestKey) error {
	return p.queue.push(binaryQueuedFrame{data: data, latestKey: latestKey})
}

func (p *binaryPeer) enqueueReview(
	data []byte,
	latestKey *binaryLatestKey,
) (bool, error) {
	return p.queue.pushWithReplacement(
		binaryQueuedFrame{data: data, latestKey: latestKey},
	)
}

func (p *binaryPeer) close(status websocket.StatusCode, reason string) {
	p.closeOnce.Do(func() {
		p.queue.close()
		_ = p.conn.Close(status, reason)
	})
}

func (p *binaryPeer) writeLoop(logger *slog.Logger) {
	for {
		frame, ok := p.queue.pop()
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), binaryWriteTimeout)
		err := p.conn.Write(ctx, websocket.MessageBinary, frame.data)
		cancel()
		if err != nil {
			logger.Debug(
				"Binary WebSocket 消息发送失败",
				"event", "session.binary_ws_write_failed",
				"sessionId", p.sessionID,
				"playerId", p.player.ID,
				"error", err,
			)
			p.close(websocket.StatusInternalError, "二进制发送失败")
			return
		}
	}
}

type binaryChannel struct {
	id      binaryChannelID
	mode    byte
	members map[string]bool
}

type binaryPendingReview struct {
	id        uint64
	requestID uint32
	channelID binaryChannelID
	senderID  string
	targetIDs []string
	flags     byte
	payload   []byte
	timer     *time.Timer
	latestKey *binaryLatestKey
}

type binaryRPCClientKey struct {
	senderID  string
	requestID uint32
}

type binaryPendingRPC struct {
	id           uint64
	requestID    uint32
	senderID     string
	payloadBytes int
	timer        *time.Timer
}

type binarySession struct {
	authorityID        string
	peers              map[string]*binaryPeer
	channels           map[binaryChannelID]*binaryChannel
	pending            map[uint64]*binaryPendingReview
	latestReview       map[binaryLatestKey]uint64
	pendingBytes       int
	nextReviewID       uint64
	pendingRPC         map[uint64]*binaryPendingRPC
	pendingRPCByClient map[binaryRPCClientKey]uint64
	pendingRPCByPlayer map[string]int
	pendingRPCBytes    int
	nextRPCID          uint64
}

type binaryHub struct {
	logger   *slog.Logger
	mutex    sync.Mutex
	sessions map[string]*binarySession
}

func newBinaryHub(logger *slog.Logger) *binaryHub {
	return &binaryHub{logger: logger, sessions: make(map[string]*binarySession)}
}

func (h *Handler) connectBinary(writer http.ResponseWriter, request *http.Request, sessionID string) {
	record, player, err := h.store.Authenticate(sessionID, request.URL.Query().Get("token"))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	if !h.hasPeer(sessionID, player.ID) {
		writeError(writer, http.StatusConflict, "primary_connection_required", errBinaryPrimaryOffline.Error())
		return
	}
	connection, err := websocket.Accept(writer, request, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		h.logger.Warn(
			"Binary WebSocket 握手失败",
			"event", "session.binary_ws_rejected",
			"sessionId", sessionID,
			"playerId", player.ID,
			"error", err,
		)
		return
	}
	connection.SetReadLimit(maxBinaryFrameBytes)
	peer := newBinaryPeer(sessionID, player, connection)
	h.binary.attach(sessionID, record.snapshot().AuthorityClientID, peer)
	go peer.writeLoop(h.logger)

	h.logger.Info(
		"Binary WebSocket 已连接",
		"event", "session.binary_ws_connected",
		"sessionId", sessionID,
		"playerId", player.ID,
	)
	defer func() {
		h.binary.detach(sessionID, peer)
		peer.close(websocket.StatusNormalClosure, "二进制连接已关闭")
		h.logger.Info(
			"Binary WebSocket 已断开",
			"event", "session.binary_ws_disconnected",
			"sessionId", sessionID,
			"playerId", player.ID,
		)
	}()
	h.binaryReadLoop(request.Context(), peer)
}

func (h *Handler) hasPeer(sessionID, playerID string) bool {
	h.mutex.Lock()
	defer h.mutex.Unlock()
	return h.rooms[sessionID][playerID] != nil
}

func (h *Handler) binaryReadLoop(ctx context.Context, peer *binaryPeer) {
	windowStarted := time.Now()
	frameCount, byteCount := 0, 0
	for {
		messageType, data, err := peer.conn.Read(ctx)
		if err != nil {
			return
		}
		if messageType != websocket.MessageBinary {
			peer.close(websocket.StatusUnsupportedData, "二进制连接只接受 binary frame")
			return
		}
		if time.Since(windowStarted) >= time.Second {
			windowStarted, frameCount, byteCount = time.Now(), 0, 0
		}
		frameCount++
		byteCount += len(data)
		if frameCount > maxBinaryFramesPerSecond || byteCount > maxBinaryBytesPerSecond {
			peer.close(websocket.StatusPolicyViolation, "二进制消息频率或流量过高")
			return
		}
		frame, err := decodeBinaryClientFrame(data)
		if err != nil || validateBinaryFlags(frame.flags) != nil {
			peer.close(websocket.StatusUnsupportedData, "二进制消息格式无效")
			return
		}
		h.binary.handle(peer, frame)
	}
}

func (b *binaryHub) attach(sessionID, authorityID string, peer *binaryPeer) {
	b.mutex.Lock()
	session := b.sessions[sessionID]
	if session == nil {
		session = &binarySession{
			authorityID:        authorityID,
			peers:              make(map[string]*binaryPeer),
			channels:           make(map[binaryChannelID]*binaryChannel),
			pending:            make(map[uint64]*binaryPendingReview),
			latestReview:       make(map[binaryLatestKey]uint64),
			pendingRPC:         make(map[uint64]*binaryPendingRPC),
			pendingRPCByClient: make(map[binaryRPCClientKey]uint64),
			pendingRPCByPlayer: make(map[string]int),
		}
		b.sessions[sessionID] = session
	}
	previous := session.peers[peer.player.ID]
	session.peers[peer.player.ID] = peer
	b.mutex.Unlock()
	if previous != nil && previous != peer {
		previous.close(websocket.StatusPolicyViolation, "二进制连接已被替换")
	}
}

func (b *binaryHub) detach(sessionID string, peer *binaryPeer) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil || session.peers[peer.player.ID] != peer {
		return
	}
	delete(session.peers, peer.player.ID)
	for _, channel := range session.channels {
		delete(channel.members, peer.player.ID)
	}
	if peer.player.ID == session.authorityID {
		// Binary 瞬断不代表游戏运行时退出。保留 Channel，让同一主会话下
		// 的 SDK 重连后通过 JOIN 恢复；未完成审核必须立即失败，不能等超时。
		b.cancelAllReviewsLocked(session, errBinaryAuthorityOffline)
		b.cancelAllRPCsLocked(
			session,
			binaryRPCCodeAuthorityOffline,
			errBinaryAuthorityOffline.Error(),
		)
	} else {
		b.cancelPlayerReviewsLocked(session, peer.player.ID, errBinaryTargetOffline)
		b.cancelPlayerRPCsLocked(session, peer.player.ID)
	}
	if len(session.peers) == 0 && len(session.channels) == 0 {
		delete(b.sessions, sessionID)
	}
}

func (b *binaryHub) disconnect(sessionID, playerID string) {
	b.mutex.Lock()
	session := b.sessions[sessionID]
	var peer *binaryPeer
	if session != nil {
		peer = session.peers[playerID]
		if playerID == session.authorityID {
			b.closeAllChannelsLocked(session, "Authority 主会话已断开")
		}
	}
	b.mutex.Unlock()
	if peer != nil {
		peer.close(websocket.StatusNormalClosure, "主会话已关闭")
	}
}

func (b *binaryHub) closeSessionChannels(sessionID string, reason string) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil {
		return
	}
	b.closeAllChannelsLocked(session, reason)
	b.cancelAllRPCsLocked(session, binaryRPCCodeAuthorityOffline, reason)
	if len(session.peers) == 0 {
		delete(b.sessions, sessionID)
	}
}

func (b *binaryHub) handle(peer *binaryPeer, frame binaryClientFrame) {
	switch frame.operation {
	case binaryOpCreate:
		b.createChannel(peer, frame)
	case binaryOpJoin:
		b.joinChannel(peer, frame)
	case binaryOpClose:
		b.closeChannel(peer, frame)
	case binaryOpSend:
		b.send(peer, frame)
	case binaryOpDecision:
		b.decide(peer, frame)
	case binaryOpRPCRequest:
		b.requestRPC(peer, frame)
	case binaryOpRPCResponse:
		b.respondRPC(peer, frame)
	}
}

func (b *binaryHub) requestRPC(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	if session == nil || session.peers[peer.player.ID] != peer {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeAuthorityOffline, errBinaryTargetOffline.Error())
		return
	}
	if !validBinaryRPCPath(frame.path) ||
		frame.timeoutMS < uint32(minBinaryRPCTimeout/time.Millisecond) ||
		frame.timeoutMS > uint32(maxBinaryRPCTimeout/time.Millisecond) {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeInvalidRequest, errBinaryInvalidRPCRequest.Error())
		return
	}
	authority := session.peers[session.authorityID]
	if authority == nil {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeAuthorityOffline, errBinaryAuthorityOffline.Error())
		return
	}
	key := binaryRPCClientKey{senderID: peer.player.ID, requestID: frame.requestID}
	if session.pendingRPCByClient[key] != 0 {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeDuplicate, "RPC requestId 正在处理中")
		return
	}
	if len(session.pendingRPC) >= maxBinaryPendingRPC ||
		session.pendingRPCByPlayer[peer.player.ID] >= maxBinaryPendingRPCPerPlayer ||
		session.pendingRPCBytes+len(frame.payload) > maxBinaryPendingRPCBytes {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeBusy, "Authority RPC 请求队列已满")
		return
	}
	session.nextRPCID++
	if session.nextRPCID == 0 {
		session.nextRPCID++
	}
	rpcID := session.nextRPCID
	incoming, err := encodeBinaryRPCIncoming(
		rpcID,
		peer.player.ID,
		frame.path,
		frame.payload,
	)
	if err != nil {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodePayloadTooLarge, "Authority RPC 请求数据过大")
		return
	}
	if err := authority.enqueue(incoming, nil); err != nil {
		b.sendRPCErrorLocked(peer, frame.requestID, binaryRPCCodeAuthorityOffline, err.Error())
		return
	}
	pending := &binaryPendingRPC{
		id: rpcID, requestID: frame.requestID, senderID: peer.player.ID,
		payloadBytes: len(frame.payload),
	}
	session.pendingRPC[rpcID] = pending
	session.pendingRPCByClient[key] = rpcID
	session.pendingRPCByPlayer[peer.player.ID]++
	session.pendingRPCBytes += len(frame.payload)
	pending.timer = time.AfterFunc(time.Duration(frame.timeoutMS)*time.Millisecond, func() {
		b.expireRPC(peer.sessionID, rpcID)
	})
}

func (b *binaryHub) respondRPC(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	if session == nil || session.peers[peer.player.ID] != peer ||
		peer.player.ID != session.authorityID {
		peer.close(websocket.StatusPolicyViolation, "只有 Authority 可以返回 RPC 结果")
		return
	}
	pending := session.pendingRPC[frame.rpcID]
	if pending == nil {
		return
	}
	b.removePendingRPCLocked(session, pending)
	requester := session.peers[pending.senderID]
	if requester == nil {
		return
	}
	var data []byte
	var err error
	if frame.errorCode != "" {
		if !validBinaryRPCErrorCode(frame.errorCode) || len(frame.errorMessage) > 512 {
			data, err = encodeBinaryRPCResult(
				pending.requestID,
				binaryStatusError,
				nil,
				"rpc_response_invalid",
				"Authority RPC 错误响应格式无效",
			)
		} else {
			data, err = encodeBinaryRPCResult(
				pending.requestID,
				binaryStatusError,
				nil,
				frame.errorCode,
				frame.errorMessage,
			)
		}
	} else {
		data, err = encodeBinaryRPCResult(
			pending.requestID,
			binaryStatusOK,
			frame.payload,
			"",
			"",
		)
	}
	if err != nil {
		b.sendRPCErrorLocked(requester, pending.requestID, "rpc_response_invalid", err.Error())
		return
	}
	_ = requester.enqueue(data, nil)
}

func (b *binaryHub) createChannel(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	if session == nil || session.peers[peer.player.ID] != peer {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryTargetOffline)
		return
	}
	if peer.player.ID != session.authorityID {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryAuthorityOnly)
		return
	}
	if len(session.channels) >= maxBinaryChannels {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelLimit)
		return
	}
	var channelID binaryChannelID
	for {
		if _, err := rand.Read(channelID[:]); err != nil {
			b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, err)
			return
		}
		if session.channels[channelID] == nil {
			break
		}
	}
	channel := &binaryChannel{
		id: channelID, mode: frame.mode,
		members: map[string]bool{peer.player.ID: true},
	}
	session.channels[channelID] = channel
	b.respond(peer, frame.requestID, binaryStatusOK, frame.mode, channelID, nil)
	b.logger.Info(
		"创建二进制 Channel",
		"event", "session.binary_channel_created",
		"sessionId", peer.sessionID,
		"playerId", peer.player.ID,
		"channelId", channelID.String(),
		"mode", binaryModeName(frame.mode),
	)
}

func (b *binaryHub) joinChannel(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	channel := sessionChannel(session, frame.channelID)
	if channel == nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelNotFound)
		return
	}
	channel.members[peer.player.ID] = true
	b.respond(peer, frame.requestID, binaryStatusOK, channel.mode, channel.id, nil)
}

func (b *binaryHub) closeChannel(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	channel := sessionChannel(session, frame.channelID)
	if channel == nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelNotFound)
		return
	}
	if session.authorityID != peer.player.ID {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryAuthorityOnly)
		return
	}
	b.removeChannelLocked(session, channel, "Channel 已关闭")
	b.respond(peer, frame.requestID, binaryStatusOK, 0, binaryChannelID{}, nil)
}

func (b *binaryHub) send(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	channel := sessionChannel(session, frame.channelID)
	if channel == nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelNotFound)
		return
	}
	if !channel.members[peer.player.ID] {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryNotJoined)
		return
	}
	var targetIDs []string
	var err error
	if frame.flags&binaryFlagBroadcast != 0 {
		targetIDs = broadcastBinaryTargetIDs(session, channel, peer.player.ID)
		frame.flags &^= binaryFlagBroadcast
		if len(targetIDs) == 0 {
			b.respond(peer, frame.requestID, binaryStatusOK, 0, binaryChannelID{}, nil)
			return
		}
	} else {
		targetIDs, err = normalizeBinaryTargetIDs(session, frame.targetIDs)
		if err != nil {
			b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, err)
			return
		}
	}
	for _, targetID := range targetIDs {
		if !channel.members[targetID] {
			b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryTargetNotJoined)
			return
		}
		if session.peers[targetID] == nil {
			b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryTargetOffline)
			return
		}
	}
	frame.targetIDs = targetIDs
	if channel.mode == binaryModeAuthority && peer.player.ID != session.authorityID {
		b.sendForReviewLocked(session, channel, peer, frame)
		return
	}
	err = b.deliverManyLocked(
		session,
		channel,
		peer.player.ID,
		frame.targetIDs,
		frame.flags,
		frame.payload,
		true,
	)
	if err != nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, err)
		return
	}
	b.respond(peer, frame.requestID, binaryStatusOK, 0, binaryChannelID{}, nil)
}

func (b *binaryHub) sendForReviewLocked(
	session *binarySession,
	channel *binaryChannel,
	peer *binaryPeer,
	frame binaryClientFrame,
) {
	authority := session.peers[session.authorityID]
	if authority == nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryAuthorityOffline)
		return
	}
	if !channel.members[session.authorityID] {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryAuthorityNotJoined)
		return
	}
	if len(session.pending) >= maxBinaryPendingReviews {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryReviewLimit)
		return
	}
	if session.pendingBytes+len(frame.payload) > maxBinaryPendingBytes {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryReviewBytes)
		return
	}
	var latestKey *binaryLatestKey
	var previousReviewID uint64
	if frame.flags&binaryFlagLatest != 0 {
		key := binaryLatestKey{
			kind: binaryOpReview, channelID: channel.id,
			senderID: peer.player.ID, targetID: binaryTargetSetKey(frame.targetIDs),
		}
		latestKey = &key
		previousReviewID = session.latestReview[key]
	}
	session.nextReviewID++
	reviewID := session.nextReviewID
	review, err := encodeBinaryReview(
		reviewID,
		channel.id,
		frame.flags,
		peer.player.ID,
		publicBinaryPlayerIDs(session, frame.targetIDs),
		frame.payload,
	)
	if err != nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, err)
		return
	}
	pending := &binaryPendingReview{
		id: reviewID, requestID: frame.requestID, channelID: channel.id,
		senderID: peer.player.ID, targetIDs: frame.targetIDs,
		flags: frame.flags, payload: frame.payload, latestKey: latestKey,
	}
	replaced, err := authority.enqueueReview(review, latestKey)
	if err != nil {
		b.respond(peer, frame.requestID, binaryStatusError, 0, binaryChannelID{}, err)
		return
	}
	// sendLatest 只替换尚在 Authority 出站队列中的审核帧。队列一旦
	// pop，JavaScript 处理器就可能已经执行，此时旧、新审核必须各自生效。
	if replaced && previousReviewID != 0 {
		if previous := session.pending[previousReviewID]; previous != nil {
			b.removePendingLocked(session, previous)
			if previousSender := session.peers[previous.senderID]; previousSender != nil {
				b.respond(
					previousSender,
					previous.requestID,
					binaryStatusSuperseded,
					0,
					binaryChannelID{},
					nil,
				)
			}
		}
	}
	session.pending[reviewID] = pending
	session.pendingBytes += len(frame.payload)
	if latestKey != nil {
		session.latestReview[*latestKey] = reviewID
	}
	pending.timer = time.AfterFunc(binaryAuthorityTimeout, func() {
		b.expireReview(peer.sessionID, reviewID)
	})
}

func (b *binaryHub) decide(peer *binaryPeer, frame binaryClientFrame) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[peer.sessionID]
	if session == nil || peer.player.ID != session.authorityID {
		peer.close(websocket.StatusPolicyViolation, "只有 Authority 可以审核二进制消息")
		return
	}
	pending := session.pending[frame.reviewID]
	if pending == nil {
		return
	}
	channel := session.channels[pending.channelID]
	b.removePendingLocked(session, pending)
	sender := session.peers[pending.senderID]
	if channel == nil {
		if sender != nil {
			b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelNotFound)
		}
		return
	}
	if frame.decision == binaryDecisionReject {
		if sender != nil {
			message := frame.errorMessage
			if message == "" {
				message = "Authority 拒绝了二进制消息"
			}
			b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, errors.New(message))
		}
		return
	}
	payload := pending.payload
	if frame.decision == binaryDecisionReplace {
		payload = frame.payload
	}
	err := b.deliverManyLocked(
		session,
		channel,
		pending.senderID,
		pending.targetIDs,
		pending.flags,
		payload,
		false,
	)
	if sender == nil {
		return
	}
	if err != nil {
		b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, err)
	} else {
		b.respond(sender, pending.requestID, binaryStatusOK, 0, binaryChannelID{}, nil)
	}
}

func (b *binaryHub) deliverManyLocked(
	session *binarySession,
	channel *binaryChannel,
	senderID string,
	targetIDs []string,
	flags byte,
	payload []byte,
	coalesce bool,
) error {
	if len(targetIDs) == 0 {
		return errBinaryInvalidTarget
	}
	targets := make([]*binaryPeer, len(targetIDs))
	for index, targetID := range targetIDs {
		if !channel.members[targetID] {
			return errBinaryTargetNotJoined
		}
		target := session.peers[targetID]
		if target == nil {
			return errBinaryTargetOffline
		}
		targets[index] = target
	}
	data, err := encodeBinaryDelivery(
		channel.id,
		flags&binaryFlagLatest,
		publicBinaryPlayerID(session, senderID),
		payload,
	)
	if err != nil {
		return err
	}
	for index, target := range targets {
		var latestKey *binaryLatestKey
		if coalesce && flags&binaryFlagLatest != 0 {
			key := binaryLatestKey{
				kind: binaryOpDelivery, channelID: channel.id,
				senderID: senderID, targetID: targetIDs[index],
			}
			latestKey = &key
		}
		if err := target.enqueue(data, latestKey); err != nil {
			return err
		}
	}
	return nil
}

func resolveBinaryTargetID(session *binarySession, targetID string) string {
	if targetID == binaryAuthorityID {
		return session.authorityID
	}
	return targetID
}

func publicBinaryPlayerID(session *binarySession, playerID string) string {
	if playerID == session.authorityID {
		return binaryAuthorityID
	}
	return playerID
}

func publicBinaryPlayerIDs(session *binarySession, playerIDs []string) []string {
	result := make([]string, len(playerIDs))
	for index, playerID := range playerIDs {
		result[index] = publicBinaryPlayerID(session, playerID)
	}
	return result
}

func normalizeBinaryTargetIDs(
	session *binarySession,
	targetIDs []string,
) ([]string, error) {
	if len(targetIDs) == 0 || len(targetIDs) > maxBinaryTargets {
		return nil, errBinaryInvalidTarget
	}
	result := make([]string, 0, len(targetIDs))
	seen := make(map[string]bool, len(targetIDs))
	for _, targetID := range targetIDs {
		targetID = resolveBinaryTargetID(session, targetID)
		if targetID == "" {
			return nil, errBinaryInvalidTarget
		}
		if seen[targetID] {
			continue
		}
		seen[targetID] = true
		result = append(result, targetID)
	}
	if len(result) == 0 {
		return nil, errBinaryInvalidTarget
	}
	return result, nil
}

func broadcastBinaryTargetIDs(
	session *binarySession,
	channel *binaryChannel,
	senderID string,
) []string {
	result := make([]string, 0, len(channel.members))
	for targetID := range channel.members {
		if targetID == senderID || session.peers[targetID] == nil {
			continue
		}
		result = append(result, targetID)
	}
	sort.Strings(result)
	return result
}

func binaryTargetSetKey(targetIDs []string) string {
	sorted := append([]string(nil), targetIDs...)
	sort.Strings(sorted)
	return strings.Join(sorted, "\x00")
}

func (b *binaryHub) expireReview(sessionID string, reviewID uint64) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil {
		return
	}
	pending := session.pending[reviewID]
	if pending == nil {
		return
	}
	b.removePendingLocked(session, pending)
	if sender := session.peers[pending.senderID]; sender != nil {
		b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryReviewExpired)
	}
}

func (b *binaryHub) removePendingLocked(session *binarySession, pending *binaryPendingReview) {
	delete(session.pending, pending.id)
	session.pendingBytes -= len(pending.payload)
	if pending.timer != nil {
		pending.timer.Stop()
	}
	if pending.latestKey != nil && session.latestReview[*pending.latestKey] == pending.id {
		delete(session.latestReview, *pending.latestKey)
	}
}

func (b *binaryHub) cancelPlayerReviewsLocked(session *binarySession, playerID string, cause error) {
	for _, pending := range session.pending {
		if pending.senderID != playerID && !containsBinaryTarget(pending.targetIDs, playerID) {
			continue
		}
		b.removePendingLocked(session, pending)
		if sender := session.peers[pending.senderID]; sender != nil {
			b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, cause)
		}
	}
}

func (b *binaryHub) cancelAllReviewsLocked(session *binarySession, cause error) {
	for _, pending := range session.pending {
		b.removePendingLocked(session, pending)
		if sender := session.peers[pending.senderID]; sender != nil {
			b.respond(
				sender,
				pending.requestID,
				binaryStatusError,
				0,
				binaryChannelID{},
				cause,
			)
		}
	}
}

func containsBinaryTarget(targetIDs []string, playerID string) bool {
	for _, targetID := range targetIDs {
		if targetID == playerID {
			return true
		}
	}
	return false
}

func validBinaryRPCPath(path string) bool {
	if len(path) == 0 || len(path) > 256 || path[0] != '/' {
		return false
	}
	if path == "/" {
		return true
	}
	if path[len(path)-1] == '/' {
		return false
	}
	previousSlash := true
	for index := 1; index < len(path); index++ {
		value := path[index]
		if value == '/' {
			if previousSlash {
				return false
			}
			previousSlash = true
			continue
		}
		previousSlash = false
		if (value >= 'a' && value <= 'z') ||
			(value >= 'A' && value <= 'Z') ||
			(value >= '0' && value <= '9') ||
			value == '.' || value == '_' || value == '-' || value == '~' {
			continue
		}
		return false
	}
	return true
}

func validBinaryRPCErrorCode(code string) bool {
	if len(code) == 0 || len(code) > 64 || code[0] < 'a' || code[0] > 'z' {
		return false
	}
	for index := 1; index < len(code); index++ {
		value := code[index]
		if (value >= 'a' && value <= 'z') ||
			(value >= '0' && value <= '9') || value == '_' {
			continue
		}
		return false
	}
	return true
}

func (b *binaryHub) sendRPCErrorLocked(
	peer *binaryPeer,
	requestID uint32,
	code string,
	message string,
) {
	data, err := encodeBinaryRPCResult(
		requestID,
		binaryStatusError,
		nil,
		code,
		message,
	)
	if err == nil {
		_ = peer.enqueue(data, nil)
	}
}

func (b *binaryHub) expireRPC(sessionID string, rpcID uint64) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil {
		return
	}
	pending := session.pendingRPC[rpcID]
	if pending == nil {
		return
	}
	b.removePendingRPCLocked(session, pending)
	if requester := session.peers[pending.senderID]; requester != nil {
		b.sendRPCErrorLocked(
			requester,
			pending.requestID,
			binaryRPCCodeTimeout,
			"Authority RPC 请求超时",
		)
	}
}

func (b *binaryHub) removePendingRPCLocked(
	session *binarySession,
	pending *binaryPendingRPC,
) {
	delete(session.pendingRPC, pending.id)
	delete(
		session.pendingRPCByClient,
		binaryRPCClientKey{senderID: pending.senderID, requestID: pending.requestID},
	)
	remaining := session.pendingRPCByPlayer[pending.senderID] - 1
	if remaining > 0 {
		session.pendingRPCByPlayer[pending.senderID] = remaining
	} else {
		delete(session.pendingRPCByPlayer, pending.senderID)
	}
	session.pendingRPCBytes -= pending.payloadBytes
	if pending.timer != nil {
		pending.timer.Stop()
	}
}

func (b *binaryHub) cancelPlayerRPCsLocked(
	session *binarySession,
	playerID string,
) {
	for _, pending := range session.pendingRPC {
		if pending.senderID == playerID {
			b.removePendingRPCLocked(session, pending)
		}
	}
}

func (b *binaryHub) cancelAllRPCsLocked(
	session *binarySession,
	code string,
	message string,
) {
	for _, pending := range session.pendingRPC {
		b.removePendingRPCLocked(session, pending)
		if requester := session.peers[pending.senderID]; requester != nil {
			b.sendRPCErrorLocked(requester, pending.requestID, code, message)
		}
	}
}

func (b *binaryHub) closeAllChannelsLocked(session *binarySession, reason string) {
	for _, channel := range session.channels {
		b.removeChannelLocked(session, channel, reason)
	}
}

func (b *binaryHub) removeChannelLocked(
	session *binarySession,
	channel *binaryChannel,
	reason string,
) {
	delete(session.channels, channel.id)
	for _, pending := range session.pending {
		if pending.channelID != channel.id {
			continue
		}
		b.removePendingLocked(session, pending)
		if sender := session.peers[pending.senderID]; sender != nil {
			b.respond(sender, pending.requestID, binaryStatusError, 0, binaryChannelID{}, errBinaryChannelNotFound)
		}
	}
	closed := encodeBinaryClosed(channel.id, reason)
	for memberID := range channel.members {
		if peer := session.peers[memberID]; peer != nil {
			_ = peer.enqueue(closed, nil)
		}
	}
	b.logger.Info(
		"关闭二进制 Channel",
		"event", "session.binary_channel_closed",
		"channelId", channel.id.String(),
		"reason", reason,
	)
}

func (b *binaryHub) respond(
	peer *binaryPeer,
	requestID uint32,
	status byte,
	mode byte,
	channelID binaryChannelID,
	cause error,
) {
	message := ""
	if cause != nil {
		message = cause.Error()
	}
	_ = peer.enqueue(encodeBinaryResponse(requestID, status, mode, channelID, message), nil)
}

func sessionChannel(session *binarySession, channelID binaryChannelID) *binaryChannel {
	if session == nil {
		return nil
	}
	return session.channels[channelID]
}

func binaryModeName(mode byte) string {
	if mode == binaryModeAuthority {
		return "authority"
	}
	return "relay"
}
