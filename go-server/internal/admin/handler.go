package admin

import (
	"bytes"
	"errors"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
	qrcode "github.com/yeqown/go-qrcode/v2"
	"github.com/yeqown/go-qrcode/writer/standard"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/packages"
	"go-server/internal/relay"
	"go-server/internal/store"
)

type Handler struct {
	config              config.Config
	store               *store.Store
	packages            *packages.Service
	mailer              *mailer.Mailer
	relay               *relay.Manager
	gamesDir            string
	scanSlots           chan struct{}
	mutex               sync.RWMutex
	updatePublicBaseURL func(string)
}

type bufferWriteCloser struct {
	*bytes.Buffer
}

func (bufferWriteCloser) Close() error { return nil }

func NewHandler(
	cfg config.Config,
	database *store.Store,
	packageService *packages.Service,
	mailService *mailer.Mailer,
	relayManager *relay.Manager,
	updatePublicBaseURL func(string),
) *Handler {
	return &Handler{
		config: cfg, store: database, packages: packageService,
		mailer: mailService, relay: relayManager,
		gamesDir:            cfg.Storage.GamesDirectory,
		scanSlots:           make(chan struct{}, cfg.Storage.MaxConcurrentScans),
		updatePublicBaseURL: updatePublicBaseURL,
	}
}

func (h *Handler) PublicUpload(c *gin.Context) {
	select {
	case h.scanSlots <- struct{}{}:
		defer func() { <-h.scanSlots }()
	default:
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": "scanner_busy", "message": "安全扫描任务已满，请稍后重试",
		})
		return
	}
	header, err := c.FormFile("package")
	if c.Request.MultipartForm != nil {
		defer c.Request.MultipartForm.RemoveAll()
	}
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "package_required", "message": "请选择 ZIP 游戏包",
		})
		return
	}
	file, err := header.Open()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "package_invalid", "message": "无法读取上传文件",
		})
		return
	}
	defer file.Close()
	game, err := h.packages.ProcessUpload(
		c.Request.Context(), file, header.Filename, c.PostForm("email"),
	)
	var rejected *packages.RejectedError
	var input *packages.InputError
	switch {
	case errors.As(err, &rejected):
		c.JSON(http.StatusUnprocessableEntity, gin.H{
			"error": "package_rejected", "message": rejected.Reason,
			"recordId": rejected.Game.ID,
		})
	case errors.As(err, &input):
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "upload_invalid", "message": input.Reason,
		})
	case err != nil:
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "upload_failed", "message": "上传处理失败，请稍后重试",
		})
	default:
		c.JSON(http.StatusAccepted, gin.H{
			"id": game.ID, "packageId": game.PackageID,
			"status": game.Status, "message": "上传成功，等待管理员审核",
		})
	}
}

func (h *Handler) PublicGames(c *gin.Context) {
	status := strings.TrimSpace(c.DefaultQuery("status", store.StatusApproved))
	page, ok := positiveQuery(c, "page", 1, 1, 1<<31-1)
	if !ok {
		return
	}
	for _, name := range []string{"id", "name", "author"} {
		if len(c.Query(name)) > 256 {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": "invalid_request", "message": name + " 过长",
			})
			return
		}
	}
	size, ok := positiveQuery(c, "size", 12, 1, 50)
	if !ok {
		return
	}
	result, err := h.store.ListPublicGames(c.Request.Context(), store.PublicGameQuery{
		Status: status, PackageID: c.Query("id"), Name: c.Query("name"),
		Author: c.Query("author"), FromTime: int64Query(c, "from"),
		ToTime: int64Query(c, "to"), Sort: c.Query("sort"),
		Order: c.Query("order"), Page: page, Size: size,
	})
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "query_failed", "message": err.Error(),
		})
		return
	}
	items := make([]gin.H, 0, len(result.Data))
	for _, game := range result.Data {
		item := gin.H{
			"recordId": game.ID, "id": game.PackageID, "name": game.Name,
			"author": game.Author, "version": game.Version,
			"remarks": game.Remarks, "status": game.Status,
			"createdAt": game.CreatedAt,
		}
		if game.Status == store.StatusApproved {
			item["downloadUrl"] = "/api/public/games/" +
				strconv.FormatInt(game.ID, 10) + "/download"
		}
		items = append(items, item)
	}
	c.JSON(http.StatusOK, gin.H{
		"total": result.Total, "current": page, "size": size, "data": items,
	})
}

func (h *Handler) PublicSourceQRCode(c *gin.Context) {
	h.mutex.RLock()
	enabled := h.config.ShowPublicSourceQRCode
	baseURL := strings.TrimRight(strings.TrimSpace(h.config.Relay.PublicBaseURL), "/")
	token := h.config.Auth.PublishedToken
	h.mutex.RUnlock()
	if !enabled || baseURL == "" || token == "" {
		c.Status(http.StatusNotFound)
		return
	}
	settings, err := h.store.GetSettings(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	sourceName := strings.TrimSpace(settings.Name)
	if sourceName == "" {
		sourceName = "Playmesh 游戏源"
	}
	query := url.Values{}
	query.Set("host", baseURL)
	query.Set("token", token)
	query.Set("name", sourceName)
	payload := (&url.URL{
		Scheme:   "playmesh",
		Host:     "catalog-source",
		RawQuery: query.Encode(),
	}).String()
	code, err := qrcode.New(payload)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "qrcode_failed"})
		return
	}
	var output bytes.Buffer
	writer := standard.NewWithWriter(
		bufferWriteCloser{Buffer: &output},
		standard.WithBuiltinImageEncoder(standard.PNG_FORMAT),
		standard.WithQRWidth(7),
		standard.WithBorderWidth(18),
		standard.WithBgColorRGBHex("#ffffff"),
		standard.WithFgColorRGBHex("#071018"),
	)
	if err := code.Save(writer); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "qrcode_failed"})
		return
	}
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Data(http.StatusOK, "image/png", output.Bytes())
}

func (h *Handler) PublicSourceInfo(c *gin.Context) {
	h.mutex.RLock()
	baseURL := strings.TrimRight(strings.TrimSpace(h.config.Relay.PublicBaseURL), "/")
	token := h.config.Auth.PublishedToken
	h.mutex.RUnlock()
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.JSON(http.StatusOK, gin.H{
		"publicBaseUrl":  baseURL,
		"publishedToken": token,
	})
}

func (h *Handler) PublicDownload(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.GetGame(c.Request.Context(), id)
	// The status condition is deliberately enforced in the backend. Pending
	// packages remain unavailable even when callers construct the URL manually.
	if err != nil || game.Status != store.StatusApproved || game.StoredPath == "" {
		c.JSON(http.StatusNotFound, gin.H{
			"error": "game_not_found", "message": "游戏包不存在或尚未通过审核",
		})
		return
	}
	resolved, err := packages.ResolveStoredArchive(
		h.gamesDir, game.StoredPath,
	)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "package_missing"})
		return
	}
	c.Header("Content-Type", "application/zip")
	c.FileAttachment(resolved, safeDownloadName(game))
}

func (h *Handler) AdminGames(c *gin.Context) {
	page, ok := positiveQuery(c, "page", 1, 1, 1<<31-1)
	if !ok {
		return
	}
	if len(c.Query("search")) > 256 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": "search 过长",
		})
		return
	}
	size, ok := positiveQuery(c, "size", 20, 1, 100)
	if !ok {
		return
	}
	result, err := h.store.ListAdminGames(c.Request.Context(), store.AdminGameQuery{
		Status: strings.TrimSpace(c.Query("status")),
		Search: strings.TrimSpace(c.Query("search")), Page: page, Size: size,
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query_failed"})
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *Handler) AdminGame(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.GetGame(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "game_not_found"})
		return
	}
	c.JSON(http.StatusOK, game)
}

func (h *Handler) AdminUpdateGame(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	var body struct {
		Status string `json:"status"`
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_request"})
		return
	}
	body.Status = strings.TrimSpace(body.Status)
	body.Reason = strings.TrimSpace(body.Reason)
	if len([]rune(body.Reason)) > 2000 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "reason_too_long", "message": "审核说明不能超过 2000 字",
		})
		return
	}
	if body.Status == store.StatusRejected && body.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "reason_required", "message": "拒绝审核时必须填写原因",
		})
		return
	}
	game, err := h.store.UpdateGameStatus(
		c.Request.Context(), id, body.Status, body.Reason,
	)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "update_failed", "message": err.Error(),
		})
		return
	}
	if h.mailer.Enabled() &&
		(game.Status == store.StatusApproved ||
			game.Status == store.StatusRejected && h.config.Mail.SendReviewFailures) {
		approved := game.Status == store.StatusApproved
		reason := body.Reason
		if approved && reason == "" {
			reason = "游戏包已通过审核，可以通过正式游戏源下载。"
		}
		_ = h.mailer.SendReviewResult(game.Email, game.Name, approved, reason)
	}
	c.JSON(http.StatusOK, game)
}

func (h *Handler) AdminDeleteGame(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	storedPath, err := h.store.DeleteGame(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "game_not_found"})
		return
	}
	if storedPath != "" {
		if resolved, resolveErr := packages.ResolveStoredArchive(
			h.gamesDir, storedPath,
		); resolveErr == nil {
			_ = os.Remove(resolved)
		}
	}
	c.Status(http.StatusNoContent)
}

func (h *Handler) AdminDownload(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.GetGame(c.Request.Context(), id)
	if err != nil || game.StoredPath == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "package_missing"})
		return
	}
	resolved, err := packages.ResolveStoredArchive(
		h.gamesDir, game.StoredPath,
	)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "package_missing"})
		return
	}
	c.Header("Content-Type", "application/zip")
	c.FileAttachment(resolved, safeDownloadName(game))
}

func (h *Handler) Settings(c *gin.Context) {
	settings, err := h.store.GetSettings(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	c.JSON(http.StatusOK, settings)
}

func (h *Handler) UpdateSettings(c *gin.Context) {
	var settings store.Settings
	if err := c.ShouldBindJSON(&settings); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_request"})
		return
	}
	settings.Name = strings.TrimSpace(settings.Name)
	settings.Author = strings.TrimSpace(settings.Author)
	settings.Homepage = strings.TrimSpace(settings.Homepage)
	if len([]rune(settings.Name)) > 120 || len([]rune(settings.Author)) > 120 ||
		len(settings.Homepage) > 2048 {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "settings_too_long", "message": "游戏源设置字段过长",
		})
		return
	}
	if settings.Homepage != "" {
		parsed, err := url.Parse(settings.Homepage)
		if err != nil || parsed.Host == "" || parsed.User != nil ||
			parsed.Fragment != "" ||
			(parsed.Scheme != "http" && parsed.Scheme != "https") {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": "homepage_invalid", "message": "主页必须是 HTTP/HTTPS 地址",
			})
			return
		}
	}
	if err := h.store.UpdateSettings(c.Request.Context(), settings); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	c.JSON(http.StatusOK, settings)
}

func (h *Handler) RelayStats(c *gin.Context) {
	c.JSON(http.StatusOK, h.relay.Stats())
}

type editableConfig struct {
	ExternalListen         string                  `json:"externalListen"`
	SupportsGameRelay      bool                    `json:"supportsGameRelay"`
	ShowPublicSourceQRCode bool                    `json:"showPublicSourceQRCode"`
	AuthWhitelist          []config.WhitelistEntry `json:"authWhitelist"`
	Admin                  config.Admin            `json:"admin"`
	Storage                config.Storage          `json:"storage"`
	Scanner                config.Scanner          `json:"scanner"`
	Relay                  config.Relay            `json:"relay"`
}

func (h *Handler) RuntimeConfig(c *gin.Context) {
	h.mutex.RLock()
	value := editableFromConfig(h.config)
	h.mutex.RUnlock()
	c.JSON(http.StatusOK, gin.H{
		"config":          value,
		"restartRequired": true,
		"message":         "publicBaseUrl、内容规则与 ClamAV 可热更新；监听器、存储、限流与其他 Relay 变更在安全重启后生效",
	})
}

func (h *Handler) UpdateRuntimeConfig(c *gin.Context) {
	var body editableConfig
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_config", "message": "运行配置格式无效",
		})
		return
	}
	h.mutex.Lock()
	defer h.mutex.Unlock()
	next := h.config
	next.ExternalListen = strings.TrimSpace(body.ExternalListen)
	next.Listen = next.ExternalListen
	next.SupportsGameRelay = body.SupportsGameRelay
	next.ShowPublicSourceQRCode = body.ShowPublicSourceQRCode
	next.Auth.Whitelist = append([]config.WhitelistEntry(nil), body.AuthWhitelist...)
	next.Admin = body.Admin
	next.Storage = body.Storage
	body.Scanner.Enabled = next.Scanner.Enabled
	next.Scanner = body.Scanner
	next.Relay = body.Relay
	if err := next.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_config", "message": err.Error(),
		})
		return
	}
	if err := next.Save(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "config_save_failed", "message": err.Error(),
		})
		return
	}
	h.packages.UpdateScanner(next.Scanner)
	if h.updatePublicBaseURL != nil {
		h.updatePublicBaseURL(next.Relay.PublicBaseURL)
	}
	h.config = next
	c.JSON(http.StatusOK, gin.H{
		"config":          editableFromConfig(next),
		"restartRequired": true,
		"message":         "server.json 已原子更新；publicBaseUrl、内容规则与 ClamAV 设置已热更新，其他运行配置在安全重启后生效",
	})
}

func editableFromConfig(cfg config.Config) editableConfig {
	return editableConfig{
		ExternalListen:         cfg.ExternalListen,
		SupportsGameRelay:      cfg.SupportsGameRelay,
		ShowPublicSourceQRCode: cfg.ShowPublicSourceQRCode,
		AuthWhitelist:          append([]config.WhitelistEntry(nil), cfg.Auth.Whitelist...),
		Admin:                  cfg.Admin,
		Storage:                cfg.Storage,
		Scanner:                cfg.Scanner,
		Relay:                  cfg.Relay,
	}
}

func positiveQuery(
	c *gin.Context,
	name string,
	fallback int,
	minimum int,
	maximum int,
) (int, bool) {
	raw := strings.TrimSpace(c.Query(name))
	if raw == "" {
		return fallback, true
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < minimum || value > maximum {
		c.JSON(http.StatusBadRequest, gin.H{
			"error": "invalid_request", "message": name + " 超出允许范围",
		})
		return fallback, false
	}
	return value, true
}

func int64Query(c *gin.Context, name string) int64 {
	value, _ := strconv.ParseInt(strings.TrimSpace(c.Query(name)), 10, 64)
	return value
}

func pathID(c *gin.Context) (int64, bool) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id < 1 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_id"})
		return 0, false
	}
	return id, true
}

func safeDownloadName(game store.Game) string {
	sanitize := func(input string) string {
		return strings.Map(func(value rune) rune {
			if value >= 'a' && value <= 'z' ||
				value >= 'A' && value <= 'Z' ||
				value >= '0' && value <= '9' ||
				value == '.' || value == '-' || value == '_' {
				return value
			}
			return '-'
		}, input)
	}
	return sanitize(game.PackageID) + "-" + sanitize(game.Version) + ".zip"
}
