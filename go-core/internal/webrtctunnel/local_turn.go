package webrtctunnel

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

const (
	localTURNRealm                  = "playmesh.local"
	localTURNCredentialTTL          = 6 * time.Hour
	localTURNRetryInterval          = 5 * time.Second
	localTURNMaxAllocations         = 256
	localTURNMaxAllocationsPerUser  = 4
	localTURNAllocationLifetime     = 10 * time.Minute
	localTURNPermissionLifetime     = 5 * time.Minute
	localTURNChannelBindingLifetime = 5 * time.Minute
)

type localTURNEndpoint struct {
	ip      net.IP
	udpPort int
	tcpPort int
}

type localTURNService struct {
	logger    *slog.Logger
	addresses []net.IP

	mutex       sync.Mutex
	server      *turn.Server
	endpoints   []localTURNEndpoint
	secret      string
	lastAttempt time.Time
	lastError   error
	closed      bool
	allocations map[string]int
	total       int
}

func newLocalTURNService(logger *slog.Logger, addressValues []string) *localTURNService {
	if logger == nil {
		logger = slog.Default()
	}
	return &localTURNService{
		logger: logger, addresses: parseLocalTURNAddresses(addressValues),
		allocations: make(map[string]int),
	}
}

func (s *localTURNService) iceServers(sessionID, playerID, identifier string) []ICEServer {
	if err := s.ensureStarted(); err != nil {
		return nil
	}
	s.mutex.Lock()
	endpoints := append([]localTURNEndpoint(nil), s.endpoints...)
	secret := s.secret
	s.mutex.Unlock()
	if len(endpoints) == 0 || secret == "" {
		return nil
	}

	identity := sha256.Sum256([]byte(sessionID + "\x00" + playerID + "\x00" + identifier))
	username, credential, err := turn.GenerateLongTermTURNRESTCredentials(
		secret,
		base64.RawURLEncoding.EncodeToString(identity[:18]),
		localTURNCredentialTTL,
	)
	if err != nil {
		s.logger.Warn(
			"签发局域网 TURN 凭据失败",
			"component", "local-turn",
			"event", "local_turn.credential_failed",
			"error", err,
		)
		return nil
	}

	stunURLs := make([]string, 0, len(endpoints))
	turnURLs := make([]string, 0, len(endpoints)*2)
	for _, endpoint := range endpoints {
		udpAddress := net.JoinHostPort(endpoint.ip.String(), strconv.Itoa(endpoint.udpPort))
		stunURLs = append(stunURLs, "stun:"+udpAddress)
		turnURLs = append(turnURLs, "turn:"+udpAddress+"?transport=udp")
		if endpoint.tcpPort != 0 {
			tcpAddress := net.JoinHostPort(endpoint.ip.String(), strconv.Itoa(endpoint.tcpPort))
			turnURLs = append(turnURLs, "turn:"+tcpAddress+"?transport=tcp")
		}
	}
	return []ICEServer{
		{URLs: stunURLs},
		{URLs: turnURLs, Username: username, Credential: credential},
	}
}

func (s *localTURNService) ensureStarted() error {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if s.closed {
		return errors.New("局域网 TURN 服务已经关闭")
	}
	if s.server != nil {
		return nil
	}
	if s.lastError != nil && time.Since(s.lastAttempt) < localTURNRetryInterval {
		return s.lastError
	}
	s.lastAttempt = time.Now()

	addresses := append([]net.IP(nil), s.addresses...)
	if len(addresses) == 0 {
		return s.recordStartErrorLocked(errors.New("Flutter 未提供可绑定的局域网 IPv4 地址"))
	}
	secretBytes := make([]byte, 32)
	if _, err := rand.Read(secretBytes); err != nil {
		return s.recordStartErrorLocked(fmt.Errorf("生成 TURN 共享密钥: %w", err))
	}

	packetConfigs := make([]turn.PacketConnConfig, 0, len(addresses))
	listenerConfigs := make([]turn.ListenerConfig, 0, len(addresses))
	endpoints := make([]localTURNEndpoint, 0, len(addresses))
	openedPackets := make([]net.PacketConn, 0, len(addresses))
	openedListeners := make([]net.Listener, 0, len(addresses))
	permissionHandler := func(_ net.Addr, peerIP net.IP) bool {
		return isAllowedLocalTURNPeerIPv4(peerIP)
	}

	for _, address := range addresses {
		ip := address.To4()
		if ip == nil {
			continue
		}
		packet, listenErr := net.ListenPacket("udp4", net.JoinHostPort(ip.String(), "0"))
		if listenErr != nil {
			continue
		}
		udpAddress, ok := packet.LocalAddr().(*net.UDPAddr)
		if !ok {
			_ = packet.Close()
			continue
		}
		listener, listenErr := net.Listen(
			"tcp4",
			net.JoinHostPort(ip.String(), strconv.Itoa(udpAddress.Port)),
		)
		if listenErr != nil {
			listener, listenErr = net.Listen("tcp4", net.JoinHostPort(ip.String(), "0"))
		}
		tcpPort := 0
		if listenErr == nil {
			tcpPort = listener.Addr().(*net.TCPAddr).Port
			openedListeners = append(openedListeners, listener)
			listenerConfigs = append(listenerConfigs, turn.ListenerConfig{
				Listener: listener,
				RelayAddressGenerator: &turn.RelayAddressGeneratorNone{
					Address: ip.String(),
				},
				PermissionHandler: permissionHandler,
			})
		}
		openedPackets = append(openedPackets, packet)
		packetConfigs = append(packetConfigs, turn.PacketConnConfig{
			PacketConn: packet,
			RelayAddressGenerator: &turn.RelayAddressGeneratorNone{
				Address: ip.String(),
			},
			PermissionHandler: permissionHandler,
		})
		endpoints = append(endpoints, localTURNEndpoint{
			ip: append(net.IP(nil), ip...), udpPort: udpAddress.Port, tcpPort: tcpPort,
		})
	}
	if len(packetConfigs) == 0 {
		return s.recordStartErrorLocked(errors.New("局域网 IPv4 地址均无法监听 UDP"))
	}

	secret := base64.RawURLEncoding.EncodeToString(secretBytes)
	server, err := turn.NewServer(turn.ServerConfig{
		Realm:       localTURNRealm,
		AuthHandler: turn.LongTermTURNRESTAuthHandler(secret, nil),
		QuotaHandler: func(userID, _ string, _ net.Addr) bool {
			s.mutex.Lock()
			defer s.mutex.Unlock()
			return s.total < localTURNMaxAllocations &&
				s.allocations[userID] < localTURNMaxAllocationsPerUser
		},
		EventHandler: turn.EventHandler{
			OnAllocationCreated: func(_, _ net.Addr, _, userID, _ string, _ net.Addr, _ int) {
				s.mutex.Lock()
				s.allocations[userID]++
				s.total++
				s.mutex.Unlock()
			},
			OnAllocationDeleted: func(_, _ net.Addr, _, userID, _ string) {
				s.mutex.Lock()
				if s.allocations[userID] > 1 {
					s.allocations[userID]--
				} else {
					delete(s.allocations, userID)
				}
				if s.total > 0 {
					s.total--
				}
				s.mutex.Unlock()
			},
		},
		PacketConnConfigs:  packetConfigs,
		ListenerConfigs:    listenerConfigs,
		LoggerFactory:      logging.NewDefaultLoggerFactory(),
		AllocationLifetime: localTURNAllocationLifetime,
		PermissionTimeout:  localTURNPermissionLifetime,
		ChannelBindTimeout: localTURNChannelBindingLifetime,
	})
	if err != nil {
		for _, listener := range openedListeners {
			_ = listener.Close()
		}
		for _, packet := range openedPackets {
			_ = packet.Close()
		}
		return s.recordStartErrorLocked(fmt.Errorf("启动 Pion TURN: %w", err))
	}
	s.server = server
	s.endpoints = endpoints
	s.secret = secret
	s.lastError = nil
	s.logger.Info(
		"Go Core 局域网 STUN/TURN 已启动",
		"component", "local-turn",
		"event", "local_turn.started",
		"interfaceCount", len(endpoints),
	)
	return nil
}

func (s *localTURNService) recordStartErrorLocked(err error) error {
	s.lastError = err
	s.logger.Warn(
		"Go Core 局域网 STUN/TURN 暂不可用",
		"component", "local-turn",
		"event", "local_turn.unavailable",
		"error", err,
	)
	return err
}

func (s *localTURNService) close() {
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		return
	}
	s.closed = true
	server := s.server
	s.server = nil
	s.endpoints = nil
	s.secret = ""
	s.mutex.Unlock()
	if server != nil {
		_ = server.Close()
	}
}

func parseLocalTURNAddresses(values []string) []net.IP {
	result := make([]net.IP, 0, len(values))
	seen := make(map[string]struct{})
	for _, value := range values {
		ip := net.ParseIP(value).To4()
		if ip == nil || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
			continue
		}
		key := ip.String()
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, append(net.IP(nil), ip...))
	}
	return result
}

func isAllowedLocalTURNPeerIPv4(ip net.IP) bool {
	value := ip.To4()
	if value == nil || value.IsUnspecified() || value.IsMulticast() || value.IsLinkLocalUnicast() {
		return false
	}
	return value.IsLoopback() || value.IsPrivate() ||
		(value[0] == 100 && value[1] >= 64 && value[1] <= 127) ||
		(value[0] == 198 && (value[1] == 18 || value[1] == 19))
}
