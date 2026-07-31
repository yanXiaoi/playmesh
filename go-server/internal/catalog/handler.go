package catalog

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/gameid"
	"go-server/internal/packages"
	"go-server/internal/store"
	"go-server/internal/version"
)

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
		"userUpload": gin.H{
			"supported":       true,
			"protocolVersion": config.UserUploadProtocolVersion,
			"path":            "/api/user/uploads",
			"maxUploadBytes":  h.config.Storage.MaxUploadBytes,
		},
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
	games, total, err := h.store.ListCatalogGames(
		c.Request.Context(),
		store.CatalogQuery{
			Name: c.Query("s_name"), Tag: c.Query("s_tag"),
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
		// The account profile is the source of truth for publisher identity.
		// Uploaded manifests contain only the name snapshot from upload time.
		manifest["author"] = game.Author
		if game.PackageSizeBytes > 0 {
			manifest["packageSizeBytes"] = game.PackageSizeBytes
		}
		if game.IconPath != "" {
			manifest["icon"] = h.currentPublicBaseURL() + "/apps/icon?id=" +
				url.QueryEscape(game.PackageID) +
				"&version=" + url.QueryEscape(game.Version)
		}
		data = append(data, manifest)
	}
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.JSON(http.StatusOK, gin.H{
		"total": total, "current": page, "size": size, "data": data,
	})
}

func (h *Handler) Download(c *gin.Context) {
	packageID := c.Query("id")
	versionValue := strings.TrimSpace(c.Query("version"))
	if !gameid.Valid(packageID) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid_request"})
		return
	}
	if _, err := version.Parse(versionValue); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"code": "invalid_version", "message": "下载必须指定合法的 MAJOR.MINOR.PATCH",
		})
		return
	}
	game, err := h.store.GetCatalogGame(
		c.Request.Context(), packageID, versionValue,
	)
	if err != nil || game.StoredPath == "" {
		c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
		c.JSON(http.StatusNotFound, gin.H{
			"code": "version_not_available", "message": "指定版本不是当前公开最新版本",
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

func (h *Handler) Icon(c *gin.Context) {
	packageID := c.Query("id")
	versionValue := strings.TrimSpace(c.Query("version"))
	if !gameid.Valid(packageID) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request"})
		return
	}
	if _, err := version.Parse(versionValue); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_version"})
		return
	}
	game, err := h.store.GetCatalogGame(
		c.Request.Context(), packageID, versionValue,
	)
	if err != nil || game.IconPath == "" {
		c.JSON(http.StatusNotFound, gin.H{"code": "version_not_available"})
		return
	}
	resolved, err := packages.ResolveStoredIcon(
		h.config.Storage.GamesDirectory, game.IconPath,
	)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"code": "icon_not_available"})
		return
	}
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.Header("Content-Type", "image/png")
	c.File(resolved)
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
