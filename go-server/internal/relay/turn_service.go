package relay

import (
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v4"

	"go-server/internal/config"
)

type TURNService struct {
	server *turn.Server
	once   sync.Once
	err    error
}

func StartTURN(cfg config.Relay) (*TURNService, error) {
	publicIP := net.ParseIP(cfg.TURNPublicIP).To4()
	udpListener, err := net.ListenPacket("udp4", cfg.TURNUDPListen)
	if err != nil {
		return nil, fmt.Errorf("监听 TURN UDP %s: %w", cfg.TURNUDPListen, err)
	}
	tcpListener, err := net.Listen("tcp4", cfg.TURNTCPListen)
	if err != nil {
		_ = udpListener.Close()
		return nil, fmt.Errorf("监听 TURN TCP %s: %w", cfg.TURNTCPListen, err)
	}
	newGenerator := func() *turn.RelayAddressGeneratorPortRange {
		return &turn.RelayAddressGeneratorPortRange{
			RelayAddress: publicIP,
			Address:      "0.0.0.0",
			MinPort:      uint16(cfg.TURNMinPort),
			MaxPort:      uint16(cfg.TURNMaxPort),
			MaxRetries:   32,
		}
	}
	server, err := turn.NewServer(turn.ServerConfig{
		Realm:         cfg.TURNRealm,
		AuthHandler:   turn.LongTermTURNRESTAuthHandler(cfg.TURNSharedSecret, nil),
		LoggerFactory: logging.NewDefaultLoggerFactory(),
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: udpListener, RelayAddressGenerator: newGenerator(),
		}},
		ListenerConfigs: []turn.ListenerConfig{{
			Listener: tcpListener, RelayAddressGenerator: newGenerator(),
		}},
	})
	if err != nil {
		_ = tcpListener.Close()
		_ = udpListener.Close()
		return nil, fmt.Errorf("启动 Pion TURN: %w", err)
	}
	return &TURNService{server: server}, nil
}

func (s *TURNService) Close() error {
	if s == nil || s.server == nil {
		return nil
	}
	s.once.Do(func() { s.err = s.server.Close() })
	return s.err
}

func turnICEServers(cfg config.Relay, user string, ttl time.Duration) ([]ICEServer, error) {
	username, credential, err := turn.GenerateLongTermTURNRESTCredentials(
		cfg.TURNSharedSecret,
		user,
		ttl,
	)
	if err != nil {
		return nil, err
	}
	hostPort := net.JoinHostPort(cfg.TURNPublicIP, strconv.Itoa(cfg.TURNPublicPort))
	return []ICEServer{
		{URLs: []string{"stun:" + hostPort}},
		{
			URLs: []string{
				"turn:" + hostPort + "?transport=udp",
				"turn:" + hostPort + "?transport=tcp",
			},
			Username: username, Credential: credential,
		},
	}, nil
}
