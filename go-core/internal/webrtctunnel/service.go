package webrtctunnel

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

var ErrSessionNotFound = errors.New("WebRTC 隧道会话不存在")

type SessionSnapshot struct {
	Type            string            `json:"type,omitempty"`
	ProtocolVersion string            `json:"protocolVersion,omitempty"`
	Timestamp       int64             `json:"timestamp,omitempty"`
	RequestID       string            `json:"requestId,omitempty"`
	ID              string            `json:"id"`
	Status          string            `json:"status"`
	JoinURI         string            `json:"joinUri,omitempty"`
	ExpiresAt       time.Time         `json:"expiresAt,omitempty"`
	ConnectionCount *int              `json:"connectionCount,omitempty"`
	PeerModes       map[string]string `json:"peerModes,omitempty"`
	ConnectionMode  string            `json:"connectionMode,omitempty"`
	WebBaseURI      string            `json:"webBaseUri,omitempty"`
	CoreBaseURI     string            `json:"coreBaseUri,omitempty"`
	LocalEntryURI   string            `json:"localEntryUri,omitempty"`
}

type Service struct {
	api       *webrtc.API
	registry  *connectionRegistry
	localTURN *localTURNService

	mutex   sync.RWMutex
	hosts   map[string]*HostSession
	clients map[string]*ClientSession
	closed  bool
}

func NewService(loggers ...*slog.Logger) *Service {
	return NewServiceWithLocalTURNAddresses(nil, loggers...)
}

func NewServiceWithLocalTURNAddresses(addresses []string, loggers ...*slog.Logger) *Service {
	settingEngine := webrtc.SettingEngine{}
	settingEngine.DetachDataChannels()
	var logger *slog.Logger
	if len(loggers) > 0 {
		logger = loggers[0]
	}
	return &Service{
		api:       webrtc.NewAPI(webrtc.WithSettingEngine(settingEngine)),
		registry:  newConnectionRegistry(),
		localTURN: newLocalTURNService(logger, addresses),
		hosts:     make(map[string]*HostSession), clients: make(map[string]*ClientSession),
	}
}

func (s *Service) CreateHost(ctx context.Context, request HostRequest) (SessionSnapshot, error) {
	if strings.TrimSpace(request.SessionID) == "" {
		return SessionSnapshot{}, errors.New("sessionId 不能为空")
	}
	if request.MaxPeers < 1 {
		return SessionSnapshot{}, errors.New("maxPeers 必须是正整数")
	}
	s.mutex.RLock()
	closed := s.closed
	s.mutex.RUnlock()
	if closed {
		return SessionSnapshot{}, errors.New("WebRTC 隧道服务已经关闭")
	}
	session, err := newHostSession(ctx, s.api, s.registry, request)
	if err != nil {
		return SessionSnapshot{}, err
	}
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		session.Close()
		return SessionSnapshot{}, errors.New("WebRTC 隧道服务已经关闭")
	}
	s.hosts[session.id] = session
	s.mutex.Unlock()
	return session.snapshot(), nil
}

func (s *Service) ICEServersForSession(sessionID, playerID, identifier string) []ICEServer {
	result := s.localTURN.iceServers(sessionID, playerID, identifier)
	s.mutex.RLock()
	hosts := make([]*HostSession, 0, len(s.hosts))
	for _, host := range s.hosts {
		if host.sessionID == sessionID {
			hosts = append(hosts, host)
		}
	}
	s.mutex.RUnlock()
	for _, host := range hosts {
		if host.expiresAt.After(time.Now()) {
			result = append(result, host.credentials.ICEServers...)
			break
		}
	}
	return result
}

func (s *Service) CreateClient(ctx context.Context, request ClientRequest) (SessionSnapshot, error) {
	s.mutex.RLock()
	closed := s.closed
	s.mutex.RUnlock()
	if closed {
		return SessionSnapshot{}, errors.New("WebRTC 隧道服务已经关闭")
	}
	session, err := newClientSession(ctx, s.api, request.InvitationURI)
	if err != nil {
		return SessionSnapshot{}, err
	}
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		session.Close()
		return SessionSnapshot{}, errors.New("WebRTC 隧道服务已经关闭")
	}
	s.clients[session.id] = session
	s.mutex.Unlock()
	return session.snapshot(), nil
}

// ResolveConnectionMode 返回 Pion 实际选中候选对对应的连接方式。
// remoteAddress 必须来自抵达 Session HTTP 的真实 TCP 连接，不能采信请求字段。
func (s *Service) ResolveConnectionMode(remoteAddress string) (string, bool) {
	return s.registry.resolve(remoteAddress)
}

func (s *Service) Host(id string) (SessionSnapshot, error) {
	s.mutex.RLock()
	session := s.hosts[id]
	s.mutex.RUnlock()
	if session == nil {
		return SessionSnapshot{}, ErrSessionNotFound
	}
	return session.snapshot(), nil
}

func (s *Service) Client(id string) (SessionSnapshot, error) {
	s.mutex.RLock()
	session := s.clients[id]
	s.mutex.RUnlock()
	if session == nil {
		return SessionSnapshot{}, ErrSessionNotFound
	}
	return session.snapshot(), nil
}

func (s *Service) DeleteHost(id string) error {
	s.mutex.Lock()
	session := s.hosts[id]
	delete(s.hosts, id)
	s.mutex.Unlock()
	if session == nil {
		return ErrSessionNotFound
	}
	session.Close()
	return nil
}

func (s *Service) DeleteClient(id string) error {
	s.mutex.Lock()
	session := s.clients[id]
	delete(s.clients, id)
	s.mutex.Unlock()
	if session == nil {
		return ErrSessionNotFound
	}
	session.Close()
	return nil
}

func (s *Service) Close() {
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		return
	}
	s.closed = true
	hosts := make([]*HostSession, 0, len(s.hosts))
	for _, session := range s.hosts {
		hosts = append(hosts, session)
	}
	clients := make([]*ClientSession, 0, len(s.clients))
	for _, session := range s.clients {
		clients = append(clients, session)
	}
	s.hosts = make(map[string]*HostSession)
	s.clients = make(map[string]*ClientSession)
	s.mutex.Unlock()
	for _, session := range clients {
		session.Close()
	}
	for _, session := range hosts {
		session.Close()
	}
	s.localTURN.close()
}

func parseServerBaseURL(raw string) (*url.URL, error) {
	result, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (result.Scheme != "http" && result.Scheme != "https") || result.Host == "" ||
		result.User != nil || result.RawQuery != "" || result.Fragment != "" {
		return nil, errors.New("WebRTC 服务器地址无效")
	}
	result.Path = strings.TrimSuffix(result.Path, "/")
	return result, nil
}

func parseLoopbackTarget(raw string) (*url.URL, error) {
	result, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || result.Scheme != "http" || result.Host == "" || result.Port() == "" ||
		result.User != nil || result.RawQuery != "" || result.Fragment != "" {
		return nil, errors.New("本地目标地址无效")
	}
	ip := net.ParseIP(result.Hostname())
	if ip == nil || !ip.IsLoopback() {
		return nil, errors.New("本地目标必须使用回环地址")
	}
	result.Path = "/"
	return result, nil
}

type connectionRegistry struct {
	mutex sync.RWMutex
	modes map[string]string
}

func newConnectionRegistry() *connectionRegistry {
	return &connectionRegistry{modes: make(map[string]string)}
}

func (r *connectionRegistry) register(remoteAddress, mode string) {
	r.mutex.Lock()
	r.modes[remoteAddress] = mode
	r.mutex.Unlock()
}

func (r *connectionRegistry) remove(remoteAddress string) {
	r.mutex.Lock()
	delete(r.modes, remoteAddress)
	r.mutex.Unlock()
}

func (r *connectionRegistry) resolve(remoteAddress string) (string, bool) {
	r.mutex.RLock()
	mode, ok := r.modes[remoteAddress]
	r.mutex.RUnlock()
	return mode, ok
}
