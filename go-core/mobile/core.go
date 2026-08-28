package mobile

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"go-core/internal/health"
	"go-core/internal/server"
	"go-core/internal/session"
	"go-core/internal/webrtctunnel"
)

const coreVersion = "0.7.0"

var (
	coreMutex         sync.RWMutex
	coreServer        *server.Server
	coreTunnelService *webrtctunnel.Service
	coreAddress       string
	coreLogger        = slog.New(slog.NewJSONHandler(os.Stdout, nil))
)

func Start(address string) (string, error) {
	return StartWithLocalTURNAddresses(address, "")
}

func StartWithLocalTURNAddresses(address string, localTURNAddresses string) (string, error) {
	coreMutex.Lock()
	defer coreMutex.Unlock()

	if coreServer != nil {
		return coreAddress, nil
	}
	if address == "" {
		address = "127.0.0.1:0"
	}

	startedAt := time.Now().UTC()
	healthService := health.NewService(coreVersion, startedAt)
	healthHandler := health.NewHandler(healthService, coreLogger)
	sessionHandler := session.NewHandler(session.NewStore(), coreLogger)
	tunnelService := webrtctunnel.NewServiceWithLocalTURNAddresses(
		splitLocalTURNAddresses(localTURNAddresses),
		coreLogger,
	)
	sessionHandler.SetConnectionModeResolver(tunnelService.ResolveConnectionMode)
	sessionHandler.SetWebRTCICEServerProvider(func(sessionID, playerID, identifier string) []session.WebRTCICEServer {
		servers := tunnelService.ICEServersForSession(sessionID, playerID, identifier)
		result := make([]session.WebRTCICEServer, 0, len(servers))
		for _, server := range servers {
			result = append(result, session.WebRTCICEServer{
				URLs: server.URLs, Username: server.Username, Credential: server.Credential,
			})
		}
		return result
	})
	tunnelHandler := webrtctunnel.NewHandler(tunnelService, coreLogger)
	instance := server.New(address, server.NewRouter(healthHandler, sessionHandler, tunnelHandler), coreLogger)
	if err := instance.Start(); err != nil {
		tunnelService.Close()
		return "", err
	}

	coreServer = instance
	coreTunnelService = tunnelService
	coreAddress = instance.Address()
	return coreAddress, nil
}

func splitLocalTURNAddresses(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if address := strings.TrimSpace(part); address != "" {
			result = append(result, address)
		}
	}
	return result
}

func Stop() error {
	coreMutex.Lock()
	instance := coreServer
	tunnelService := coreTunnelService
	coreServer = nil
	coreTunnelService = nil
	coreAddress = ""
	coreMutex.Unlock()

	if instance == nil {
		return nil
	}
	if tunnelService != nil {
		tunnelService.Close()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := instance.Shutdown(ctx); err != nil {
		return err
	}

	select {
	case err := <-instance.Errors():
		return err
	case <-ctx.Done():
		return errors.New("等待 Go Core 停止超时")
	}
}

func IsRunning() bool {
	coreMutex.RLock()
	defer coreMutex.RUnlock()
	return coreServer != nil
}

func Address() string {
	coreMutex.RLock()
	defer coreMutex.RUnlock()
	return coreAddress
}
