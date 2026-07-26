package main

import (
	"log/slog"
	"os"

	"go-server/internal/config"
	"go-server/internal/server"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := config.Load("server.json")
	if err != nil {
		logger.Error("加载配置失败", "error", err)
		os.Exit(1)
	}
	app, err := server.New(cfg, logger)
	if err != nil {
		logger.Error("初始化服务失败", "error", err)
		os.Exit(1)
	}
	defer app.Close()
	logger.Info("Playmesh 游戏源服务启动",
		"externalListen", cfg.ExternalListen,
		"adminListen", cfg.Admin.Listen,
	)
	if err := app.Run(cfg.ExternalListen); err != nil {
		logger.Error("服务退出", "error", err)
		os.Exit(1)
	}
}
