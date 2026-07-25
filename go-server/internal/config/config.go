package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
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
	Token     string           `json:"token"`
	Whitelist []WhitelistEntry `json:"whitelist"`
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
	Listen            string `json:"listen"`
	Name              string `json:"name"`
	Author            string `json:"author"`
	Homepage          string `json:"homepage"`
	SupportsGameRelay bool   `json:"supportsGameRelay"`
	Auth              Auth   `json:"auth"`
	Relay             Relay  `json:"relay"`
}

func Default() Config {
	return Config{
		Listen:            "0.0.0.0:16668",
		Name:              "Playmesh 公共游戏源",
		SupportsGameRelay: true,
		Auth: Auth{Whitelist: []WhitelistEntry{
			{Method: "GET", Path: "/health"},
			{Method: "GET", Path: "/relay/v1/client"},
		}},
		Relay: Relay{
			PublicBaseURL:                   "http://127.0.0.1:16668",
			TunnelTTLSeconds:                21600,
			PendingConnectionTimeoutSeconds: 15,
			IdleTimeoutSeconds:              120,
			MaxTunnels:                      1000,
			MaxConnectionsPerTunnel:         64,
			MaxConnectionsPerIP:             32,
		},
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("解析配置: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if strings.TrimSpace(c.Listen) == "" {
		return errors.New("listen 不能为空")
	}
	if c.Homepage != "" {
		homepage, err := url.Parse(c.Homepage)
		if err != nil || homepage.Host == "" ||
			(homepage.Scheme != "http" && homepage.Scheme != "https") {
			return errors.New("homepage 必须是 HTTP/HTTPS 地址")
		}
	}
	for _, entry := range c.Auth.Whitelist {
		if strings.TrimSpace(entry.Method) == "" || !strings.HasPrefix(entry.Path, "/") {
			return errors.New("auth.whitelist 必须包含有效 method 和 path")
		}
	}
	if c.SupportsGameRelay {
		publicBaseURL, err := url.Parse(strings.TrimSpace(c.Relay.PublicBaseURL))
		if err != nil ||
			(publicBaseURL.Scheme != "http" && publicBaseURL.Scheme != "https") ||
			publicBaseURL.Host == "" ||
			publicBaseURL.User != nil ||
			publicBaseURL.RawQuery != "" ||
			publicBaseURL.Fragment != "" ||
			(publicBaseURL.Path != "" && publicBaseURL.Path != "/") {
			return errors.New("relay.publicBaseUrl 必须是只包含协议、主机和端口的 HTTP/HTTPS 地址")
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
	return nil
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
