package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"
)

type Server struct {
	address    string
	httpServer *http.Server
	logger     *slog.Logger
	errors     chan error
	listener   net.Listener
	mutex      sync.RWMutex
}

func New(address string, handler http.Handler, logger *slog.Logger) *Server {
	return &Server{
		address: address,
		httpServer: &http.Server{
			Handler:           handler,
			ReadHeaderTimeout: 5 * time.Second,
			IdleTimeout:       30 * time.Second,
		},
		logger: logger,
		errors: make(chan error, 1),
	}
}

func (s *Server) Start() error {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	if s.listener != nil {
		return errors.New("Go Core 已经启动")
	}

	listener, err := net.Listen("tcp", s.address)
	if err != nil {
		return fmt.Errorf("监听 %s 失败: %w", s.address, err)
	}
	s.listener = listener

	s.logger.Info(
		"Go Core 已启动",
		"component", "core-lifecycle",
		"event", "core.started",
		"address", listener.Addr().String(),
	)

	go func() {
		err := s.httpServer.Serve(listener)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		s.errors <- err
	}()

	return nil
}

func (s *Server) Address() string {
	s.mutex.RLock()
	defer s.mutex.RUnlock()

	if s.listener == nil {
		return ""
	}
	return s.listener.Addr().String()
}

func (s *Server) Errors() <-chan error {
	return s.errors
}

func (s *Server) Shutdown(ctx context.Context) error {
	s.logger.Info(
		"Go Core 正在停止",
		"component", "core-lifecycle",
		"event", "core.stopping",
	)

	if err := s.httpServer.Shutdown(ctx); err != nil {
		return fmt.Errorf("停止 Go Core 失败: %w", err)
	}

	s.logger.Info(
		"Go Core 已停止",
		"component", "core-lifecycle",
		"event", "core.stopped",
	)
	return nil
}
