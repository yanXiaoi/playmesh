package target

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/target/credential"
)

type Config struct {
	BaseURL      string
	WorkspaceURL string
	WorkspaceID  string
	Token        string
}

type persistedTargetConfig struct {
	BaseURL        string `json:"baseUrl"`
	WorkspaceURL   string `json:"workspaceUrl,omitempty"`
	WorkspaceID    string `json:"workspaceId,omitempty"`
	TokenStorage   string `json:"tokenStorage,omitempty"`
	ProtectedToken string `json:"protectedToken,omitempty"`
}

var workspacePathPattern = regexp.MustCompile(`^/dev/([^/]+)/workspace$`)

type Store interface {
	Save(Config) error
	Load() (Config, error)
}

type FileStore struct {
	path      func() (string, error)
	protector credential.Protector
}

func NewSystemStore() *FileStore {
	return NewSystemStoreWithProtector(credential.PlatformProtector{})
}

func NewSystemStoreWithProtector(protector credential.Protector) *FileStore {
	return &FileStore{
		path:      systemConfigPath,
		protector: protector,
	}
}

func NewFileStore(path string, protector credential.Protector) *FileStore {
	return &FileStore{
		path: func() (string, error) {
			if strings.TrimSpace(path) == "" {
				return "", errors.New("目标配置路径不能为空")
			}
			return filepath.Clean(path), nil
		},
		protector: protector,
	}
}

func ParseWorkspaceURL(raw string) (Config, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return Config{}, errors.New("开发者工作区链接无效")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return Config{}, errors.New("工作区链接只支持 http 或 https")
	}
	match := workspacePathPattern.FindStringSubmatch(parsed.EscapedPath())
	if len(match) != 2 {
		return Config{}, errors.New("工作区链接路径必须是 /dev/{workspaceId}/workspace")
	}
	token := parsed.Query().Get("token")
	if token == "" {
		return Config{}, errors.New("工作区链接缺少 token")
	}
	workspaceURL := *parsed
	workspaceURL.RawQuery = ""
	workspaceURL.Fragment = ""
	base := &url.URL{Scheme: parsed.Scheme, Host: parsed.Host}
	return Config{
		BaseURL:      strings.TrimRight(base.String(), "/"),
		WorkspaceURL: workspaceURL.String(),
		WorkspaceID:  match[1],
		Token:        token,
	}, nil
}

func systemConfigPath() (string, error) {
	directory, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(directory, "Playmesh", "cli-target.json"), nil
}

func (store *FileStore) Save(target Config) error {
	if store == nil || store.path == nil || store.protector == nil {
		return errors.New("目标配置存储未初始化")
	}
	path, err := store.path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	storage, protected, err := store.protector.Protect(target.Token)
	if err != nil {
		return err
	}
	persisted := persistedTargetConfig{
		BaseURL:        target.BaseURL,
		WorkspaceURL:   target.WorkspaceURL,
		WorkspaceID:    target.WorkspaceID,
		TokenStorage:   storage,
		ProtectedToken: protected,
	}
	data, err := json.MarshalIndent(persisted, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return fsutil.ReplaceFile(temporary, path)
}

func (store *FileStore) Load() (Config, error) {
	if store == nil || store.path == nil || store.protector == nil {
		return Config{}, errors.New("目标配置存储未初始化")
	}
	path, err := store.path()
	if err != nil {
		return Config{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Config{}, errors.New("尚未连接目标 App，请先执行 playmesh-cli to")
		}
		return Config{}, err
	}
	var persisted persistedTargetConfig
	if err := json.Unmarshal(data, &persisted); err != nil {
		return Config{}, errors.New("全局目标配置损坏，请重新执行 playmesh-cli to")
	}
	target := Config{
		BaseURL:      persisted.BaseURL,
		WorkspaceURL: persisted.WorkspaceURL,
		WorkspaceID:  persisted.WorkspaceID,
	}
	if persisted.ProtectedToken != "" {
		target.Token, err = store.protector.Unprotect(
			persisted.TokenStorage,
			persisted.ProtectedToken,
		)
		if err != nil {
			return Config{}, errors.New(
				"无法读取操作系统保护的目标 App 凭据，请重新执行 playmesh-cli to",
			)
		}
	}
	if target.BaseURL == "" || target.Token == "" {
		return Config{}, errors.New("全局目标配置不完整，请重新执行 playmesh-cli to")
	}
	return target, nil
}
