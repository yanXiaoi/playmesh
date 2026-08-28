package config

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/mail"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go-server/internal/localization"
)

const (
	CatalogAPIVersion         = "3.0.0"
	RelayProtocolVersion      = "4.0.0"
	UserUploadProtocolVersion = "1.0.0"
)

type WhitelistEntry struct {
	Method string `json:"method"`
	Path   string `json:"path"`
}

type Auth struct {
	// Token is kept for source compatibility with older callers. Load maps it
	// to PublishedToken when the new environment variables are not used.
	Token          string           `json:"-"`
	PublishedToken string           `json:"-"`
	ReviewToken    string           `json:"-"`
	Whitelist      []WhitelistEntry `json:"whitelist"`
}

type Admin struct {
	Listen string `json:"listen"`
	// CAPTCHA settings are loaded from .env. The JSON names remain accepted
	// for compatibility with older server.json files, but Save omits them.
	CaptchaMode                 string `json:"captchaMode,omitempty"`
	CaptchaImageSource          string `json:"captchaImageSource,omitempty"`
	CaptchaImageDirectory       string `json:"captchaImageDirectory,omitempty"`
	CaptchaImageURL             string `json:"captchaImageUrl,omitempty"`
	CaptchaImageCacheSize       int    `json:"captchaImageCacheSize,omitempty"`
	SessionTTLMinutes           int    `json:"sessionTtlMinutes"`
	LoginIntervalMilliseconds   int    `json:"loginIntervalMilliseconds"`
	CaptchaIntervalMilliseconds int    `json:"captchaIntervalMilliseconds,omitempty"`
}

type Storage struct {
	DatabasePath                string `json:"databasePath"`
	GamesDirectory              string `json:"gamesDirectory"`
	QuarantineDirectory         string `json:"quarantineDirectory"`
	MaxUploadBytes              int64  `json:"maxUploadBytes"`
	MaxExpandedBytes            int64  `json:"maxExpandedBytes"`
	MaxFileBytes                int64  `json:"maxFileBytes"`
	MaxFiles                    int    `json:"maxFiles"`
	MaxCompressionRatio         int64  `json:"maxCompressionRatio"`
	MaxConcurrentScans          int    `json:"maxConcurrentScans"`
	PublicUploadIntervalSeconds int    `json:"publicUploadIntervalSeconds"`
}

type Scanner struct {
	Enabled        bool          `json:"-"`
	ClamScanPath   string        `json:"clamScanPath"`
	Required       bool          `json:"required"`
	TimeoutSeconds int           `json:"timeoutSeconds"`
	ContentRules   []ContentRule `json:"contentRules"`
}

type ContentRule struct {
	ID          string   `json:"id"`
	Description string   `json:"description"`
	Pattern     string   `json:"pattern"`
	Extensions  []string `json:"extensions"`
	Enabled     bool     `json:"enabled"`
}

type Mail struct {
	Enabled            bool
	Host               string
	Port               int
	Username           string
	Password           string
	From               string
	UseTLS             bool
	SendReviewFailures bool
}

type Relay struct {
	PublicBaseURL string `json:"publicBaseUrl"`
	// TunnelTTLSeconds 兼容保留历史字段名；现在表示主机首次附着等待时间和
	// 每个 peer 的短期 ICE/TURN 凭据寿命，不是在线主机邀请的硬过期时间。
	TunnelTTLSeconds        int    `json:"tunnelTTLSeconds"`
	MaxTunnels              int    `json:"maxTunnels"`
	MaxConnectionsPerTunnel int    `json:"maxConnectionsPerTunnel"`
	MaxConnectionsPerIP     int    `json:"maxConnectionsPerIP"`
	TURNUDPListen           string `json:"turnUdpListen"`
	TURNTCPListen           string `json:"turnTcpListen"`
	TURNPublicIP            string `json:"turnPublicIp"`
	TURNPublicPort          int    `json:"turnPublicPort"`
	TURNRealm               string `json:"turnRealm"`
	TURNMinPort             int    `json:"turnMinPort"`
	TURNMaxPort             int    `json:"turnMaxPort"`
	TURNSharedSecret        string `json:"-"`
}

type WebUI struct {
	DefaultLocale     string   `json:"defaultLocale"`
	EnabledLocales    []string `json:"enabledLocales"`
	AllowLocaleSwitch bool     `json:"allowLocaleSwitch"`
	DefaultThemeMode  string   `json:"defaultThemeMode"`
	AllowThemeSwitch  bool     `json:"allowThemeSwitch"`
}

type Config struct {
	// Listen is the legacy external listen field.
	Listen                   string  `json:"listen,omitempty"`
	ExternalListen           string  `json:"externalListen"`
	Name                     string  `json:"name"`
	Author                   string  `json:"author"`
	Homepage                 string  `json:"homepage"`
	SupportsGameRelay        bool    `json:"supportsGameRelay"`
	ShowPublicSourceQRCode   bool    `json:"showPublicSourceQRCode"`
	AllowUserRegistration    bool    `json:"allowUserRegistration"`
	RequireEmailVerification bool    `json:"requireEmailVerification"`
	Auth                     Auth    `json:"auth"`
	Admin                    Admin   `json:"admin"`
	Storage                  Storage `json:"storage"`
	Scanner                  Scanner `json:"scanner"`
	Relay                    Relay   `json:"relay"`
	WebUI                    WebUI   `json:"webUI"`

	AdminUsername   string `json:"-"`
	AdminPassword   string `json:"-"`
	AdminPath       string `json:"-"`
	Mail            Mail   `json:"-"`
	UploadKeyPepper string `json:"-"`
	ConfigPath      string `json:"-"`
}

func Default() Config {
	return Config{
		ExternalListen:           "0.0.0.0:16668",
		Name:                     "Playmesh 公共游戏源",
		SupportsGameRelay:        true,
		ShowPublicSourceQRCode:   true,
		AllowUserRegistration:    true,
		RequireEmailVerification: false,
		Auth: Auth{
			PublishedToken: "test-published-token-at-least-32-bytes",
			ReviewToken:    "test-review-token-at-least-32-bytes",
			Whitelist: []WhitelistEntry{
				{Method: "GET", Path: "/health"},
				{Method: "GET", Path: "/relay/v1/client"},
			},
		},
		Admin: Admin{
			Listen:                      "127.0.0.1:16669",
			CaptchaMode:                 "slide",
			CaptchaImageSource:          "remote",
			CaptchaImageDirectory:       "data/captcha-images",
			CaptchaImageURL:             "https://t.alcy.cc/moe",
			CaptchaImageCacheSize:       8,
			SessionTTLMinutes:           480,
			LoginIntervalMilliseconds:   1000,
			CaptchaIntervalMilliseconds: 1000,
		},
		Storage: Storage{
			DatabasePath:                "data/playmesh-server.db",
			GamesDirectory:              "data/games",
			QuarantineDirectory:         "data/quarantine",
			MaxUploadBytes:              100 << 20,
			MaxExpandedBytes:            512 << 20,
			MaxFileBytes:                128 << 20,
			MaxFiles:                    8000,
			MaxCompressionRatio:         100,
			MaxConcurrentScans:          4,
			PublicUploadIntervalSeconds: 60,
		},
		Scanner: Scanner{
			Enabled:        true,
			ClamScanPath:   "clamscan",
			Required:       true,
			TimeoutSeconds: 120,
			ContentRules: []ContentRule{
				{
					ID: "html-data-url", Description: "可执行 HTML Data URL",
					Pattern: `(?i)data\s*:\s*text/html`, Enabled: true,
				},
				{
					ID: "eval", Description: "动态代码执行 eval",
					Pattern: `(?i)\beval\s*\(`, Enabled: true,
				},
				{
					ID: "service-worker", Description: "Service Worker 注册",
					Pattern: `(?i)serviceWorker\s*\.\s*register`, Enabled: true,
				},
				{
					ID: "active-svg", Description: "SVG 活动脚本或 foreignObject",
					Pattern:    `(?i)<\s*(script|foreignObject)\b`,
					Extensions: []string{".svg"}, Enabled: true,
				},
			},
		},
		Relay: Relay{
			PublicBaseURL:           "http://127.0.0.1:16668",
			TunnelTTLSeconds:        21600,
			MaxTunnels:              1000,
			MaxConnectionsPerTunnel: 64,
			MaxConnectionsPerIP:     32,
			TURNUDPListen:           "0.0.0.0:3478",
			TURNTCPListen:           "0.0.0.0:3478",
			TURNPublicIP:            "127.0.0.1",
			TURNPublicPort:          3478,
			TURNRealm:               "playmesh",
			TURNMinPort:             49160,
			TURNMaxPort:             49260,
			TURNSharedSecret:        "test-turn-shared-secret-at-least-32-bytes",
		},
		WebUI: defaultWebUI(),
		// These values only preserve config.Default() compatibility for unit
		// callers. Load rejects them unless .env overrides them.
		AdminUsername:   "test-admin",
		AdminPassword:   "test-admin-password",
		AdminPath:       "/admin",
		UploadKeyPepper: "test-upload-key-pepper-at-least-32-bytes",
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	if err := loadDotEnv(filepath.Join(filepath.Dir(path), ".env")); err != nil {
		return Config{}, err
	}
	// #nosec G304 -- path is the local operator-supplied server.json path,
	// never a value accepted from an HTTP request.
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("解析配置: %w", err)
	}
	cfg.normalize()
	if err := cfg.applyEnvironment(); err != nil {
		return Config{}, err
	}
	if cfg.AdminUsername == "test-admin" || cfg.AdminPassword == "test-admin-password" {
		return Config{}, errors.New("必须在 .env 配置 PLAYMESH_ADMIN_USERNAME 和 PLAYMESH_ADMIN_PASSWORD")
	}
	if cfg.Auth.PublishedToken == "test-published-token-at-least-32-bytes" ||
		cfg.Auth.ReviewToken == "test-review-token-at-least-32-bytes" {
		return Config{}, errors.New("必须在 .env 配置正式发布 Token 和待审核 Token")
	}
	if cfg.AdminPath == "/admin" {
		return Config{}, errors.New("必须在 .env 配置不可预测的 PLAYMESH_ADMIN_PATH")
	}
	if cfg.UploadKeyPepper == "test-upload-key-pepper-at-least-32-bytes" {
		return Config{}, errors.New("必须在 .env 配置 PLAYMESH_UPLOAD_KEY_PEPPER")
	}
	if cfg.SupportsGameRelay &&
		cfg.Relay.TURNSharedSecret == "test-turn-shared-secret-at-least-32-bytes" {
		return Config{}, errors.New("必须在 .env 配置 PLAYMESH_TURN_SHARED_SECRET（TURN REST 临时凭据 HMAC 共享密钥，至少 32 字节；参见 .env.example）")
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	cfg.ConfigPath = filepath.Clean(path)
	return cfg, nil
}

func (c Config) Save() error {
	if strings.TrimSpace(c.ConfigPath) == "" {
		return errors.New("当前配置没有可写入的 server.json 路径")
	}
	copyForDisk := c
	copyForDisk.Listen = ""
	copyForDisk.Auth.Token = ""
	copyForDisk.Auth.PublishedToken = ""
	copyForDisk.Auth.ReviewToken = ""
	copyForDisk.AdminUsername = ""
	copyForDisk.AdminPassword = ""
	copyForDisk.AdminPath = ""
	copyForDisk.Admin.CaptchaMode = ""
	copyForDisk.Admin.CaptchaImageSource = ""
	copyForDisk.Admin.CaptchaImageDirectory = ""
	copyForDisk.Admin.CaptchaImageURL = ""
	copyForDisk.Admin.CaptchaImageCacheSize = 0
	copyForDisk.Admin.CaptchaIntervalMilliseconds = 0
	copyForDisk.Mail = Mail{}
	copyForDisk.UploadKeyPepper = ""
	copyForDisk.Relay.TURNSharedSecret = ""
	copyForDisk.ConfigPath = ""
	data, err := json.MarshalIndent(copyForDisk, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化 server.json: %w", err)
	}
	data = append(data, '\n')
	directory := filepath.Dir(c.ConfigPath)
	temp, err := os.CreateTemp(directory, "server-*.json.tmp")
	if err != nil {
		return fmt.Errorf("创建 server.json 临时文件: %w", err)
	}
	tempPath := temp.Name()
	cleanup := func() {
		_ = temp.Close()
		_ = os.Remove(tempPath)
	}
	if err := temp.Chmod(0o640); err != nil && os.PathSeparator != '\\' {
		cleanup()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := temp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := temp.Close(); err != nil {
		_ = os.Remove(tempPath)
		return err
	}
	if err := os.Rename(tempPath, c.ConfigPath); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("替换 server.json: %w", err)
	}
	return nil
}

func (c *Config) normalize() {
	if strings.TrimSpace(c.ExternalListen) == "" {
		c.ExternalListen = c.Listen
	}
	if strings.TrimSpace(c.Auth.PublishedToken) == "" {
		c.Auth.PublishedToken = c.Auth.Token
	}
	c.Listen = c.ExternalListen
	c.Auth.Token = c.Auth.PublishedToken
	if c.Storage.MaxConcurrentScans == 0 {
		c.Storage.MaxConcurrentScans = 4
	}
	// Retire only exact historical defaults that are no longer part of upload
	// policy. Keeping the pattern check preserves operator-defined rules that
	// happen to reuse an old ID with different semantics.
	contentRules := c.Scanner.ContentRules[:0]
	for _, rule := range c.Scanner.ContentRules {
		if isRetiredDefaultContentRule(rule) {
			continue
		}
		contentRules = append(contentRules, rule)
	}
	c.Scanner.ContentRules = contentRules
}

func isRetiredDefaultContentRule(rule ContentRule) bool {
	switch rule.ID {
	case "parent-path":
		return rule.Pattern == `(?:\.\./|\.\.\\)`
	case "external-http-ws":
		return rule.Pattern == `(?i)(?:https?|wss?)://`
	case "protocol-relative-attribute":
		return rule.Pattern == `(?i)(?:src|href|action)\s*=\s*["']//`
	case "protocol-relative-css":
		return rule.Pattern == `(?i)url\s*\(\s*["']?//`
	case "protocol-relative-script":
		return rule.Pattern == `(?i)["']\s*//[a-z0-9]`
	case "function-constructor":
		return rule.Pattern == `(?i)new\s+Function\s*\(`
	case "file-protocol":
		return rule.Pattern == `(?i)file://`
	case "javascript-url":
		return rule.Pattern == `(?i)javascript\s*:`
	case "embedded-document":
		return rule.Pattern == `(?i)<\s*(iframe|object|embed)\b`
	default:
		return false
	}
}

func (c *Config) applyEnvironment() error {
	c.AdminUsername = envOr("PLAYMESH_ADMIN_USERNAME", c.AdminUsername)
	c.AdminPassword = envOr("PLAYMESH_ADMIN_PASSWORD", c.AdminPassword)
	c.AdminPath = envOr("PLAYMESH_ADMIN_PATH", c.AdminPath)
	c.Auth.PublishedToken = envOr("PLAYMESH_PUBLISHED_TOKEN", c.Auth.PublishedToken)
	c.Auth.ReviewToken = envOr("PLAYMESH_REVIEW_TOKEN", c.Auth.ReviewToken)
	c.Auth.Token = c.Auth.PublishedToken
	c.Scanner.ClamScanPath = envOr("PLAYMESH_CLAMSCAN_PATH", c.Scanner.ClamScanPath)
	c.Admin.CaptchaMode = envOr("PLAYMESH_CAPTCHA_MODE", c.Admin.CaptchaMode)
	c.Admin.CaptchaImageSource = envOr(
		"PLAYMESH_CAPTCHA_IMAGE_SOURCE", c.Admin.CaptchaImageSource,
	)
	c.Admin.CaptchaImageDirectory = envOr(
		"PLAYMESH_CAPTCHA_IMAGE_DIRECTORY", c.Admin.CaptchaImageDirectory,
	)
	c.Admin.CaptchaImageURL = envOr(
		"PLAYMESH_CAPTCHA_IMAGE_URL", c.Admin.CaptchaImageURL,
	)

	var err error
	c.Admin.CaptchaImageCacheSize, err = envInt(
		"PLAYMESH_CAPTCHA_IMAGE_CACHE_SIZE", c.Admin.CaptchaImageCacheSize,
	)
	if err != nil {
		return err
	}
	c.Admin.CaptchaIntervalMilliseconds, err = envInt(
		"PLAYMESH_CAPTCHA_INTERVAL_MILLISECONDS",
		c.Admin.CaptchaIntervalMilliseconds,
	)
	if err != nil {
		return err
	}
	c.Scanner.Enabled, err = envBool("PLAYMESH_CLAMAV_ENABLED", true)
	if err != nil {
		return err
	}
	c.Mail.Enabled, err = envBool("PLAYMESH_SMTP_ENABLED", false)
	if err != nil {
		return err
	}
	c.Mail.Host = strings.TrimSpace(os.Getenv("PLAYMESH_SMTP_HOST"))
	c.Mail.Port, err = envInt("PLAYMESH_SMTP_PORT", 587)
	if err != nil {
		return err
	}
	c.Mail.Username = strings.TrimSpace(os.Getenv("PLAYMESH_SMTP_USERNAME"))
	c.Mail.Password = os.Getenv("PLAYMESH_SMTP_PASSWORD")
	c.Mail.From = strings.TrimSpace(os.Getenv("PLAYMESH_SMTP_FROM"))
	c.Mail.UseTLS, err = envBool("PLAYMESH_SMTP_TLS", false)
	if err != nil {
		return err
	}
	c.Mail.SendReviewFailures, err = envBool("PLAYMESH_SMTP_SEND_REVIEW_FAILURES", true)
	c.UploadKeyPepper = os.Getenv("PLAYMESH_UPLOAD_KEY_PEPPER")
	c.Relay.TURNSharedSecret = envOr(
		"PLAYMESH_TURN_SHARED_SECRET",
		c.Relay.TURNSharedSecret,
	)
	return err
}

func (c Config) Validate() error {
	if err := validateListen("externalListen", c.ExternalListen); err != nil {
		return err
	}
	if err := validateListen("admin.listen", c.Admin.Listen); err != nil {
		return err
	}
	if c.ExternalListen == c.Admin.Listen {
		return errors.New("外部端口与后台管理端口必须分离")
	}
	if strings.TrimSpace(c.Auth.PublishedToken) == "" ||
		strings.TrimSpace(c.Auth.ReviewToken) == "" {
		return errors.New("正式发布 Token 和待审核 Token 均不能为空")
	}
	if c.Auth.PublishedToken == c.Auth.ReviewToken {
		return errors.New("正式发布 Token 与待审核 Token 必须不同")
	}
	if len(c.UploadKeyPepper) < 32 {
		return errors.New("必须通过 PLAYMESH_UPLOAD_KEY_PEPPER 配置至少 32 字节的上传密钥 Pepper")
	}
	if strings.TrimSpace(c.AdminUsername) == "" ||
		strings.TrimSpace(c.AdminPassword) == "" {
		return errors.New("管理员账号和密码均不能为空")
	}
	if err := validateAdminPath(c.AdminPath); err != nil {
		return err
	}
	if c.Admin.CaptchaMode != "text" &&
		c.Admin.CaptchaMode != "slide" &&
		c.Admin.CaptchaMode != "rotate" {
		return errors.New("PLAYMESH_CAPTCHA_MODE 只能是 text、slide 或 rotate")
	}
	if c.Admin.CaptchaImageCacheSize < 0 || c.Admin.CaptchaImageCacheSize > 128 {
		return errors.New("PLAYMESH_CAPTCHA_IMAGE_CACHE_SIZE 必须在 0 到 128 之间")
	}
	switch c.Admin.CaptchaImageSource {
	case "local":
		if strings.TrimSpace(c.Admin.CaptchaImageDirectory) == "" {
			return errors.New("local 验证码图片源必须配置 PLAYMESH_CAPTCHA_IMAGE_DIRECTORY")
		}
	case "remote":
		if err := validateHTTPURL(
			"PLAYMESH_CAPTCHA_IMAGE_URL", c.Admin.CaptchaImageURL, false,
		); err != nil {
			return err
		}
		if c.Admin.CaptchaImageCacheSize < 1 ||
			c.Admin.CaptchaImageCacheSize > 128 {
			return errors.New("PLAYMESH_CAPTCHA_IMAGE_CACHE_SIZE 必须在 1 到 128 之间")
		}
	default:
		return errors.New("PLAYMESH_CAPTCHA_IMAGE_SOURCE 只能是 local 或 remote")
	}
	if c.Admin.SessionTTLMinutes < 1 ||
		c.Admin.SessionTTLMinutes > 30*24*60 ||
		c.Admin.LoginIntervalMilliseconds < 100 ||
		c.Admin.LoginIntervalMilliseconds > 60*1000 ||
		c.Admin.CaptchaIntervalMilliseconds < 100 ||
		c.Admin.CaptchaIntervalMilliseconds > 60*1000 {
		return errors.New("管理员会话和登录/验证码限流配置无效")
	}
	allowedWhitelist := map[string]struct{}{
		"GET /health":          {},
		"GET /apps/info":       {},
		"GET /apps/list":       {},
		"GET /apps/icon":       {},
		"GET /apps/download":   {},
		"GET /relay/v1/client": {},
	}
	seenWhitelist := make(map[string]struct{}, len(c.Auth.Whitelist))
	for _, entry := range c.Auth.Whitelist {
		key := strings.ToUpper(strings.TrimSpace(entry.Method)) + " " +
			strings.TrimSpace(entry.Path)
		if _, allowed := allowedWhitelist[key]; !allowed {
			return fmt.Errorf("auth.whitelist 不允许跳过鉴权: %s", key)
		}
		if _, exists := seenWhitelist[key]; exists {
			return fmt.Errorf("auth.whitelist 包含重复项: %s", key)
		}
		seenWhitelist[key] = struct{}{}
	}
	if c.Homepage != "" {
		if err := validateHTTPURL("homepage", c.Homepage, false); err != nil {
			return err
		}
	}
	if err := validateWebUI(c.WebUI); err != nil {
		return err
	}
	if c.Storage.DatabasePath == "" || c.Storage.GamesDirectory == "" ||
		c.Storage.QuarantineDirectory == "" {
		return errors.New("数据库、游戏包和隔离目录不能为空")
	}
	if err := validateStorageLayout(c.Storage); err != nil {
		return err
	}
	if c.Storage.MaxUploadBytes < 1 || c.Storage.MaxExpandedBytes < 1 ||
		c.Storage.MaxFileBytes < 1 || c.Storage.MaxFiles < 1 ||
		c.Storage.MaxCompressionRatio < 1 ||
		c.Storage.MaxConcurrentScans < 1 ||
		c.Storage.MaxConcurrentScans > 64 ||
		c.Storage.PublicUploadIntervalSeconds < 1 {
		return errors.New("上传安全限制必须为正整数")
	}
	if c.Storage.MaxUploadBytes > 2<<30 ||
		c.Storage.MaxExpandedBytes > 8<<30 ||
		c.Storage.MaxFileBytes > 1<<30 ||
		c.Storage.MaxFileBytes > c.Storage.MaxExpandedBytes ||
		c.Storage.MaxFiles > 100000 ||
		c.Storage.MaxCompressionRatio > 10000 ||
		c.Storage.PublicUploadIntervalSeconds > 24*60*60 {
		return errors.New("上传安全限制超过平台允许上界")
	}
	if c.Scanner.TimeoutSeconds < 1 || c.Scanner.TimeoutSeconds > 3600 {
		return errors.New("scanner.timeoutSeconds 必须为正整数")
	}
	if c.Scanner.Enabled && c.Scanner.Required &&
		strings.TrimSpace(c.Scanner.ClamScanPath) == "" {
		return errors.New("启用强制病毒扫描时 clamScanPath 不能为空")
	}
	if c.Scanner.Enabled {
		clamExecutable := strings.ToLower(
			filepath.Base(strings.TrimSpace(c.Scanner.ClamScanPath)),
		)
		if clamExecutable != "clamscan" && clamExecutable != "clamscan.exe" {
			return errors.New("scanner.clamScanPath 必须指向 clamscan 或 clamscan.exe")
		}
	}
	seenRuleIDs := make(map[string]struct{}, len(c.Scanner.ContentRules))
	enabledRules := 0
	if len(c.Scanner.ContentRules) > 256 {
		return errors.New("scanner.contentRules 不能超过 256 条")
	}
	for index, rule := range c.Scanner.ContentRules {
		if strings.TrimSpace(rule.ID) == "" || strings.TrimSpace(rule.Description) == "" ||
			strings.TrimSpace(rule.Pattern) == "" {
			return fmt.Errorf("scanner.contentRules[%d] 缺少 id、description 或 pattern", index)
		}
		if len(rule.ID) > 64 || len([]rune(rule.Description)) > 200 ||
			len(rule.Pattern) > 16<<10 || len(rule.Extensions) > 64 {
			return fmt.Errorf("scanner.contentRules[%d] 字段超过安全长度", index)
		}
		if _, exists := seenRuleIDs[rule.ID]; exists {
			return fmt.Errorf("scanner.contentRules 包含重复 id: %s", rule.ID)
		}
		seenRuleIDs[rule.ID] = struct{}{}
		if _, err := regexp.Compile(rule.Pattern); err != nil {
			return fmt.Errorf("scanner.contentRules[%s] 正则无效: %w", rule.ID, err)
		}
		for _, extension := range rule.Extensions {
			if !strings.HasPrefix(extension, ".") ||
				extension != strings.ToLower(extension) {
				return fmt.Errorf("scanner.contentRules[%s] 扩展名必须是小写 .ext", rule.ID)
			}
		}
		if rule.Enabled {
			enabledRules++
		}
	}
	if enabledRules == 0 {
		return errors.New("scanner.contentRules 至少需要一条启用的内容扫描规则")
	}
	if c.SupportsGameRelay || c.ShowPublicSourceQRCode || c.RequireEmailVerification {
		if err := validateHTTPURL("relay.publicBaseUrl", c.Relay.PublicBaseURL, true); err != nil {
			return err
		}
	}
	if c.Relay.TunnelTTLSeconds < 1 ||
		c.Relay.MaxTunnels < 1 ||
		c.Relay.MaxConnectionsPerTunnel < 1 ||
		c.Relay.MaxConnectionsPerIP < 1 {
		return errors.New("relay 限制必须为正整数")
	}
	if c.Relay.TunnelTTLSeconds > 7*24*60*60 ||
		c.Relay.MaxTunnels > 100000 ||
		c.Relay.MaxConnectionsPerTunnel > 1024 ||
		c.Relay.MaxConnectionsPerIP > 4096 {
		return errors.New("relay 限制超过平台允许上界")
	}
	if c.SupportsGameRelay {
		if err := validateListen("relay.turnUdpListen", c.Relay.TURNUDPListen); err != nil {
			return err
		}
		if err := validateListen("relay.turnTcpListen", c.Relay.TURNTCPListen); err != nil {
			return err
		}
		if ip := net.ParseIP(strings.TrimSpace(c.Relay.TURNPublicIP)); ip == nil || ip.To4() == nil {
			return errors.New("relay.turnPublicIp 必须是公网 IPv4 地址")
		}
		if c.Relay.TURNPublicPort < 1 || c.Relay.TURNPublicPort > 65535 ||
			c.Relay.TURNMinPort < 1024 || c.Relay.TURNMaxPort > 65535 ||
			c.Relay.TURNMinPort > c.Relay.TURNMaxPort {
			return errors.New("TURN 公共端口或中继端口范围无效")
		}
		if strings.TrimSpace(c.Relay.TURNRealm) == "" ||
			len(c.Relay.TURNSharedSecret) < 32 {
			return errors.New("TURN realm 不能为空且共享密钥至少需要 32 字节")
		}
	}
	if c.Mail.Enabled {
		if c.Mail.Host == "" || c.Mail.Port < 1 || c.Mail.Port > 65535 ||
			c.Mail.From == "" {
			return errors.New("启用 SMTP 时 host、port、from 必须有效")
		}
		if _, err := mail.ParseAddress(c.Mail.From); err != nil {
			return fmt.Errorf("PLAYMESH_SMTP_FROM 无效: %w", err)
		}
	}
	if c.RequireEmailVerification && !c.Mail.Enabled {
		return errors.New("启用邮箱验证时必须同时启用 SMTP")
	}
	return nil
}

func validateAdminPath(value string) error {
	value = strings.TrimSpace(value)
	if value == "" || value[0] != '/' || value == "/" {
		return errors.New("PLAYMESH_ADMIN_PATH 必须是以 / 开头的非根路径")
	}
	if strings.HasSuffix(value, "/") ||
		strings.Contains(value, "//") ||
		strings.Contains(value, "..") {
		return errors.New("PLAYMESH_ADMIN_PATH 格式无效")
	}
	if !regexp.MustCompile(`^/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$`).MatchString(value) {
		return errors.New("PLAYMESH_ADMIN_PATH 只能包含字母、数字、-、_ 和路径分隔符")
	}
	lower := strings.ToLower(value)
	for _, reserved := range []string{"/api", "/assets", "/health"} {
		if lower == reserved || strings.HasPrefix(lower, reserved+"/") {
			return errors.New("PLAYMESH_ADMIN_PATH 不能占用保留路径")
		}
	}
	return nil
}

func validateListen(name, value string) error {
	host, port, err := net.SplitHostPort(strings.TrimSpace(value))
	if err != nil || host == "" {
		return fmt.Errorf("%s 必须是 host:port", name)
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return fmt.Errorf("%s 端口无效", name)
	}
	return nil
}

func validateHTTPURL(name, value string, originOnly bool) error {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return fmt.Errorf("%s 必须是有效 HTTP/HTTPS 地址", name)
	}
	if originOnly && (parsed.RawQuery != "" || (parsed.Path != "" && parsed.Path != "/")) {
		return fmt.Errorf("%s 只能包含协议、主机和端口", name)
	}
	return nil
}

func validateWebUI(value WebUI) error {
	catalog, err := localization.Load()
	if err != nil {
		return fmt.Errorf("加载 go-server 本地化资源: %w", err)
	}
	if strings.TrimSpace(value.DefaultLocale) == "" || len(value.EnabledLocales) == 0 {
		return errors.New("webUI 必须配置默认语言和至少一种启用语言")
	}
	available := make(map[string]struct{})
	for _, locale := range catalog.EnabledLocaleIDs() {
		available[locale] = struct{}{}
	}
	seen := make(map[string]struct{}, len(value.EnabledLocales))
	defaultEnabled := false
	for _, locale := range value.EnabledLocales {
		locale = strings.TrimSpace(locale)
		if locale == "" {
			return errors.New("webUI.enabledLocales 不能包含空语言")
		}
		if _, exists := available[locale]; !exists {
			return fmt.Errorf("webUI.enabledLocales 引用未知语言 %s", locale)
		}
		if _, exists := seen[locale]; exists {
			return errors.New("webUI.enabledLocales 不能包含重复语言")
		}
		seen[locale] = struct{}{}
		if locale == value.DefaultLocale {
			defaultEnabled = true
		}
	}
	if !defaultEnabled {
		return errors.New("webUI.defaultLocale 必须位于 enabledLocales")
	}
	switch value.DefaultThemeMode {
	case "system", "light", "dark":
	default:
		return errors.New("webUI.defaultThemeMode 只能是 system、light 或 dark")
	}
	return nil
}

func defaultWebUI() WebUI {
	catalog, err := localization.Load()
	if err != nil {
		return WebUI{}
	}
	return WebUI{
		DefaultLocale:     catalog.Manifest.DefaultLocale,
		EnabledLocales:    catalog.EnabledLocaleIDs(),
		AllowLocaleSwitch: catalog.Manifest.UI.AllowLocaleSwitch,
		DefaultThemeMode:  "light",
		AllowThemeSwitch:  false,
	}
}

func validateStorageLayout(storage Storage) error {
	database, err := filepath.Abs(filepath.Clean(storage.DatabasePath))
	if err != nil {
		return fmt.Errorf("databasePath 无效: %w", err)
	}
	games, err := filepath.Abs(filepath.Clean(storage.GamesDirectory))
	if err != nil {
		return fmt.Errorf("gamesDirectory 无效: %w", err)
	}
	quarantine, err := filepath.Abs(filepath.Clean(storage.QuarantineDirectory))
	if err != nil {
		return fmt.Errorf("quarantineDirectory 无效: %w", err)
	}
	if games == filepath.VolumeName(games)+string(filepath.Separator) ||
		quarantine == filepath.VolumeName(quarantine)+string(filepath.Separator) {
		return errors.New("游戏包和隔离目录不能是文件系统根目录")
	}
	if pathsOverlap(games, quarantine) {
		return errors.New("游戏包目录与隔离目录不能相同或互相嵌套")
	}
	if pathContains(games, database) || pathContains(quarantine, database) {
		return errors.New("SQLite 数据库不能位于游戏包或隔离目录内")
	}
	return nil
}

func pathsOverlap(left, right string) bool {
	return pathContains(left, right) || pathContains(right, left)
}

func pathContains(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	if err != nil || filepath.IsAbs(relative) {
		return false
	}
	return relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func loadDotEnv(path string) error {
	// #nosec G304 -- path is derived from the local server.json directory,
	// never a value accepted from an HTTP request.
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("读取 .env: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		name, value, ok := strings.Cut(line, "=")
		if !ok {
			return fmt.Errorf(".env 行缺少等号: %q", line)
		}
		name = strings.TrimSpace(name)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if name == "" {
			return errors.New(".env 变量名不能为空")
		}
		if _, exists := os.LookupEnv(name); !exists {
			if err := os.Setenv(name, value); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}

func envOr(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return strings.TrimSpace(value)
	}
	return fallback
}

func envBool(name string, fallback bool) (bool, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(strings.TrimSpace(value))
	if err != nil {
		return false, fmt.Errorf("%s 必须是布尔值", name)
	}
	return parsed, nil
}

func envInt(name string, fallback int) (int, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return 0, fmt.Errorf("%s 必须是整数", name)
	}
	return parsed, nil
}

func (r Relay) TunnelTTL() time.Duration {
	return time.Duration(r.TunnelTTLSeconds) * time.Second
}
