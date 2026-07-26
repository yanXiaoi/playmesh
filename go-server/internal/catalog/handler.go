package catalog

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/middleware"
	"go-server/internal/packages"
	"go-server/internal/store"
)

const pendingTag = "待审核"

type Handler struct {
	config            config.Config
	store             *store.Store
	publicBaseURL     string
	publicBaseURLLock sync.RWMutex
}

func New(cfg config.Config, database *store.Store) *Handler {
	return &Handler{
		config:        cfg,
		store:         database,
		publicBaseURL: cfg.Relay.PublicBaseURL,
	}
}

// UpdatePublicBaseURL refreshes the declaration returned by /apps/info without
// changing listener or Relay manager settings that still require a restart.
func (h *Handler) UpdatePublicBaseURL(value string) {
	h.publicBaseURLLock.Lock()
	h.publicBaseURL = value
	h.publicBaseURLLock.Unlock()
}

func (h *Handler) currentPublicBaseURL() string {
	h.publicBaseURLLock.RLock()
	value := h.publicBaseURL
	h.publicBaseURLLock.RUnlock()
	return strings.TrimRight(strings.TrimSpace(value), "/")
}

func (h *Handler) Info(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	settings, err := h.store.GetSettings(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "settings_failed"})
		return
	}
	response := gin.H{
		"catalogApiVersion": config.CatalogAPIVersion,
		"supportsGameRelay": settings.SupportsGameRelay && h.config.SupportsGameRelay,
	}
	if name := strings.TrimSpace(settings.Name); name != "" {
		response["name"] = name
	}
	if author := strings.TrimSpace(settings.Author); author != "" {
		response["author"] = author
	}
	if homepage := strings.TrimSpace(settings.Homepage); homepage != "" {
		response["homepage"] = homepage
	}
	if response["supportsGameRelay"] == true {
		response["relay"] = gin.H{
			"protocolVersion":         config.RelayProtocolVersion,
			"transport":               "playmesh-tcp-upgrade",
			"publicBaseUrl":           h.currentPublicBaseURL(),
			"hostPath":                "/relay/v1/host",
			"clientPath":              "/relay/v1/client",
			"maxConnectionsPerTunnel": h.config.Relay.MaxConnectionsPerTunnel,
		}
	}
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.JSON(http.StatusOK, response)
}

func (h *Handler) List(c *gin.Context) {
	page := positiveQuery(c, "page", 1, 1, 1<<31-1)
	size := positiveQuery(c, "size", 10, 1, 100)
	if c.IsAborted() {
		return
	}
	for _, name := range []string{"s_name", "s_tag", "s_desc"} {
		if len(c.Query(name)) > 256 {
			c.JSON(http.StatusBadRequest, gin.H{
				"error": "invalid_request", "message": name + " 过长",
			})
			return
		}
	}
	status := middleware.CatalogStatus(c)
	games, total, err := h.store.ListCatalogGames(
		c.Request.Context(),
		store.CatalogQuery{
			Status: status, Name: c.Query("s_name"), Tag: c.Query("s_tag"),
			Description: c.Query("s_desc"),
		},
		page,
		size,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "catalog_failed"})
		return
	}
	data := make([]map[string]any, 0, len(games))
	for _, game := range games {
		var manifest map[string]any
		if err := json.Unmarshal([]byte(game.ManifestJSON), &manifest); err != nil {
			continue
		}
		if status == store.StatusPending {
			addPendingTag(manifest)
		}
		data = append(data, manifest)
	}
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.JSON(http.StatusOK, gin.H{
		"total": total, "current": page, "size": size, "data": data,
	})
}

func (h *Handler) Download(c *gin.Context) {
	status := middleware.CatalogStatus(c)
	packageID := strings.TrimSpace(c.Query("id"))
	if len(packageID) > 128 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_request"})
		return
	}
	game, err := h.store.GetCatalogGame(
		c.Request.Context(), packageID, status,
	)
	if err != nil || game.StoredPath == "" {
		c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
		c.JSON(http.StatusNotFound, gin.H{
			"error": "game_not_found", "message": "当前 Token 下没有可下载的游戏",
		})
		return
	}
	resolved, err := packages.ResolveStoredArchive(
		h.config.Storage.GamesDirectory, game.StoredPath,
	)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "package_missing"})
		return
	}
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.Header("Content-Type", "application/zip")
	c.FileAttachment(
		resolved,
		safeFilename(game.PackageID)+"-"+safeFilename(game.Version)+".zip",
	)
}

func addPendingTag(manifest map[string]any) {
	tags, _ := manifest["tags"].([]any)
	for _, tag := range tags {
		if value, ok := tag.(string); ok && value == pendingTag {
			return
		}
	}
	manifest["tags"] = append(tags, pendingTag)
}

func safeFilename(value string) string {
	return strings.Map(func(character rune) rune {
		if character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' ||
			character == '.' || character == '-' || character == '_' {
			return character
		}
		return '-'
	}, value)
}

func positiveQuery(c *gin.Context, name string, fallback, minimum, maximum int) int {
	value := fallback
	if raw := c.Query(name); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil ||
			parsed < minimum || parsed > maximum {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
				"error":   "invalid_request",
				"message": name + " 超出允许范围",
			})
			return fallback
		}
		value = parsed
	}
	return value
}
