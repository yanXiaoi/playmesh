package webrtctunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

type relayCredentials struct {
	Type            string      `json:"type"`
	ProtocolVersion string      `json:"protocolVersion"`
	Timestamp       int64       `json:"timestamp"`
	RequestID       string      `json:"requestId"`
	TunnelID        string      `json:"tunnelId"`
	HostLease       string      `json:"hostLease"`
	JoinCapability  string      `json:"joinCapability"`
	ExpiresAt       time.Time   `json:"expiresAt"`
	ICEServers      []iceServer `json:"iceServers"`
}

type HostRequest struct {
	SessionID            string `json:"sessionId"`
	ServerBaseURL        string `json:"serverBaseUrl"`
	SourceToken          string `json:"sourceToken"`
	HostPath             string `json:"hostPath"`
	ClientPath           string `json:"clientPath"`
	AuthorityWebBaseURI  string `json:"authorityWebBaseUri"`
	AuthorityCoreBaseURI string `json:"authorityCoreBaseUri"`
	AuthorityEntryURI    string `json:"authorityEntryUri"`
	MaxPeers             int    `json:"maxPeers"`
}

type HostSession struct {
	id          string
	sessionID   string
	joinURL     *url.URL
	expiresAt   time.Time
	credentials relayCredentials
	serverURL   *url.URL
	hostPath    string
	sourceToken string
	signal      *signalSocket
	api         *webrtc.API
	secret      []byte
	webTarget   *url.URL
	coreTarget  *url.URL
	registry    *connectionRegistry
	maxPeers    int

	ctx       context.Context
	cancel    context.CancelFunc
	closeOnce sync.Once
	mutex     sync.RWMutex
	peers     map[string]*peer
	mode      map[string]string
	status    string
}

func newHostSession(
	ctx context.Context,
	api *webrtc.API,
	registry *connectionRegistry,
	request HostRequest,
) (*HostSession, error) {
	serverURL, err := parseServerBaseURL(request.ServerBaseURL)
	if err != nil {
		return nil, err
	}
	if err := validateRelayPath(request.HostPath); err != nil {
		return nil, err
	}
	if err := validateRelayPath(request.ClientPath); err != nil {
		return nil, err
	}
	webTarget, err := parseLoopbackTarget(request.AuthorityWebBaseURI)
	if err != nil {
		return nil, errors.New("Authority Web 目标无效")
	}
	coreTarget, err := parseLoopbackTarget(request.AuthorityCoreBaseURI)
	if err != nil {
		return nil, errors.New("Authority Core 目标无效")
	}
	entryURL, err := url.Parse(request.AuthorityEntryURI)
	if err != nil || entryURL.Hostname() != "127.0.0.1" {
		return nil, errors.New("Authority 邀请入口无效")
	}
	credentials, err := createRelaySession(ctx, serverURL, request)
	if err != nil {
		return nil, err
	}
	secret, err := randomBytes(32)
	if err != nil {
		return nil, err
	}
	joinURL, err := makeInvitation(
		serverURL, credentials.TunnelID, request.ClientPath,
		credentials.JoinCapability, entryURL, secret, credentials.ExpiresAt,
	)
	if err != nil {
		return nil, err
	}
	headers := make(http.Header)
	headers.Set("Authorization", "Bearer "+request.SourceToken)
	headers.Set("X-Playmesh-Host-Lease", credentials.HostLease)
	signal, err := dialSignal(ctx, serverURL, request.HostPath, url.Values{"tunnelId": {credentials.TunnelID}}, headers)
	if err != nil {
		return nil, err
	}
	sessionCtx, cancel := context.WithCancel(context.Background())
	id, err := randomID(18)
	if err != nil {
		cancel()
		signal.close("初始化失败")
		return nil, err
	}
	result := &HostSession{
		id: id, sessionID: request.SessionID, joinURL: joinURL,
		expiresAt: credentials.ExpiresAt, credentials: credentials,
		serverURL: serverURL, hostPath: request.HostPath, sourceToken: request.SourceToken,
		signal: signal, api: api, secret: secret, webTarget: webTarget, coreTarget: coreTarget,
		registry: registry, maxPeers: request.MaxPeers,
		ctx: sessionCtx, cancel: cancel, peers: make(map[string]*peer), mode: make(map[string]string),
		status: "connected",
	}
	go result.readSignals()
	return result, nil
}

func createRelaySession(ctx context.Context, serverURL *url.URL, request HostRequest) (relayCredentials, error) {
	endpoint := serverURL.ResolveReference(&url.URL{Path: request.HostPath})
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), nil)
	if err != nil {
		return relayCredentials{}, err
	}
	httpRequest.Header.Set("Authorization", "Bearer "+request.SourceToken)
	requestID, err := randomRelayRequestID()
	if err != nil {
		return relayCredentials{}, err
	}
	httpRequest.Header.Set("X-Playmesh-Relay-Version", relaySignalProtocolVersion)
	httpRequest.Header.Set("X-Playmesh-Request-ID", requestID)
	httpRequest.Header.Set("X-Playmesh-Timestamp", fmt.Sprintf("%d", time.Now().UnixMilli()))
	response, err := http.DefaultClient.Do(httpRequest)
	if err != nil {
		return relayCredentials{}, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil {
		return relayCredentials{}, fmt.Errorf("读取公共 WebRTC 会话响应失败: %w", err)
	}
	if len(body) > 64*1024 {
		return relayCredentials{}, fmt.Errorf("公共 WebRTC 会话响应过大: status=%s body=%s", response.Status, body)
	}
	if response.StatusCode != http.StatusCreated {
		return relayCredentials{}, fmt.Errorf("公共 WebRTC 会话创建失败: status=%s body=%s", response.Status, body)
	}
	var credentials relayCredentials
	if err := json.Unmarshal(body, &credentials); err != nil {
		return relayCredentials{}, fmt.Errorf("公共 WebRTC 会话凭据 JSON 无效: %w; body=%s", err, body)
	}
	if credentials.Type != "playmesh.relay.credentials" ||
		credentials.ProtocolVersion != relaySignalProtocolVersion || credentials.RequestID != requestID ||
		credentials.Timestamp <= 0 || credentials.TunnelID == "" || credentials.HostLease == "" ||
		credentials.JoinCapability == "" || !credentials.ExpiresAt.After(time.Now()) {
		return relayCredentials{}, fmt.Errorf("公共 WebRTC 会话凭据无效: body=%s", body)
	}
	return credentials, nil
}

func (s *HostSession) readSignals() {
	defer s.Close()
	for {
		frame, err := s.signal.read(s.ctx)
		if err != nil {
			return
		}
		switch frame.Type {
		case "peer.joined":
			configuration, err := parsePeerConnectionConfiguration(frame.Payload)
			if err != nil {
				// 兼容尚未携带逐连接 ICE 配置的 4.0.0 服务端；旧服务端
				// 本身会在这组初始凭据到期时关闭隧道，因此不能在到期后回退。
				if !s.credentials.ExpiresAt.After(time.Now()) {
					continue
				}
				configuration.ICEServers = s.credentials.ICEServers
			}
			if _, err = s.ensurePeer(frame.PeerID, configuration.ICEServers); err != nil {
				s.reportPeerError(frame.PeerID, "主机创建 WebRTC PeerConnection 失败", err)
			}
		case "peer.left":
			s.removePeer(frame.PeerID)
		case "description", "candidate":
			p := s.peer(frame.PeerID)
			if p == nil {
				continue
			}
			if frame.Type == "description" {
				err = p.handleOffer(frame.Payload)
			} else {
				err = p.handleCandidate(frame.Payload)
			}
			if err != nil {
				s.reportPeerError(frame.PeerID, "主机处理 WebRTC 信令失败", err)
				p.close()
			}
		case "close":
			s.removePeer(frame.PeerID)
		}
	}
}

func (s *HostSession) reportPeerError(peerID, operation string, err error) {
	if peerID == "" || err == nil {
		return
	}
	_ = s.signal.write(s.ctx, signalFrame{
		Type:    "peer.error",
		PeerID:  peerID,
		Payload: json.RawMessage(`{}`),
		Reason:  fmt.Sprintf("%s: %v", operation, err),
	})
}

type peerConnectionConfiguration struct {
	ICEServers []iceServer `json:"iceServers"`
	ExpiresAt  time.Time   `json:"expiresAt"`
}

func parsePeerConnectionConfiguration(payload json.RawMessage) (peerConnectionConfiguration, error) {
	var configuration peerConnectionConfiguration
	if json.Unmarshal(payload, &configuration) != nil ||
		len(configuration.ICEServers) == 0 ||
		!configuration.ExpiresAt.After(time.Now()) {
		return peerConnectionConfiguration{}, errors.New("WebRTC 临时 ICE 配置无效")
	}
	return configuration, nil
}

func (s *HostSession) peer(peerID string) *peer {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.peers[peerID]
}

func (s *HostSession) ensurePeer(peerID string, iceServers []iceServer) (*peer, error) {
	if peerID == "" {
		return nil, errors.New("信令 peerId 缺失")
	}
	if len(iceServers) == 0 {
		return nil, errors.New("WebRTC 临时 ICE 配置缺失")
	}
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if existing := s.peers[peerID]; existing != nil {
		return existing, nil
	}
	if len(s.peers) >= s.maxPeers {
		return nil, errors.New("WebRTC 会话玩家数量已达本地上限")
	}
	var result *peer
	p, err := newPeer(s.api, iceServers, s.signal, peerID, s.ctx, func() {
		s.mutex.Lock()
		if s.peers[peerID] == result {
			delete(s.peers, peerID)
			delete(s.mode, peerID)
		}
		s.mutex.Unlock()
	})
	if err != nil {
		return nil, err
	}
	result = p
	p.pc.OnDataChannel(func(channel *webrtc.DataChannel) {
		if channel.Label() == controlDataChannelLabel {
			detachAndDiscard(channel)
			return
		}
		channel.OnOpen(func() {
			connection, err := channel.Detach()
			if err != nil {
				_ = channel.Close()
				return
			}
			go s.serveStream(p, connection)
		})
	})
	p.pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateConnected {
			s.mutex.Lock()
			s.mode[peerID] = p.selectedMode()
			s.mutex.Unlock()
		}
		closeDisconnectedPeer(p, state)
	})
	s.peers[peerID] = p
	s.mode[peerID] = "connecting"
	return p, nil
}

func (s *HostSession) serveStream(p *peer, connection io.ReadWriteCloser) {
	header, err := readStreamHeader(connection, s.secret)
	if err != nil || !p.acceptStream(header) {
		_ = connection.Close()
		return
	}
	streamReleased := false
	releaseStream := func() {
		if streamReleased {
			return
		}
		streamReleased = true
		p.releaseStream(header.ConnectionID)
	}
	target := s.webTarget
	if header.Target == "core" {
		target = s.coreTarget
	}
	plain, err := net.DialTimeout("tcp", target.Host, 5*time.Second)
	if err != nil {
		releaseStream()
		_ = connection.Close()
		return
	}
	mode := p.selectedMode()
	if mode != "direct" && mode != "relay" {
		releaseStream()
		_ = connection.Close()
		_ = plain.Close()
		return
	}
	registryKey := plain.LocalAddr().String()
	s.registry.register(registryKey, mode)
	bridgeConnections(connection, plain, func() {
		s.registry.remove(registryKey)
		releaseStream()
	})
}

func (s *HostSession) removePeer(peerID string) {
	s.mutex.RLock()
	p := s.peers[peerID]
	s.mutex.RUnlock()
	if p != nil {
		p.close()
	}
}

func (s *HostSession) snapshot() SessionSnapshot {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	modes := make(map[string]string, len(s.mode))
	for id, mode := range s.mode {
		modes[id] = mode
	}
	connectionCount := len(s.peers)
	return SessionSnapshot{
		ID: s.id, Status: s.status, JoinURI: s.joinURL.String(),
		ExpiresAt: s.expiresAt.UTC(), ConnectionCount: &connectionCount, PeerModes: modes,
	}
}

func (s *HostSession) Close() {
	s.closeOnce.Do(func() {
		s.cancel()
		s.signal.close("Authority WebRTC 会话已关闭")
		s.mutex.Lock()
		s.status = "closed"
		peers := make([]*peer, 0, len(s.peers))
		for _, p := range s.peers {
			peers = append(peers, p)
		}
		s.peers = make(map[string]*peer)
		s.mode = make(map[string]string)
		s.mutex.Unlock()
		for _, p := range peers {
			p.close()
		}
		deleteURL := s.serverURL.ResolveReference(&url.URL{Path: s.hostPath, RawQuery: url.Values{"tunnelId": {s.credentials.TunnelID}}.Encode()})
		request, _ := http.NewRequestWithContext(context.Background(), http.MethodDelete, deleteURL.String(), nil)
		request.Header.Set("Authorization", "Bearer "+s.sourceToken)
		request.Header.Set("X-Playmesh-Host-Lease", s.credentials.HostLease)
		if requestID, err := randomRelayRequestID(); err == nil {
			request.Header.Set("X-Playmesh-Relay-Version", relaySignalProtocolVersion)
			request.Header.Set("X-Playmesh-Request-ID", requestID)
			request.Header.Set("X-Playmesh-Timestamp", fmt.Sprintf("%d", time.Now().UnixMilli()))
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		request = request.WithContext(ctx)
		if response, err := http.DefaultClient.Do(request); err == nil {
			response.Body.Close()
		}
	})
}
