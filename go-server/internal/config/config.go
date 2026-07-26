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
)

const (
	CatalogAPIVersion    = "1.4.0"
	RelayProtocolVersion = "2.0.0"
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
	Listen                      string `json:"listen"`
	CaptchaMode                 string `json:"captchaMode"`
	SessionTTLMinutes           int    `json:"sessionTtlMinutes"`
	LoginIntervalMilliseconds   int    `json:"loginIntervalMilliseconds"`
	CaptchaIntervalMilliseconds int    `json:"captchaIntervalMilliseconds"`
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
	PublicBaseURL                   string `json:"publicBaseUrl"`
	TunnelTTLSeconds                int    `json:"tunnelTTLSeconds"`
	PendingConnectionTimeoutSeconds int    `json:"pendingConnectionTimeoutSeconds"`
	IdleTimeoutSeconds              int    `json:"idleTimeoutSeconds"`
	MaxTunnels                      int    `json:"maxTunnels"`
	MaxConnectionsPerTunnel         int    `json:"maxConnectionsPerTunnel"`
	MaxConnectionsPerIP             int    `json:"maxConnectionsPerIP"`
}

type Config struct {
	// Listen is the legacy external listen field.
	Listen                 string  `json:"listen,omitempty"`
	ExternalListen         string  `json:"externalListen"`
	Name                   string  `json:"name"`
	Author                 string  `json:"author"`
	Homepage               string  `json:"homepage"`
	SupportsGameRelay      bool    `json:"supportsGameRelay"`
	ShowPublicSourceQRCode bool    `json:"showPublicSourceQRCode"`
	Auth                   Auth    `json:"auth"`
	Admin                  Admin   `json:"admin"`
	Storage                Storage `json:"storage"`
	Scanner                Scanner `json:"scanner"`
	Relay                  Relay   `json:"relay"`

	AdminUsername string `json:"-"`
	AdminPassword string `json:"-"`
	AdminPath     string `json:"-"`
	Mail          Mail   `json:"-"`
	ConfigPath    string `json:"-"`
}

func Default() Config {
	return Config{
		ExternalListen:         "0.0.0.0:16668",
		Name:                   "Playmesh 公共游戏源",
		SupportsGameRelay:      true,
		ShowPublicSourceQRCode: true,
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
			CaptchaMode:                 "math",
			SessionTTLMinutes:           480,
			LoginIntervalMilliseconds:   1000,
			CaptchaIntervalMilliseconds: 1000,
		},
		Storage: Storage{
			DatabasePath:                "data/playmesh-server.db",
			GamesDirectory:              "data/games",
			QuarantineDirectory:         "data/quarantine",
			MaxUploadBytes:              64 << 20,
			MaxExpandedBytes:            256 << 20,
			MaxFileBytes:                64 << 20,
			MaxFiles:                    4096,
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
					ID: "external-http-ws", Description: "外部 HTTP/WS 地址",
					Pattern: `(?i)(?:https?|wss?)://`, Enabled: true,
				},
				{
					ID: "protocol-relative-attribute", Description: "HTML 协议相对外部地址",
					Pattern: `(?i)(?:src|href|action)\s*=\s*["']//`, Enabled: true,
				},
				{
					ID: "protocol-relative-css", Description: "CSS 协议相对外部地址",
					Pattern: `(?i)url\s*\(\s*["']?//`, Enabled: true,
				},
				{
					ID: "protocol-relative-script", Description: "脚本协议相对外部地址",
					Pattern: `(?i)["']\s*//[a-z0-9]`, Enabled: true,
				},
				{
					ID: "file-protocol", Description: "本地文件协议",
					Pattern: `(?i)file://`, Enabled: true,
				},
				{
					ID: "javascript-url", Description: "JavaScript URL",
					Pattern: `(?i)javascript\s*:`, Enabled: true,
				},
				{
					ID: "html-data-url", Description: "可执行 HTML Data URL",
					Pattern: `(?i)data\s*:\s*text/html`, Enabled: true,
				},
				{
					ID: "eval", Description: "动态代码执行 eval",
					Pattern: `(?i)\beval\s*\(`, Enabled: true,
				},
				{
					ID: "function-constructor", Description: "动态 Function 构造",
					Pattern: `(?i)new\s+Function\s*\(`, Enabled: true,
				},
				{
					ID: "service-worker", Description: "Service Worker 注册",
					Pattern: `(?i)serviceWorker\s*\.\s*register`, Enabled: true,
				},
				{
					ID: "embedded-document", Description: "嵌入外部文档元素",
					Pattern: `(?i)<\s*(iframe|object|embed)\b`, Enabled: true,
				},
				{
					ID: "active-svg", Description: "SVG 活动脚本或 foreignObject",
					Pattern:    `(?i)<\s*(script|foreignObject)\b`,
					Extensions: []string{".svg"}, Enabled: true,
				},
			},
		},
		Relay: Relay{
			PublicBaseURL:                   "http://127.0.0.1:16668",
			TunnelTTLSeconds:                21600,
			PendingConnectionTimeoutSeconds: 15,
			IdleTimeoutSeconds:              120,
			MaxTunnels:                      1000,
			MaxConnectionsPerTunnel:         64,
			MaxConnectionsPerIP:             32,
		},
		// These values only preserve config.Default() compatibility for unit
		// callers. Load rejects them unless .env overrides them.
		AdminUsername: "test-admin",
		AdminPassword: "test-admin-password",
		AdminPath:     "/admin",
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
	copyForDisk.Mail = Mail{}
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
	// Older releases shipped a broad content rule that rejected every "../"
	// occurrence inside JavaScript. Relative module imports are valid package
	// content, while ZIP entry traversal is already rejected by safeArchivePath.
	// Drop only the exact legacy default so operator-defined rules stay intact.
	contentRules := c.Scanner.ContentRules[:0]
	for _, rule := range c.Scanner.ContentRules {
		if rule.ID == "parent-path" &&
			rule.Pattern == `(?:\.\./|\.\.\\)` {
			continue
		}
		contentRules = append(contentRules, rule)
	}
	c.Scanner.ContentRules = contentRules
}

func (c *Config) applyEnvironment() error {
	c.AdminUsername = envOr("PLAYMESH_ADMIN_USERNAME", c.AdminUsername)
	c.AdminPassword = envOr("PLAYMESH_ADMIN_PASSWORD", c.AdminPassword)
	c.AdminPath = envOr("PLAYMESH_ADMIN_PATH", c.AdminPath)
	c.Auth.PublishedToken = envOr("PLAYMESH_PUBLISHED_TOKEN", c.Auth.PublishedToken)
	c.Auth.ReviewToken = envOr("PLAYMESH_REVIEW_TOKEN", c.Auth.ReviewToken)
	c.Auth.Token = c.Auth.PublishedToken
	c.Scanner.ClamScanPath = envOr("PLAYMESH_CLAMSCAN_PATH", c.Scanner.ClamScanPath)

	var err error
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
	if strings.TrimSpace(c.AdminUsername) == "" ||
		strings.TrimSpace(c.AdminPassword) == "" {
		return errors.New("管理员账号和密码均不能为空")
	}
	if err := validateAdminPath(c.AdminPath); err != nil {
		return err
	}
	if c.Admin.CaptchaMode != "math" && c.Admin.CaptchaMode != "text" {
		return errors.New("admin.captchaMode 只能是 math 或 text")
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
	if c.SupportsGameRelay || c.ShowPublicSourceQRCode {
		if err := validateHTTPURL("relay.publicBaseUrl", c.Relay.PublicBaseURL, true); err != nil {
			return err
		}
	}
	if c.Relay.TunnelTTLSeconds < 1 ||
		c.Relay.PendingConnectionTimeoutSeconds < 1 ||
		c.Relay.IdleTimeoutSeconds < 1 ||
		c.Relay.MaxTunnels < 1 ||
		c.Relay.MaxConnectionsPerTunnel < 1 ||
		c.Relay.MaxConnectionsPerIP < 1 {
		return errors.New("relay 限制必须为正整数")
	}
	if c.Relay.TunnelTTLSeconds > 7*24*60*60 ||
		c.Relay.PendingConnectionTimeoutSeconds > 300 ||
		c.Relay.IdleTimeoutSeconds > 24*60*60 ||
		c.Relay.MaxTunnels > 100000 ||
		c.Relay.MaxConnectionsPerTunnel > 1024 ||
		c.Relay.MaxConnectionsPerIP > 4096 {
		return errors.New("relay 限制超过平台允许上界")
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

func (r Relay) PendingConnectionTimeout() time.Duration {
	return time.Duration(r.PendingConnectionTimeoutSeconds) * time.Second
}

func (r Relay) IdleTimeout() time.Duration {
	return time.Duration(r.IdleTimeoutSeconds) * time.Second
}
