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
	Token          string           `json:"token,omitempty"`
	PublishedToken string           `json:"-"`
	ReviewToken    string           `json:"-"`
	Whitelist      []WhitelistEntry `json:"whitelist"`
}

type Admin struct {
	Listen                     string `json:"listen"`
	CaptchaMode                string `json:"captchaMode"`
	SessionTTLMinutes          int    `json:"sessionTtlMinutes"`
	LoginIntervalMilliseconds  int    `json:"loginIntervalMilliseconds"`
	CaptchaIntervalMilliseconds int   `json:"captchaIntervalMilliseconds"`
}

type Storage struct {
	DatabasePath          string `json:"databasePath"`
	GamesDirectory        string `json:"gamesDirectory"`
	QuarantineDirectory   string `json:"quarantineDirectory"`
	MaxUploadBytes        int64  `json:"maxUploadBytes"`
	MaxExpandedBytes      int64  `json:"maxExpandedBytes"`
	MaxFileBytes          int64  `json:"maxFileBytes"`
	MaxFiles              int    `json:"maxFiles"`
	MaxCompressionRatio   int64  `json:"maxCompressionRatio"`
	PublicUploadIntervalSeconds int `json:"publicUploadIntervalSeconds"`
}

type Scanner struct {
	ClamScanPath   string `json:"clamScanPath"`
	Required       bool   `json:"required"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
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
	Listen            string `json:"listen,omitempty"`
	ExternalListen    string `json:"externalListen"`
	Name              string `json:"name"`
	Author            string `json:"author"`
	Homepage          string `json:"homepage"`
	SupportsGameRelay bool   `json:"supportsGameRelay"`
	Auth              Auth   `json:"auth"`
	Admin             Admin  `json:"admin"`
	Storage           Storage `json:"storage"`
	Scanner           Scanner `json:"scanner"`
	Relay             Relay  `json:"relay"`

	AdminUsername string `json:"-"`
	AdminPassword string `json:"-"`
	Mail          Mail   `json:"-"`
}

func Default() Config {
	return Config{
		ExternalListen:    "0.0.0.0:16668",
		Name:              "Playmesh 公共游戏源",
		SupportsGameRelay: true,
		Auth: Auth{
			PublishedToken: "test-published-token",
			ReviewToken:    "test-review-token",
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
			PublicUploadIntervalSeconds: 60,
		},
		Scanner: Scanner{
			ClamScanPath:   "clamscan",
			Required:       true,
			TimeoutSeconds: 120,
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
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	if err := loadDotEnv(filepath.Join(filepath.Dir(path), ".env")); err != nil {
		return Config{}, err
	}
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
	if cfg.Auth.PublishedToken == "test-published-token" ||
		cfg.Auth.ReviewToken == "test-review-token" {
		return Config{}, errors.New("必须在 .env 配置正式发布 Token 和待审核 Token")
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
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
}

func (c *Config) applyEnvironment() error {
	c.AdminUsername = envOr("PLAYMESH_ADMIN_USERNAME", c.AdminUsername)
	c.AdminPassword = envOr("PLAYMESH_ADMIN_PASSWORD", c.AdminPassword)
	c.Auth.PublishedToken = envOr("PLAYMESH_PUBLISHED_TOKEN", c.Auth.PublishedToken)
	c.Auth.ReviewToken = envOr("PLAYMESH_REVIEW_TOKEN", c.Auth.ReviewToken)
	c.Auth.Token = c.Auth.PublishedToken
	c.Scanner.ClamScanPath = envOr("PLAYMESH_CLAMSCAN_PATH", c.Scanner.ClamScanPath)

	var err error
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
	if strings.TrimSpace(c.AdminUsername) == "" || len(c.AdminPassword) < 12 {
		return errors.New("管理员账号不能为空，密码长度至少为 12")
	}
	if c.Admin.CaptchaMode != "math" && c.Admin.CaptchaMode != "text" {
		return errors.New("admin.captchaMode 只能是 math 或 text")
	}
	if c.Admin.SessionTTLMinutes < 1 ||
		c.Admin.LoginIntervalMilliseconds < 100 ||
		c.Admin.CaptchaIntervalMilliseconds < 100 {
		return errors.New("管理员会话和登录/验证码限流配置无效")
	}
	for _, entry := range c.Auth.Whitelist {
		if strings.TrimSpace(entry.Method) == "" || !strings.HasPrefix(entry.Path, "/") {
			return errors.New("auth.whitelist 必须包含有效 method 和 path")
		}
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
	if c.Storage.MaxUploadBytes < 1 || c.Storage.MaxExpandedBytes < 1 ||
		c.Storage.MaxFileBytes < 1 || c.Storage.MaxFiles < 1 ||
		c.Storage.MaxCompressionRatio < 1 ||
		c.Storage.PublicUploadIntervalSeconds < 1 {
		return errors.New("上传安全限制必须为正整数")
	}
	if c.Scanner.TimeoutSeconds < 1 {
		return errors.New("scanner.timeoutSeconds 必须为正整数")
	}
	if c.Scanner.Required && strings.TrimSpace(c.Scanner.ClamScanPath) == "" {
		return errors.New("启用强制病毒扫描时 clamScanPath 不能为空")
	}
	if c.SupportsGameRelay {
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

func loadDotEnv(path string) error {
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
