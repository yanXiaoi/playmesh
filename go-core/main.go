package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go-core/internal/health"
	"go-core/internal/server"
	"go-core/internal/session"
)

const coreVersion = "0.3.0"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	address := flag.String("addr", "127.0.0.1:0", "Go Core HTTP 监听地址")
	parentPID := flag.Int("parent-pid", 0, "父进程 ID；父进程退出时自动关闭")
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

	if err := run(ctx, *address, logger); err != nil {
		logger.Error(
			"Go Core 运行失败",
			"component", "core-lifecycle",
			"event", "core.failed",
			"error", err,
		)
		os.Exit(1)
	}
}

func run(ctx context.Context, address string, logger *slog.Logger) error {
	startedAt := time.Now().UTC()
	healthService := health.NewService(coreVersion, startedAt)
	healthHandler := health.NewHandler(healthService, logger)
	sessionHandler := session.NewHandler(session.NewStore(), logger)
	mux := server.NewRouter(healthHandler, sessionHandler)
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
