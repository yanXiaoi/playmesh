package admin

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/packages"
	"go-server/internal/qrimage"
	"go-server/internal/relay"
	"go-server/internal/store"
	useraccount "go-server/internal/user"
)

type Handler struct {
	config              config.Config
	store               *store.Store
	packages            *packages.Service
	mailer              *mailer.Mailer
	relay               *relay.Manager
	gamesDir            string
	mutex               sync.RWMutex
	updatePublicBaseURL func(string)
}

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
		updatePublicBaseURL: updatePublicBaseURL,
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
			"packageSizeBytes": game.PackageSizeBytes, "createdAt": game.CreatedAt,
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
	publicURL, err := url.Parse(baseURL)
	if err != nil || publicURL.Host == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "public_url_invalid"})
		return
	}
	query := publicURL.Query()
	query.Set("token", token)
	publicURL.RawQuery = query.Encode()
	payload := publicURL.String()
	output, err := qrimage.PNG(payload)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "qrcode_failed"})
		return
	}
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Data(http.StatusOK, "image/png", output)
}

func (h *Handler) PublicSourceInfo(c *gin.Context) {
	h.mutex.RLock()
	baseURL := strings.TrimRight(strings.TrimSpace(h.config.Relay.PublicBaseURL), "/")
	token := h.config.Auth.PublishedToken
	h.mutex.RUnlock()
	c.Header("Cache-Control", "no-store, no-cache, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.JSON(http.StatusOK, gin.H{
		"publicURL": baseURL + "?token=" + url.QueryEscape(token),
	})
}

func (h *Handler) PublicDownload(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.GetGame(c.Request.Context(), id)
	if err == nil {
		visible, visibleErr := h.store.GetCatalogGame(
			c.Request.Context(), game.PackageID, game.Version,
		)
		if visibleErr != nil || visible.ID != game.ID {
			err = store.ErrNotFound
		}
	}
	// 浏览器下载也执行与 Catalog 相同的 latest + published 可见性规则。
	if err != nil || game.StoredPath == "" {
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

func (h *Handler) AdminUsers(c *gin.Context) {
	page, ok := positiveQuery(c, "page", 1, 1, 1<<31-1)
	if !ok {
		return
	}
	size, ok := positiveQuery(c, "size", 20, 1, 100)
	if !ok {
		return
	}
	if len(c.Query("search")) > 320 {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "invalid_request", "message": "搜索内容过长",
		})
		return
	}
	result, err := h.store.ListAdminUsers(
		c.Request.Context(),
		store.AdminUserQuery{
			Search: strings.TrimSpace(c.Query("search")),
			Status: strings.TrimSpace(c.Query("status")),
			Page:   page,
			Size:   size,
		},
	)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "user_query_failed", "message": err.Error(),
		})
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *Handler) AdminCreateUser(c *gin.Context) {
	var body struct {
		Email       string `json:"email"`
		Password    string `json:"password"`
		DisplayName string `json:"displayName"`
		Disabled    bool   `json:"disabled"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request"})
		return
	}
	email, err := useraccount.NormalizeEmail(body.Email)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "email_invalid", "message": err.Error(),
		})
		return
	}
	passwordHash, err := useraccount.HashPassword(body.Password)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "password_invalid", "message": err.Error(),
		})
		return
	}
	displayName := strings.TrimSpace(body.DisplayName)
	if len([]rune(displayName)) > 40 {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "display_name_invalid", "message": "展示名称不能超过 40 个字符",
		})
		return
	}
	account, err := h.store.CreateUser(
		c.Request.Context(), email, passwordHash, "active",
	)
	if err != nil {
		code := "user_create_failed"
		status := http.StatusInternalServerError
		if errors.Is(err, store.ErrEmailExists) {
			code = "email_exists"
			status = http.StatusConflict
		}
		c.JSON(status, gin.H{"code": code, "message": err.Error()})
		return
	}
	if displayName != "" {
		account, err = h.store.UpdateDisplayName(
			c.Request.Context(), account.ID, displayName,
		)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"code": "profile_update_failed", "message": err.Error(),
			})
			return
		}
	}
	if body.Disabled {
		if err := h.store.SetUserDisabled(
			c.Request.Context(), account.ID, true, "管理员创建时禁用",
		); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"code": "user_update_failed", "message": err.Error(),
			})
			return
		}
		account.Status = "disabled"
	}
	c.JSON(http.StatusCreated, account)
}

func (h *Handler) AdminUpdateUser(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	var body struct {
		Disabled bool   `json:"disabled"`
		Reason   string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request"})
		return
	}
	body.Reason = strings.TrimSpace(body.Reason)
	if body.Disabled && body.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "reason_required", "message": "禁用用户时必须填写原因",
		})
		return
	}
	if len([]rune(body.Reason)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "reason_too_long", "message": "禁用原因不能超过 500 字",
		})
		return
	}
	if err := h.store.SetUserDisabled(
		c.Request.Context(), id, body.Disabled, body.Reason,
	); err != nil {
		status := http.StatusInternalServerError
		code := "user_update_failed"
		if errors.Is(err, store.ErrNotFound) {
			status = http.StatusNotFound
			code = "user_not_found"
		}
		c.JSON(status, gin.H{"code": code, "message": err.Error()})
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *Handler) AdminDeleteUser(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	if err := h.store.DeleteUser(c.Request.Context(), id); err != nil {
		status := http.StatusInternalServerError
		code := "user_delete_failed"
		switch {
		case errors.Is(err, store.ErrNotFound):
			status = http.StatusNotFound
			code = "user_not_found"
		case errors.Is(err, store.ErrUserHasGames):
			status = http.StatusConflict
			code = "user_has_games"
		}
		c.JSON(status, gin.H{"code": code, "message": err.Error()})
		return
	}
	c.Status(http.StatusNoContent)
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
		store.AdminReviewActor(h.config.AdminUsername),
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
	title := "游戏包审核通过"
	message := fmt.Sprintf("%s %s 已通过审核。", game.Name, game.Version)
	kind := "game_approved"
	if game.Status == store.StatusRejected {
		title = "游戏包审核未通过"
		message = fmt.Sprintf(
			"%s %s 未通过审核。原因：%s", game.Name, game.Version, body.Reason,
		)
		kind = "game_rejected"
	}
	_ = h.store.CreateNotification(
		c.Request.Context(), game.OwnerUserID, kind, title, message,
	)
	c.JSON(http.StatusOK, game)
}

func (h *Handler) AdminDeleteGame(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	var body struct {
		Reason string `json:"reason"`
	}
	if c.Request.ContentLength > 0 {
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request"})
			return
		}
	}
	body.Reason = strings.TrimSpace(body.Reason)
	if len([]rune(body.Reason)) > 2000 {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "reason_too_long", "message": "删除说明不能超过 2000 字",
		})
		return
	}
	game, err := h.store.BeginDeleteOwnedGame(
		c.Request.Context(), id, store.AdminReviewActor(h.config.AdminUsername),
	)
	if err != nil {
		status := http.StatusConflict
		code := "game_operation_failed"
		if errors.Is(err, store.ErrNotFound) {
			status = http.StatusNotFound
			code = "game_not_found"
		} else if errors.Is(err, store.ErrGameMustBeUnpublished) {
			code = "game_must_be_unpublished"
		}
		c.JSON(status, gin.H{"code": code, "message": err.Error()})
		return
	}
	reason := body.Reason
	if reason == "" {
		reason = "管理员删除了该游戏包记录。"
	}
	_ = h.store.CreateNotification(
		c.Request.Context(), game.OwnerUserID, "game_deleted",
		"游戏包已删除",
		fmt.Sprintf("%s %s 已删除。说明：%s", game.Name, game.Version, reason),
	)
	if err := packages.DeleteStoredFiles(
		h.gamesDir, game.StoredPath, game.IconPath,
	); err != nil {
		c.JSON(http.StatusAccepted, gin.H{
			"code": "deletion_pending", "status": store.StatusDeleting,
			"message": "删除已进入后台清理队列",
		})
		return
	}
	_, err = h.store.CompleteDeletingGame(
		c.Request.Context(), id, store.AdminReviewActor(h.config.AdminUsername),
	)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		c.JSON(http.StatusAccepted, gin.H{
			"code": "deletion_pending", "status": store.StatusDeleting,
			"message": "删除已进入后台清理队列",
		})
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *Handler) AdminPublishGame(c *gin.Context) {
	h.adminSetPublished(c, true, "")
}

func (h *Handler) AdminUnpublishGame(c *gin.Context) {
	var body struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&body); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request"})
		return
	}
	body.Reason = strings.TrimSpace(body.Reason)
	if body.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "reason_required", "message": "下架游戏时必须填写原因",
		})
		return
	}
	if len([]rune(body.Reason)) > 2000 {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "reason_too_long", "message": "下架原因不能超过 2000 字",
		})
		return
	}
	h.adminSetPublished(c, false, body.Reason)
}

func (h *Handler) adminSetPublished(
	c *gin.Context,
	published bool,
	reason string,
) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.SetPublishedWithDetail(
		c.Request.Context(), id,
		store.AdminReviewActor(h.config.AdminUsername), published, reason,
	)
	if err != nil {
		code := "invalid_game_state"
		if errors.Is(err, store.ErrNotLatestVersion) {
			code = "not_latest_version"
		}
		c.JSON(http.StatusConflict, gin.H{"code": code, "message": err.Error()})
		return
	}
	if published {
		_ = h.store.CreateNotification(
			c.Request.Context(), game.OwnerUserID, "game_published",
			"游戏包已上架",
			fmt.Sprintf("%s %s 已上架。", game.Name, game.Version),
		)
	} else {
		_ = h.store.CreateNotification(
			c.Request.Context(), game.OwnerUserID, "game_unpublished",
			"游戏包已下架",
			fmt.Sprintf(
				"%s %s 已下架。原因：%s", game.Name, game.Version, reason,
			),
		)
	}
	c.JSON(http.StatusOK, game)
}

func (h *Handler) AdminDownload(c *gin.Context) {
	id, ok := pathID(c)
	if !ok {
		return
	}
	game, err := h.store.GetGame(c.Request.Context(), id)
	if err != nil || game.StoredPath == "" || game.Status == store.StatusDeleting {
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
	currentSettings, currentErr := h.store.GetSettings(c.Request.Context())
	if currentErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	settings.AllowUserRegistration = currentSettings.AllowUserRegistration
	settings.RequireEmailVerification = currentSettings.RequireEmailVerification
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
	if err := h.store.UpdateSettings(
		c.Request.Context(), settings,
		store.AdminReviewActor(h.config.AdminUsername),
	); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	c.JSON(http.StatusOK, settings)
}

func (h *Handler) RelayStats(c *gin.Context) {
	c.JSON(http.StatusOK, h.relay.Stats())
}

type editableAdminConfig struct {
	Listen                    string `json:"listen"`
	SessionTTLMinutes         int    `json:"sessionTtlMinutes"`
	LoginIntervalMilliseconds int    `json:"loginIntervalMilliseconds"`
}

type editableConfig struct {
	ExternalListen           string                  `json:"externalListen"`
	SupportsGameRelay        bool                    `json:"supportsGameRelay"`
	ShowPublicSourceQRCode   bool                    `json:"showPublicSourceQRCode"`
	AllowUserRegistration    bool                    `json:"allowUserRegistration"`
	RequireEmailVerification bool                    `json:"requireEmailVerification"`
	AuthWhitelist            []config.WhitelistEntry `json:"authWhitelist"`
	Admin                    editableAdminConfig     `json:"admin"`
	Storage                  config.Storage          `json:"storage"`
	Scanner                  config.Scanner          `json:"scanner"`
	Relay                    config.Relay            `json:"relay"`
	WebUI                    config.WebUI            `json:"webUI"`
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
	next.AllowUserRegistration = body.AllowUserRegistration
	next.RequireEmailVerification = body.RequireEmailVerification
	next.Auth.Whitelist = append([]config.WhitelistEntry(nil), body.AuthWhitelist...)
	next.Admin.Listen = strings.TrimSpace(body.Admin.Listen)
	next.Admin.SessionTTLMinutes = body.Admin.SessionTTLMinutes
	next.Admin.LoginIntervalMilliseconds = body.Admin.LoginIntervalMilliseconds
	next.Storage = body.Storage
	body.Scanner.Enabled = next.Scanner.Enabled
	next.Scanner = body.Scanner
	next.Relay = relayFromEditable(next.Relay, body.Relay)
	if strings.TrimSpace(body.WebUI.DefaultLocale) == "" {
		body.WebUI = next.WebUI
	}
	next.WebUI = body.WebUI
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
	settings, settingsErr := h.store.GetSettings(c.Request.Context())
	if settingsErr == nil {
		settings.AllowUserRegistration = next.AllowUserRegistration
		settings.RequireEmailVerification = next.RequireEmailVerification
		settingsErr = h.store.UpdateSettings(
			c.Request.Context(), settings,
			store.AdminReviewActor(h.config.AdminUsername),
		)
	}
	if settingsErr != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "settings_save_failed", "message": "server.json 已保存，但注册开关同步失败",
		})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"config":          editableFromConfig(next),
		"restartRequired": true,
		"message":         "server.json 已原子更新；publicBaseUrl、内容规则与 ClamAV 设置已热更新，其他运行配置在安全重启后生效",
	})
}

func relayFromEditable(current config.Relay, edited config.Relay) config.Relay {
	edited.TURNSharedSecret = current.TURNSharedSecret
	return edited
}

func editableFromConfig(cfg config.Config) editableConfig {
	return editableConfig{
		ExternalListen:           cfg.ExternalListen,
		SupportsGameRelay:        cfg.SupportsGameRelay,
		ShowPublicSourceQRCode:   cfg.ShowPublicSourceQRCode,
		AllowUserRegistration:    cfg.AllowUserRegistration,
		RequireEmailVerification: cfg.RequireEmailVerification,
		AuthWhitelist:            append([]config.WhitelistEntry(nil), cfg.Auth.Whitelist...),
		Admin: editableAdminConfig{
			Listen:                    cfg.Admin.Listen,
			SessionTTLMinutes:         cfg.Admin.SessionTTLMinutes,
			LoginIntervalMilliseconds: cfg.Admin.LoginIntervalMilliseconds,
		},
		Storage: cfg.Storage,
		Scanner: cfg.Scanner,
		Relay:   cfg.Relay,
		WebUI:   cfg.WebUI,
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
