package webui

import (
	"embed"
	"mime"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed assets/*
var assets embed.FS

type Handler struct{}

var userAssets = map[string]struct{}{
	"style.css": {},
	"user.js":   {},
}

var adminAssets = map[string]struct{}{
	"admin.js":  {},
	"style.css": {},
}

func New() *Handler {
	return &Handler{}
}

func (h *Handler) User(c *gin.Context) {
	h.serve(c, "assets/user.html")
}

func (h *Handler) Admin(c *gin.Context) {
	content, err := assets.ReadFile("assets/admin.html")
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	assetBase := strings.TrimRight(c.Request.URL.Path, "/") + "/assets"
	content = []byte(strings.ReplaceAll(
		string(content), "{{ADMIN_ASSET_BASE}}", assetBase,
	))
	c.Data(http.StatusOK, "text/html; charset=utf-8", content)
}

func (h *Handler) UserAsset(c *gin.Context) {
	h.asset(c, userAssets)
}

func (h *Handler) AdminAsset(c *gin.Context) {
	h.asset(c, adminAssets)
}

func (h *Handler) asset(c *gin.Context, allowedAssets map[string]struct{}) {
	name := filepath.Base(c.Param("name"))
	if name != c.Param("name") {
		c.Status(http.StatusNotFound)
		return
	}
	if _, allowed := allowedAssets[name]; !allowed {
		c.Status(http.StatusNotFound)
		return
	}
	h.serve(c, "assets/"+name)
}

func (h *Handler) serve(c *gin.Context, name string) {
	content, err := assets.ReadFile(name)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	contentType := mime.TypeByExtension(filepath.Ext(name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	c.Data(http.StatusOK, contentType, content)
}
