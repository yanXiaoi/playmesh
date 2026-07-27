package webui

import (
	"embed"
	"encoding/json"
	"mime"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"

	"go-server/internal/config"
	"go-server/internal/localization"
)

//go:embed assets/*
var assets embed.FS

type Handler struct {
	webUI   config.WebUI
	catalog localization.Catalog
}

var userAssets = map[string]struct{}{
	"captcha.js":           {},
	"gocaptcha.global.css": {},
	"gocaptcha.global.js":  {},
	"style.css":            {},
	"user.js":              {},
}

var adminAssets = map[string]struct{}{
	"admin.js":             {},
	"captcha.js":           {},
	"gocaptcha.global.css": {},
	"gocaptcha.global.js":  {},
	"style.css":            {},
}

func New(webUI config.WebUI) *Handler {
	catalog, err := localization.Load()
	if err != nil {
		panic(err)
	}
	return &Handler{webUI: webUI, catalog: catalog}
}

func (h *Handler) LocalizationManifest(c *gin.Context) {
	type localeOption struct {
		ID    string `json:"id"`
		Label string `json:"label"`
	}
	enabled := make(map[string]struct{}, len(h.webUI.EnabledLocales))
	for _, locale := range h.webUI.EnabledLocales {
		enabled[locale] = struct{}{}
	}
	locales := make([]localeOption, 0, len(enabled))
	for _, locale := range h.catalog.Manifest.Locales {
		if _, ok := enabled[locale.ID]; ok {
			locales = append(locales, localeOption{ID: locale.ID, Label: locale.Label})
		}
	}
	c.Header("Cache-Control", "no-cache")
	c.JSON(http.StatusOK, gin.H{
		"defaultLocale":     h.webUI.DefaultLocale,
		"allowLocaleSwitch": h.webUI.AllowLocaleSwitch,
		"defaultThemeMode":  "light",
		"allowThemeSwitch":  false,
		"locales":           locales,
	})
}

func (h *Handler) LocalizationBundle(c *gin.Context) {
	locale := c.Param("locale")
	allowed := false
	for _, candidate := range h.webUI.EnabledLocales {
		if candidate == locale {
			allowed = true
			break
		}
	}
	content, ok := h.catalog.Bundle(locale)
	if !allowed || !ok {
		c.Status(http.StatusNotFound)
		return
	}
	var messages map[string]string
	if err := json.Unmarshal(content, &messages); err != nil {
		c.Status(http.StatusInternalServerError)
		return
	}
	c.Header("Cache-Control", "no-cache")
	c.JSON(http.StatusOK, messages)
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
