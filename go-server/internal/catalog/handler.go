package catalog

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
)

type Handler struct {
	config config.Config
}

func New(cfg config.Config) *Handler {
	return &Handler{config: cfg}
}

func (h *Handler) Info(c *gin.Context) {
	response := gin.H{
		"catalogApiVersion": config.CatalogAPIVersion,
		"supportsGameRelay": h.config.SupportsGameRelay,
	}
	if name := strings.TrimSpace(h.config.Name); name != "" {
		response["name"] = name
	}
	if author := strings.TrimSpace(h.config.Author); author != "" {
		response["author"] = author
	}
	if homepage := strings.TrimSpace(h.config.Homepage); homepage != "" {
		response["homepage"] = homepage
	}
	if h.config.SupportsGameRelay {
		response["relay"] = gin.H{
			"protocolVersion":         config.RelayProtocolVersion,
			"transport":               "playmesh-tcp-upgrade",
			"publicBaseUrl":           strings.TrimRight(strings.TrimSpace(h.config.Relay.PublicBaseURL), "/"),
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
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.JSON(http.StatusOK, gin.H{
		"total":   0,
		"current": page,
		"size":    size,
		"data":    []any{},
	})
}

func (h *Handler) Download(c *gin.Context) {
	c.Header("X-Playmesh-Catalog-Version", config.CatalogAPIVersion)
	c.JSON(http.StatusNotFound, gin.H{
		"error":   "game_not_found",
		"message": "当前游戏源没有可下载游戏",
	})
}

func positiveQuery(c *gin.Context, name string, fallback, minimum, maximum int) int {
	value := fallback
	if raw := c.Query(name); raw != "" {
		var parsed int
		if _, err := fmt.Sscanf(raw, "%d", &parsed); err != nil ||
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
