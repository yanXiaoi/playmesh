package mobile

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"sync"
	"time"

	"go-core/internal/health"
	"go-core/internal/server"
	"go-core/internal/session"
)

const coreVersion = "0.3.0"

var (
	coreMutex   sync.RWMutex
	coreServer  *server.Server
	coreAddress string
	coreLogger  = slog.New(slog.NewJSONHandler(os.Stdout, nil))
)

func Start(address string) (string, error) {
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
	instance := server.New(address, server.NewRouter(healthHandler, sessionHandler), coreLogger)
	if err := instance.Start(); err != nil {
		return "", err
	}

	coreServer = instance
	coreAddress = instance.Address()
	return coreAddress, nil
}

func Stop() error {
	coreMutex.Lock()
	instance := coreServer
	coreServer = nil
	coreAddress = ""
	coreMutex.Unlock()

	if instance == nil {
		return nil
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
