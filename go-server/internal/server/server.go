package server

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"go-server/internal/admin"
	captchamodule "go-server/internal/captcha"
	"go-server/internal/catalog"
	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/middleware"
	"go-server/internal/packages"
	"go-server/internal/relay"
	"go-server/internal/store"
	"go-server/internal/user"
	"go-server/internal/webui"
)

type Server struct {
	// Engine remains the external App engine for compatibility with existing
	// embedders and tests.
	Engine        *gin.Engine
	AdminEngine   *gin.Engine
	manager       *relay.Manager
	store         *store.Store
	config        config.Config
	externalHTTP  *http.Server
	adminHTTP     *http.Server
	cleanupCancel context.CancelFunc
	cleanupDone   chan struct{}
	closeOnce     sync.Once
}

func New(cfg config.Config, logger *slog.Logger) (*Server, error) {
	if cfg.Auth.Token != "" && cfg.Auth.Token != cfg.Auth.PublishedToken {
		cfg.Auth.PublishedToken = cfg.Auth.Token
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	gin.SetMode(gin.ReleaseMode)
	database, err := store.Open(cfg.Storage, store.Settings{
		Name: cfg.Name, Author: cfg.Author, Homepage: cfg.Homepage,
		SupportsGameRelay:        cfg.SupportsGameRelay,
		AllowUserRegistration:    cfg.AllowUserRegistration,
		RequireEmailVerification: cfg.RequireEmailVerification,
	})
	if err != nil {
		return nil, err
	}
	manager := relay.NewManager(cfg.Relay)
	mailService := mailer.New(cfg.Mail)
	packageService := packages.New(cfg, database, mailService, logger)
	catalogHandler := catalog.New(cfg, database)
	relayHandler := relay.NewHandler(
		manager,
		middleware.NewIPLimiter(cfg.Relay.MaxConnectionsPerIP),
		logger,
	)
	captchaContext, cancelCaptcha := context.WithTimeout(
		context.Background(), 15*time.Second,
	)
	captchaService, err := captchamodule.New(
		captchaContext,
		captchamodule.Options{
			Mode:                 cfg.Admin.CaptchaMode,
			ImageSource:          cfg.Admin.CaptchaImageSource,
			LocalImageDirectory:  cfg.Admin.CaptchaImageDirectory,
			RemoteImageURL:       cfg.Admin.CaptchaImageURL,
			RemoteImageCacheSize: cfg.Admin.CaptchaImageCacheSize,
		},
		logger,
	)
	cancelCaptcha()
	if err != nil {
		_ = database.Close()
		return nil, err
	}
	authHandler := admin.NewAuthHandlerWithCaptchaService(
		cfg, database, captchaService,
	)
	userHandler := user.New(
		cfg, database, packageService, mailService, captchaService,
	)
	adminHandler := admin.NewHandler(
		cfg, database, packageService, mailService, manager,
		func(value string) {
			catalogHandler.UpdatePublicBaseURL(value)
			userHandler.UpdatePublicBaseURL(value)
		},
	)
	ui := webui.New(cfg.WebUI)

	external := gin.New()
	external.MaxMultipartMemory = 1 << 20
	if err := external.SetTrustedProxies(nil); err != nil {
		return nil, err
	}
	external.Use(gin.Recovery())
	external.Use(middleware.RequestID())
	external.Use(middleware.AccessLog(logger))
	external.Use(middleware.SecurityHeaders())
	external.Use(middleware.CORS())
	external.GET("/", ui.User)
	external.GET("/games", ui.User)
	external.GET("/my", ui.User)
	external.GET("/login", ui.User)
	external.GET("/register", ui.User)
	external.GET("/assets/:name", ui.UserAsset)
	external.GET("/i18n/manifest", ui.LocalizationManifest)
	external.GET("/i18n/:locale", ui.LocalizationBundle)
	external.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	sourceToken := middleware.CatalogToken(cfg.Auth)
	catalogToken := middleware.CatalogReadToken(cfg.Auth)
	appReadLimiter := middleware.NewWindowLimiter(60, time.Second)
	appDownloadLimiter := middleware.NewIntervalLimiter(time.Second)
	external.GET(
		"/apps/info",
		middleware.WindowRateLimit(appReadLimiter, "apps-info"),
		catalogToken,
		catalogHandler.Info,
	)
	external.GET(
		"/apps/list",
		middleware.WindowRateLimit(appReadLimiter, "apps-list"),
		catalogToken,
		catalogHandler.List,
	)
	external.GET(
		"/apps/download",
		middleware.RateLimit(appDownloadLimiter, "apps-download"),
		catalogToken,
		catalogHandler.Download,
	)
	external.GET(
		"/apps/icon",
		middleware.WindowRateLimit(appReadLimiter, "apps-icon"),
		catalogToken,
		catalogHandler.Icon,
	)

	publicListLimiter := middleware.NewIntervalLimiter(250 * time.Millisecond)
	publicDownloadLimiter := middleware.NewIntervalLimiter(time.Second)
	publicQRCodeLimiter := middleware.NewIntervalLimiter(time.Second)
	publicSourceInfoLimiter := middleware.NewIntervalLimiter(time.Second)
	external.GET(
		"/api/public/games",
		middleware.RateLimit(publicListLimiter, "public-list"),
		adminHandler.PublicGames,
	)

	userCaptchaLimiter := middleware.NewIntervalLimiter(
		time.Duration(cfg.Admin.CaptchaIntervalMilliseconds) * time.Millisecond,
	)
	userLoginLimiter := middleware.NewIntervalLimiter(
		time.Duration(cfg.Admin.LoginIntervalMilliseconds) * time.Millisecond,
	)
	userUploadLimiter := middleware.NewIntervalLimiter(30 * time.Second)
	external.GET("/api/user/config", userHandler.RegistrationState)
	external.GET(
		"/api/user/auth/captcha",
		middleware.RateLimit(userCaptchaLimiter, "user-captcha"),
		userHandler.Captcha,
	)
	external.POST(
		"/api/user/auth/captcha/verify",
		middleware.RateLimit(userLoginLimiter, "user-captcha-verify"),
		limitRequestBody(64<<10),
		userHandler.VerifyCaptcha,
	)
	external.POST(
		"/api/user/auth/register",
		middleware.RateLimit(userLoginLimiter, "user-register"),
		limitRequestBody(64<<10),
		userHandler.Register,
	)
	external.POST(
		"/api/user/auth/login",
		middleware.RateLimit(userLoginLimiter, "user-login"),
		limitRequestBody(64<<10),
		userHandler.Login,
	)
	external.GET("/api/user/auth/verify-email", userHandler.VerifyEmail)
	external.POST(
		"/api/user/auth/resend-verification",
		middleware.RateLimit(userLoginLimiter, "user-resend"),
		limitRequestBody(64<<10),
		userHandler.ResendVerification,
	)
	external.POST(
		"/api/user/uploads",
		middleware.RateLimit(userUploadLimiter, "user-upload"),
		limitRequestBody(cfg.Storage.MaxUploadBytes+(1<<20)),
		userHandler.RequireUploadKey(),
		userHandler.KeyUpload,
	)
	external.GET("/api/user/me", userHandler.RequireSession(false), userHandler.Me)
	external.PATCH(
		"/api/user/me",
		limitRequestBody(64<<10),
		userHandler.RequireSession(true),
		userHandler.UpdateMe,
	)
	external.POST(
		"/api/user/auth/logout",
		userHandler.RequireSession(true),
		userHandler.Logout,
	)
	external.PUT(
		"/api/user/upload-key",
		limitRequestBody(64<<10),
		userHandler.RequireSession(true),
		userHandler.PutUploadKey,
	)
	external.GET(
		"/api/user/upload-key",
		userHandler.RequireSession(false),
		userHandler.GetUploadKey,
	)
	external.GET(
		"/api/user/games",
		userHandler.RequireSession(false),
		userHandler.Games,
	)
	external.GET(
		"/api/user/notifications",
		userHandler.RequireSession(false),
		userHandler.Notifications,
	)
	external.POST(
		"/api/user/notifications/:id/read",
		userHandler.RequireSession(true),
		userHandler.ReadNotification,
	)
	external.POST(
		"/api/user/games/uploads",
		middleware.RateLimit(userUploadLimiter, "user-upload"),
		limitRequestBody(cfg.Storage.MaxUploadBytes+(1<<20)),
		userHandler.RequireSession(true),
		userHandler.BrowserUpload,
	)
	external.POST(
		"/api/user/games/:id/publish",
		userHandler.RequireSession(true),
		userHandler.Publish,
	)
	external.POST(
		"/api/user/games/:id/unpublish",
		userHandler.RequireSession(true),
		userHandler.Unpublish,
	)
	external.DELETE(
		"/api/user/games/by-package/:gameId",
		userHandler.RequireSession(true),
		userHandler.DeletePackage,
	)
	external.DELETE(
		"/api/user/games/:id",
		userHandler.RequireSession(true),
		userHandler.DeleteGame,
	)
	external.GET(
		"/api/public/source-qrcode",
		middleware.RateLimit(publicQRCodeLimiter, "public-source-qrcode"),
		adminHandler.PublicSourceQRCode,
	)
	external.GET(
		"/api/public/source-info",
		middleware.RateLimit(publicSourceInfoLimiter, "public-source-info"),
		adminHandler.PublicSourceInfo,
	)
	external.GET(
		"/api/public/games/:id/download",
		middleware.RateLimit(publicDownloadLimiter, "public-download"),
		adminHandler.PublicDownload,
	)

	if cfg.SupportsGameRelay {
		relayCreateLimiter := middleware.NewIntervalLimiter(time.Second)
		relayRequestLimiter := middleware.NewWindowLimiter(120, time.Second)
		external.POST(
			"/relay/v1/host",
			middleware.WindowRateLimit(relayRequestLimiter, "relay"),
			middleware.RateLimit(relayCreateLimiter, "relay-create"),
			sourceToken,
			relayHandler.Create,
		)
		external.GET(
			"/relay/v1/host",
			middleware.WindowRateLimit(relayRequestLimiter, "relay"),
			sourceToken,
			relayHandler.HostLease(),
			relayHandler.Host,
		)
		external.DELETE(
			"/relay/v1/host",
			middleware.WindowRateLimit(relayRequestLimiter, "relay"),
			sourceToken,
			relayHandler.HostLease(),
			relayHandler.Delete,
		)
		external.GET(
			"/relay/v1/client",
			middleware.WindowRateLimit(relayRequestLimiter, "relay"),
			sourceToken,
			relayHandler.ClientCapability(),
			relayHandler.Client,
		)
	}

	management := gin.New()
	management.MaxMultipartMemory = 1 << 20
	if err := management.SetTrustedProxies(nil); err != nil {
		return nil, err
	}
	management.Use(gin.Recovery())
	management.Use(middleware.RequestID())
	management.Use(middleware.AccessLog(logger))
	management.Use(middleware.SecurityHeaders())
	management.Use(middleware.NoStore())
	management.GET(cfg.AdminPath, ui.Admin)
	management.GET(cfg.AdminPath+"/assets/:name", ui.AdminAsset)
	management.GET(cfg.AdminPath+"/i18n/manifest", ui.LocalizationManifest)
	management.GET(cfg.AdminPath+"/i18n/:locale", ui.LocalizationBundle)

	captchaLimiter := middleware.NewIntervalLimiter(
		time.Duration(cfg.Admin.CaptchaIntervalMilliseconds) * time.Millisecond,
	)
	loginLimiter := middleware.NewIntervalLimiter(
		time.Duration(cfg.Admin.LoginIntervalMilliseconds) * time.Millisecond,
	)
	management.GET(
		cfg.AdminPath+"/api/auth/captcha",
		middleware.RateLimit(captchaLimiter, "captcha"),
		authHandler.Captcha,
	)
	management.POST(
		cfg.AdminPath+"/api/auth/captcha/verify",
		middleware.RateLimit(loginLimiter, "captcha-verify"),
		limitRequestBody(64<<10),
		authHandler.VerifyCaptcha,
	)
	management.POST(
		cfg.AdminPath+"/api/auth/login",
		middleware.RateLimit(loginLimiter, "login"),
		limitRequestBody(64<<10),
		authHandler.Login,
	)
	adminAPI := management.Group(cfg.AdminPath + "/api/admin")
	adminAPI.Use(authHandler.RequireSession())
	adminAPI.POST("/logout", authHandler.Logout)
	adminAPI.GET("/users", adminHandler.AdminUsers)
	adminAPI.POST(
		"/users", limitRequestBody(64<<10), adminHandler.AdminCreateUser,
	)
	adminAPI.PATCH(
		"/users/:id", limitRequestBody(64<<10), adminHandler.AdminUpdateUser,
	)
	adminAPI.DELETE("/users/:id", adminHandler.AdminDeleteUser)
	adminAPI.GET("/games", adminHandler.AdminGames)
	adminAPI.GET("/games/:id", adminHandler.AdminGame)
	adminAPI.PATCH(
		"/games/:id", limitRequestBody(64<<10), adminHandler.AdminUpdateGame,
	)
	adminAPI.DELETE(
		"/games/:id", limitRequestBody(64<<10), adminHandler.AdminDeleteGame,
	)
	adminAPI.POST("/games/:id/publish", adminHandler.AdminPublishGame)
	adminAPI.POST(
		"/games/:id/unpublish",
		limitRequestBody(64<<10),
		adminHandler.AdminUnpublishGame,
	)
	adminAPI.GET("/games/:id/download", adminHandler.AdminDownload)
	adminAPI.GET("/settings", adminHandler.Settings)
	adminAPI.PUT(
		"/settings", limitRequestBody(64<<10), adminHandler.UpdateSettings,
	)
	adminAPI.GET("/config", adminHandler.RuntimeConfig)
	adminAPI.PUT(
		"/config", limitRequestBody(2<<20), adminHandler.UpdateRuntimeConfig,
	)
	adminAPI.GET("/relay/stats", adminHandler.RelayStats)

	result := &Server{
		Engine: external, AdminEngine: management, manager: manager,
		store: database, config: cfg, cleanupDone: make(chan struct{}),
	}
	cleanupContext, cancelCleanup := context.WithCancel(context.Background())
	result.cleanupCancel = cancelCleanup
	go func() {
		defer close(result.cleanupDone)
		runCleanup := func() {
			completed, err := packageService.CleanupDeleting(cleanupContext)
			if err != nil && !errors.Is(err, context.Canceled) {
				logger.Warn("background artifact cleanup incomplete", "error", err)
			}
			if completed > 0 {
				logger.Info(
					"background deleting-record cleanup completed",
					"records", completed,
				)
			}
		}
		runCleanup()
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-cleanupContext.Done():
				return
			case <-ticker.C:
				runCleanup()
			}
		}
	}()
	return result, nil
}

func (s *Server) Run(address string) error {
	if address == "" {
		address = s.config.ExternalListen
	}
	s.externalHTTP = &http.Server{
		Addr: address,
		Handler: http.MaxBytesHandler(
			s.Engine, s.config.Storage.MaxUploadBytes+(1<<20),
		),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	s.adminHTTP = &http.Server{
		Addr: s.config.Admin.Listen,
		Handler: http.MaxBytesHandler(
			s.AdminEngine, s.config.Storage.MaxUploadBytes+(1<<20),
		),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	errorsChannel := make(chan error, 2)
	go func() { errorsChannel <- s.externalHTTP.ListenAndServe() }()
	go func() { errorsChannel <- s.adminHTTP.ListenAndServe() }()
	err := <-errorsChannel
	_ = s.shutdownHTTP()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (s *Server) Close() {
	s.closeOnce.Do(func() {
		_ = s.shutdownHTTP()
		s.manager.Close()
		if s.cleanupCancel != nil {
			s.cleanupCancel()
		}
		if s.cleanupDone != nil {
			<-s.cleanupDone
		}
		_ = s.store.Close()
	})
}

func (s *Server) shutdownHTTP() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var result error
	if s.externalHTTP != nil {
		result = s.externalHTTP.Shutdown(ctx)
	}
	if s.adminHTTP != nil {
		if err := s.adminHTTP.Shutdown(ctx); result == nil {
			result = err
		}
	}
	return result
}

func limitRequestBody(maximum int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maximum)
		c.Next()
	}
}

func DiscardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
