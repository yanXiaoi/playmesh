package relay

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"go-server/internal/config"
)

var (
	ErrTunnelNotFound  = errors.New("隧道不存在或已过期")
	ErrTunnelLimit     = errors.New("隧道数量已达上限")
	ErrConnectionLimit = errors.New("隧道连接数量已达上限")
	ErrHostUnavailable = errors.New("主机暂时没有可用连接")
	ErrUnauthorized    = errors.New("隧道凭证无效")
)

type Credentials struct {
	TunnelID       string    `json:"tunnelId"`
	HostLease      string    `json:"hostLease"`
	JoinCapability string    `json:"joinCapability"`
	ExpiresAt      time.Time `json:"expiresAt"`
}

type Manager struct {
	config  config.Relay
	mutex   sync.RWMutex
	tunnels map[string]*Tunnel
	stop    chan struct{}
}

type Tunnel struct {
	id             string
	hostLeaseHash  [32]byte
	capabilityHash [32]byte
	expiresAt      time.Time
	maxConnections int

	mutex       sync.Mutex
	closed      bool
	pending     chan net.Conn
	connections map[net.Conn]struct{}
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
		tunnel.close()
	}
}

func (m *Manager) Create() (Credentials, error) {
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
	expiresAt := time.Now().Add(m.config.TunnelTTL())
	m.tunnels[tunnelID] = &Tunnel{
		id:             tunnelID,
		hostLeaseHash:  sha256.Sum256([]byte(hostLease)),
		capabilityHash: sha256.Sum256([]byte(capability)),
		expiresAt:      expiresAt,
		maxConnections: m.config.MaxConnectionsPerTunnel,
		pending:        make(chan net.Conn, m.config.MaxConnectionsPerTunnel),
		connections:    make(map[net.Conn]struct{}),
	}
	return Credentials{
		TunnelID: tunnelID, HostLease: hostLease,
		JoinCapability: capability, ExpiresAt: expiresAt.UTC(),
	}, nil
}

func (m *Manager) AuthenticateHost(id, lease string) (*Tunnel, error) {
	tunnel, err := m.get(id)
	if err != nil {
		return nil, err
	}
	if sha256.Sum256([]byte(lease)) != tunnel.hostLeaseHash {
		return nil, ErrUnauthorized
	}
	return tunnel, nil
}

func (m *Manager) AuthenticateClient(id, capability string) (*Tunnel, error) {
	tunnel, err := m.get(id)
	if err != nil {
		return nil, err
	}
	if sha256.Sum256([]byte(capability)) != tunnel.capabilityHash {
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
	tunnel.close()
}

func (m *Manager) get(id string) (*Tunnel, error) {
	m.mutex.RLock()
	tunnel := m.tunnels[id]
	m.mutex.RUnlock()
	if tunnel == nil || time.Now().After(tunnel.expiresAt) {
		if tunnel != nil {
			m.Delete(id, tunnel)
		}
		return nil, ErrTunnelNotFound
	}
	return tunnel, nil
}

func (m *Manager) AddHost(tunnel *Tunnel, conn net.Conn) error {
	if !tunnel.add(conn) {
		return ErrConnectionLimit
	}
	select {
	case tunnel.pending <- conn:
		return nil
	default:
		tunnel.remove(conn)
		return ErrConnectionLimit
	}
}

func (m *Manager) PairClient(tunnel *Tunnel, client net.Conn) error {
	if !tunnel.add(client) {
		return ErrConnectionLimit
	}
	timer := time.NewTimer(m.config.PendingConnectionTimeout())
	defer timer.Stop()
	var host net.Conn
	select {
	case host = <-tunnel.pending:
	case <-timer.C:
		tunnel.remove(client)
		return ErrHostUnavailable
	}
	go m.pipe(tunnel, host, client)
	return nil
}

func (m *Manager) pipe(tunnel *Tunnel, host, client net.Conn) {
	hostConnection := host
	clientConnection := client
	host = &idleConn{Conn: hostConnection, timeout: m.config.IdleTimeout()}
	client = &idleConn{Conn: clientConnection, timeout: m.config.IdleTimeout()}
	var once sync.Once
	closePair := func() {
		once.Do(func() {
			tunnel.remove(hostConnection)
			tunnel.remove(clientConnection)
		})
	}
	copyOne := func(destination, source net.Conn) {
		_, _ = io.Copy(destination, source)
		closePair()
	}
	go copyOne(host, client)
	copyOne(client, host)
}

// idleConn 在每次读写时刷新超时，避免活跃的大文件传输被固定截止时间中断。
type idleConn struct {
	net.Conn
	timeout time.Duration
}

func (c *idleConn) Read(buffer []byte) (int, error) {
	_ = c.Conn.SetReadDeadline(time.Now().Add(c.timeout))
	return c.Conn.Read(buffer)
}

func (c *idleConn) Write(buffer []byte) (int, error) {
	_ = c.Conn.SetWriteDeadline(time.Now().Add(c.timeout))
	return c.Conn.Write(buffer)
}

func (t *Tunnel) add(conn net.Conn) bool {
	t.mutex.Lock()
	defer t.mutex.Unlock()
	if t.closed || len(t.connections) >= t.maxConnections*2 {
		return false
	}
	t.connections[conn] = struct{}{}
	return true
}

func (t *Tunnel) remove(conn net.Conn) {
	t.mutex.Lock()
	delete(t.connections, conn)
	t.mutex.Unlock()
	_ = conn.Close()
}

func (t *Tunnel) close() {
	t.mutex.Lock()
	if t.closed {
		t.mutex.Unlock()
		return
	}
	t.closed = true
	connections := make([]net.Conn, 0, len(t.connections))
	for conn := range t.connections {
		connections = append(connections, conn)
	}
	t.connections = make(map[net.Conn]struct{})
	t.mutex.Unlock()
	for _, conn := range connections {
		_ = conn.Close()
	}
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
				if now.After(tunnel.expiresAt) {
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
