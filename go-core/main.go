package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"go-core/internal/health"
	"go-core/internal/server"
	"go-core/internal/session"
	"go-core/internal/webrtctunnel"
)

const coreVersion = "0.7.0"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	address := flag.String("addr", "127.0.0.1:0", "Go Core HTTP 监听地址")
	parentPID := flag.Int("parent-pid", 0, "父进程 ID；父进程退出时自动关闭")
	localTURNAddresses := flag.String("local-turn-addresses", "", "Flutter 已验证可绑定的局域网 IPv4 地址，逗号分隔")
	flag.Parse()

	signalCtx, stop := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()
	ctx, cancel := context.WithCancel(signalCtx)
	defer cancel()
	if *parentPID > 0 {
		go func() {
			<-watchParent(*parentPID)
			logger.Info(
				"父进程已退出，关闭 Go Core",
				"component", "core-lifecycle",
				"event", "core.parent_exited",
				"parentPid", *parentPID,
			)
			cancel()
		}()
	}

	if err := run(ctx, *address, splitLocalTURNAddresses(*localTURNAddresses), logger); err != nil {
		logger.Error(
			"Go Core 运行失败",
			"component", "core-lifecycle",
			"event", "core.failed",
			"error", err,
		)
		os.Exit(1)
	}
}

func run(ctx context.Context, address string, localTURNAddresses []string, logger *slog.Logger) error {
	startedAt := time.Now().UTC()
	healthService := health.NewService(coreVersion, startedAt)
	healthHandler := health.NewHandler(healthService, logger)
	sessionHandler := session.NewHandler(session.NewStore(), logger)
	tunnelService := webrtctunnel.NewServiceWithLocalTURNAddresses(localTURNAddresses, logger)
	defer tunnelService.Close()
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
	tunnelHandler := webrtctunnel.NewHandler(tunnelService, logger)
	mux := server.NewRouter(healthHandler, sessionHandler, tunnelHandler)
	coreServer := server.New(address, mux, logger)
	if err := coreServer.Start(); err != nil {
		return err
	}

	select {
	case err := <-coreServer.Errors():
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		if err := coreServer.Shutdown(shutdownCtx); err != nil {
			return err
		}

		return <-coreServer.Errors()
	}
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
