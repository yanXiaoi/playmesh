package relay

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"go-server/internal/config"
)

var (
	ErrTunnelNotFound  = errors.New("WebRTC 会话不存在或已过期")
	ErrTunnelLimit     = errors.New("WebRTC 会话数量已达上限")
	ErrConnectionLimit = errors.New("WebRTC 会话玩家数量已达上限")
	ErrHostUnavailable = errors.New("Authority 信令端当前不可用")
	ErrUnauthorized    = errors.New("WebRTC 会话凭证无效")
)

type Credentials struct {
	Type            string      `json:"type"`
	ProtocolVersion string      `json:"protocolVersion"`
	Timestamp       int64       `json:"timestamp"`
	RequestID       string      `json:"requestId"`
	TunnelID        string      `json:"tunnelId"`
	HostLease       string      `json:"hostLease"`
	JoinCapability  string      `json:"joinCapability"`
	ExpiresAt       time.Time   `json:"expiresAt"`
	ICEServers      []ICEServer `json:"iceServers"`
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type SignalFrame struct {
	Type            string          `json:"type"`
	ProtocolVersion string          `json:"protocolVersion"`
	Timestamp       int64           `json:"timestamp"`
	RequestID       string          `json:"requestId"`
	PeerID          string          `json:"peerId,omitempty"`
	Payload         json.RawMessage `json:"payload,omitempty"`
	Reason          string          `json:"reason,omitempty"`
}

type SignalRouteError struct {
	Code    string
	Message string
	Cause   error
}

func (e *SignalRouteError) Error() string {
	if e.Cause == nil {
		return e.Message
	}
	return fmt.Sprintf("%s: %v", e.Message, e.Cause)
}

func (e *SignalRouteError) Unwrap() error {
	return e.Cause
}

type signalPeer struct {
	conn                    *websocket.Conn
	connectionConfiguration json.RawMessage
	mutex                   sync.Mutex
}

func (p *signalPeer) write(frame SignalFrame) error {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	frame, err := normalizeSignalFrame(frame)
	if err != nil {
		return err
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	return p.conn.Write(ctx, websocket.MessageText, data)
}

type Manager struct {
	config  config.Relay
	mutex   sync.RWMutex
	tunnels map[string]*Tunnel
	stop    chan struct{}

	activePairs       atomic.Int64
	totalPairs        atomic.Int64
	bytesHostToClient atomic.Int64
	bytesClientToHost atomic.Int64
}

type Tunnel struct {
	id             string
	hostLeaseHash  [32]byte
	capabilityHash [32]byte
	attachDeadline time.Time
	maxConnections int

	mutex   sync.Mutex
	closed  bool
	host    *signalPeer
	clients map[string]*signalPeer
}

type Stats struct {
	Transport          string `json:"transport"`
	Tunnels            int    `json:"tunnels"`
	TrackedConnections int    `json:"trackedConnections"`
	ActivePairs        int64  `json:"activePairs"`
	TotalPairs         int64  `json:"totalPairs"`
	BytesHostToClient  int64  `json:"bytesHostToClient"`
	BytesClientToHost  int64  `json:"bytesClientToHost"`
	MaxTunnels         int    `json:"maxTunnels"`
	UpdatedAt          int64  `json:"updatedAt"`
}

func NewManager(cfg config.Relay) *Manager {
	manager := &Manager{
		config: cfg, tunnels: make(map[string]*Tunnel), stop: make(chan struct{}),
	}
	go manager.cleanupLoop()
	return manager
}

func (m *Manager) Close() {
	select {
	case <-m.stop:
		return
	default:
		close(m.stop)
	}
	m.mutex.Lock()
	tunnels := make([]*Tunnel, 0, len(m.tunnels))
	for _, tunnel := range m.tunnels {
		tunnels = append(tunnels, tunnel)
	}
	m.tunnels = make(map[string]*Tunnel)
	m.mutex.Unlock()
	for _, tunnel := range tunnels {
		m.activePairs.Add(-int64(tunnel.close("服务正在关闭")))
	}
}

func (m *Manager) Create(requestID string) (Credentials, error) {
	m.mutex.Lock()
	defer m.mutex.Unlock()
	if len(m.tunnels) >= m.config.MaxTunnels {
		return Credentials{}, ErrTunnelLimit
	}
	tunnelID, err := randomToken(18)
	if err != nil {
		return Credentials{}, err
	}
	hostLease, err := randomToken(32)
	if err != nil {
		return Credentials{}, err
	}
	capability, err := randomToken(32)
	if err != nil {
		return Credentials{}, err
	}
	credentialExpiresAt := time.Now().Add(m.config.TunnelTTL())
	iceServers, err := turnICEServers(
		m.config, tunnelID, time.Until(credentialExpiresAt),
	)
	if err != nil {
		return Credentials{}, err
	}
	m.tunnels[tunnelID] = &Tunnel{
		id: tunnelID, hostLeaseHash: sha256.Sum256([]byte(hostLease)),
		capabilityHash: sha256.Sum256([]byte(capability)),
		attachDeadline: credentialExpiresAt,
		maxConnections: m.config.MaxConnectionsPerTunnel,
		clients:        make(map[string]*signalPeer),
	}
	return Credentials{
		Type: "playmesh.relay.credentials", ProtocolVersion: config.RelayProtocolVersion,
		Timestamp: time.Now().UnixMilli(), RequestID: requestID,
		TunnelID: tunnelID, HostLease: hostLease,
		JoinCapability: capability, ExpiresAt: credentialExpiresAt.UTC(),
		ICEServers: iceServers,
	}, nil
}

func normalizeSignalFrame(frame SignalFrame) (SignalFrame, error) {
	if frame.ProtocolVersion == "" {
		frame.ProtocolVersion = config.RelayProtocolVersion
	}
	if frame.Timestamp == 0 {
		frame.Timestamp = time.Now().UnixMilli()
	}
	if frame.RequestID == "" {
		requestID, err := randomRelayRequestID()
		if err != nil {
			return SignalFrame{}, err
		}
		frame.RequestID = requestID
	}
	return frame, nil
}

func (m *Manager) AuthenticateHost(id, lease string) (*Tunnel, error) {
	if len(id) != 24 || len(lease) != 43 {
		return nil, ErrUnauthorized
	}
	tunnel, err := m.get(id)
	if err != nil {
		return nil, err
	}
	actual := sha256.Sum256([]byte(lease))
	if subtle.ConstantTimeCompare(actual[:], tunnel.hostLeaseHash[:]) != 1 {
		return nil, ErrUnauthorized
	}
	return tunnel, nil
}

func (m *Manager) AuthenticateClient(id, capability string) (*Tunnel, error) {
	if len(id) != 24 || len(capability) != 43 {
		return nil, ErrUnauthorized
	}
	tunnel, err := m.get(id)
	if err != nil {
		return nil, err
	}
	actual := sha256.Sum256([]byte(capability))
	if subtle.ConstantTimeCompare(actual[:], tunnel.capabilityHash[:]) != 1 {
		return nil, ErrUnauthorized
	}
	return tunnel, nil
}

func (m *Manager) Delete(id string, tunnel *Tunnel) {
	m.mutex.Lock()
	if m.tunnels[id] == tunnel {
		delete(m.tunnels, id)
	}
	m.mutex.Unlock()
	m.activePairs.Add(-int64(tunnel.close("WebRTC 会话已关闭")))
}

func (m *Manager) get(id string) (*Tunnel, error) {
	m.mutex.RLock()
	tunnel := m.tunnels[id]
	m.mutex.RUnlock()
	if tunnel == nil {
		return nil, ErrTunnelNotFound
	}
	tunnel.mutex.Lock()
	expired := tunnel.closed ||
		(tunnel.host == nil && time.Now().After(tunnel.attachDeadline))
	tunnel.mutex.Unlock()
	if expired {
		m.Delete(id, tunnel)
		return nil, ErrTunnelNotFound
	}
	return tunnel, nil
}

func (m *Manager) AttachHost(tunnel *Tunnel, connection *websocket.Conn) (*signalPeer, error) {
	peer := &signalPeer{conn: connection}
	tunnel.mutex.Lock()
	if tunnel.closed {
		tunnel.mutex.Unlock()
		return nil, ErrTunnelNotFound
	}
	previous := tunnel.host
	tunnel.host = peer
	type attachedClient struct {
		id            string
		configuration json.RawMessage
	}
	clients := make([]attachedClient, 0, len(tunnel.clients))
	for id, client := range tunnel.clients {
		clients = append(clients, attachedClient{
			id:            id,
			configuration: client.connectionConfiguration,
		})
	}
	tunnel.mutex.Unlock()
	if previous != nil {
		_ = previous.conn.Close(websocket.StatusPolicyViolation, "Authority 信令连接已被替换")
	}
	for _, client := range clients {
		_ = peer.write(SignalFrame{
			Type: "peer.joined", PeerID: client.id,
			Payload: client.configuration,
		})
	}
	return peer, nil
}

func (m *Manager) DetachHost(tunnel *Tunnel, peer *signalPeer) {
	tunnel.mutex.Lock()
	detached := false
	if tunnel.host == peer {
		tunnel.host = nil
		detached = true
	}
	tunnel.mutex.Unlock()
	if detached {
		// 邀请的真实租约就是当前 Authority 信令连接。主机断开后立即
		// 删除隧道，使原二维码和原链接同时失效；替换连接的旧 peer
		// 不得误删已经接管同一租约的新连接。
		m.Delete(tunnel.id, tunnel)
	}
}

func (m *Manager) AttachClient(tunnel *Tunnel, connection *websocket.Conn) (string, *signalPeer, error) {
	peerID, err := randomToken(18)
	if err != nil {
		return "", nil, err
	}
	credentialExpiresAt := time.Now().Add(m.config.TunnelTTL())
	iceServers, err := turnICEServers(
		m.config, tunnel.id+":"+peerID, m.config.TunnelTTL(),
	)
	if err != nil {
		return "", nil, err
	}
	connectionConfiguration, err := json.Marshal(map[string]any{
		"iceServers": iceServers,
		"expiresAt":  credentialExpiresAt.UTC(),
	})
	if err != nil {
		return "", nil, err
	}
	peer := &signalPeer{
		conn: connection, connectionConfiguration: connectionConfiguration,
	}
	tunnel.mutex.Lock()
	if tunnel.closed {
		tunnel.mutex.Unlock()
		return "", nil, ErrTunnelNotFound
	}
	if tunnel.host == nil {
		tunnel.mutex.Unlock()
		return "", nil, ErrHostUnavailable
	}
	if len(tunnel.clients) >= tunnel.maxConnections {
		tunnel.mutex.Unlock()
		return "", nil, ErrConnectionLimit
	}
	tunnel.clients[peerID] = peer
	host := tunnel.host
	tunnel.mutex.Unlock()
	m.activePairs.Add(1)
	m.totalPairs.Add(1)
	// 两端必须拿到同一组刚签发的临时 ICE 凭据。先通知主机，再允许
	// 加入端发送 offer，避免长时间分享后的旧 TURN 凭据被继续复用。
	if err := host.write(SignalFrame{
		Type: "peer.joined", PeerID: peerID,
		Payload: connectionConfiguration,
	}); err != nil {
		m.DetachClient(tunnel, peerID, peer)
		return "", nil, ErrHostUnavailable
	}
	if err := peer.write(SignalFrame{
		Type: "connected", PeerID: peerID,
		Payload: connectionConfiguration,
	}); err != nil {
		m.DetachClient(tunnel, peerID, peer)
		return "", nil, err
	}
	return peerID, peer, nil
}

func (m *Manager) DetachClient(tunnel *Tunnel, peerID string, peer *signalPeer) {
	tunnel.mutex.Lock()
	if tunnel.clients[peerID] != peer {
		tunnel.mutex.Unlock()
		return
	}
	delete(tunnel.clients, peerID)
	host := tunnel.host
	tunnel.mutex.Unlock()
	m.activePairs.Add(-1)
	if host != nil {
		_ = host.write(SignalFrame{Type: "peer.left", PeerID: peerID})
	}
}

func (m *Manager) RouteFromHost(tunnel *Tunnel, frame SignalFrame, size int) error {
	if frame.PeerID == "" {
		return &SignalRouteError{
			Code: "host_peer_id_missing", Message: "Authority 信令缺少 peerId",
		}
	}
	if frame.Type != "description" && frame.Type != "candidate" &&
		frame.Type != "peer.error" && frame.Type != "close" {
		return &SignalRouteError{
			Code: "host_signal_type_unsupported", Message: "Authority 信令类型不受支持",
		}
	}
	tunnel.mutex.Lock()
	client := tunnel.clients[frame.PeerID]
	tunnel.mutex.Unlock()
	if client == nil {
		return nil
	}
	m.bytesHostToClient.Add(int64(size))
	if err := client.write(frame); err != nil {
		return &SignalRouteError{
			Code: "client_signal_write_failed", Message: "向加入端写入信令失败", Cause: err,
		}
	}
	return nil
}

func (m *Manager) RouteFromClient(tunnel *Tunnel, peerID string, frame SignalFrame, size int) error {
	if frame.Type != "description" && frame.Type != "candidate" && frame.Type != "close" {
		return &SignalRouteError{
			Code: "client_signal_type_unsupported", Message: "加入端信令类型不受支持",
		}
	}
	frame.PeerID = peerID
	tunnel.mutex.Lock()
	host := tunnel.host
	tunnel.mutex.Unlock()
	if host == nil {
		return &SignalRouteError{
			Code: "host_signal_unavailable", Message: "Authority 信令端当前不可用",
		}
	}
	m.bytesClientToHost.Add(int64(size))
	if err := host.write(frame); err != nil {
		return &SignalRouteError{
			Code: "host_signal_write_failed", Message: "向 Authority 写入信令失败", Cause: err,
		}
	}
	return nil
}

func (m *Manager) Stats() Stats {
	m.mutex.RLock()
	tunnels := make([]*Tunnel, 0, len(m.tunnels))
	for _, tunnel := range m.tunnels {
		tunnels = append(tunnels, tunnel)
	}
	m.mutex.RUnlock()
	connections := 0
	for _, tunnel := range tunnels {
		tunnel.mutex.Lock()
		connections += len(tunnel.clients)
		if tunnel.host != nil {
			connections++
		}
		tunnel.mutex.Unlock()
	}
	return Stats{
		Transport: "webrtc-signaling", Tunnels: len(tunnels),
		TrackedConnections: connections, ActivePairs: m.activePairs.Load(),
		TotalPairs:        m.totalPairs.Load(),
		BytesHostToClient: m.bytesHostToClient.Load(),
		BytesClientToHost: m.bytesClientToHost.Load(),
		MaxTunnels:        m.config.MaxTunnels, UpdatedAt: time.Now().UnixMilli(),
	}
}

func (t *Tunnel) close(reason string) int {
	t.mutex.Lock()
	if t.closed {
		t.mutex.Unlock()
		return 0
	}
	t.closed = true
	activeClients := len(t.clients)
	peers := make([]*signalPeer, 0, len(t.clients)+1)
	if t.host != nil {
		peers = append(peers, t.host)
	}
	for _, peer := range t.clients {
		peers = append(peers, peer)
	}
	t.host = nil
	t.clients = make(map[string]*signalPeer)
	t.mutex.Unlock()
	for _, peer := range peers {
		_ = peer.conn.Close(websocket.StatusNormalClosure, reason)
	}
	return activeClients
}

func (m *Manager) cleanupLoop() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			now := time.Now()
			m.mutex.RLock()
			expired := make(map[string]*Tunnel)
			for id, tunnel := range m.tunnels {
				tunnel.mutex.Lock()
				shouldExpire := tunnel.host == nil && now.After(tunnel.attachDeadline)
				tunnel.mutex.Unlock()
				if shouldExpire {
					expired[id] = tunnel
				}
			}
			m.mutex.RUnlock()
			for id, tunnel := range expired {
				m.Delete(id, tunnel)
			}
		case <-m.stop:
			return
		}
	}
}

func randomToken(byteCount int) (string, error) {
	value := make([]byte, byteCount)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func randomRelayRequestID() (string, error) {
	value, err := randomToken(12)
	if err != nil {
		return "", err
	}
	return "relay-" + value, nil
}
