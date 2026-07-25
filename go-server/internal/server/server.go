package server

import (
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"go-server/internal/catalog"
	"go-server/internal/config"
	"go-server/internal/middleware"
	"go-server/internal/relay"
)

type Server struct {
	Engine  *gin.Engine
	manager *relay.Manager
}

func New(cfg config.Config, logger *slog.Logger) (*Server, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	gin.SetMode(gin.ReleaseMode)
	engine := gin.New()
	engine.Use(gin.Recovery())
	engine.Use(middleware.RequestID())
	engine.Use(middleware.AccessLog(logger))
	engine.Use(middleware.CORS())
	engine.Use(middleware.SourceToken(cfg.Auth))

	manager := relay.NewManager(cfg.Relay)
	relayHandler := relay.NewHandler(
		manager,
		middleware.NewIPLimiter(cfg.Relay.MaxConnectionsPerIP),
		logger,
	)
	catalogHandler := catalog.New(cfg)

	engine.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	engine.GET("/apps/info", catalogHandler.Info)
	engine.GET("/apps/list", catalogHandler.List)
	engine.GET("/apps/download", catalogHandler.Download)

	if cfg.SupportsGameRelay {
		engine.POST("/relay/v1/host", relayHandler.Create)
		engine.GET("/relay/v1/host", relayHandler.HostLease(), relayHandler.Host)
		engine.DELETE("/relay/v1/host", relayHandler.HostLease(), relayHandler.Delete)
		engine.GET(
			"/relay/v1/client",
			relayHandler.ClientCapability(),
			relayHandler.Client,
		)
	}

	return &Server{Engine: engine, manager: manager}, nil
}

func (s *Server) Run(address string) error {
	defer s.manager.Close()
	httpServer := &http.Server{
		Addr:              address,
		Handler:           http.MaxBytesHandler(s.Engine, 64*1024),
		ReadHeaderTimeout: 10 * time.Second,
	}
	return httpServer.ListenAndServe()
}

func (s *Server) Close() {
	s.manager.Close()
}

func DiscardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
