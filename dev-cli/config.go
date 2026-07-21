package main

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type targetConfig struct {
	BaseURL      string `json:"baseUrl"`
	WorkspaceURL string `json:"workspaceUrl"`
	WorkspaceID  string `json:"workspaceId"`
	Token        string `json:"token"`
}

var workspacePathPattern = regexp.MustCompile(`^/dev/([^/]+)/workspace$`)

func parseWorkspaceURL(raw string) (targetConfig, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return targetConfig{}, errors.New("开发者工作区链接无效")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return targetConfig{}, errors.New("工作区链接只支持 http 或 https")
	}
	match := workspacePathPattern.FindStringSubmatch(parsed.EscapedPath())
	if len(match) != 2 {
		return targetConfig{}, errors.New("工作区链接路径必须是 /dev/{workspaceId}/workspace")
	}
	token := parsed.Query().Get("token")
	if token == "" {
		return targetConfig{}, errors.New("工作区链接缺少 token")
	}
	workspaceURL := *parsed
	workspaceURL.RawQuery = ""
	workspaceURL.Fragment = ""
	base := &url.URL{Scheme: parsed.Scheme, Host: parsed.Host}
	return targetConfig{
		BaseURL:      strings.TrimRight(base.String(), "/"),
		WorkspaceURL: workspaceURL.String(),
		WorkspaceID:  match[1],
		Token:        token,
	}, nil
}

func configPath() (string, error) {
	directory, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(directory, "Playmesh", "cli-target.json"), nil
}

func saveTarget(target targetConfig) error {
	path, err := configPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(target, "", "  ")
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return replaceFile(temporary, path)
}

func loadTarget() (targetConfig, error) {
	path, err := configPath()
	if err != nil {
		return targetConfig{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return targetConfig{}, errors.New("尚未连接目标 App，请先执行 playmesh-cli to")
		}
		return targetConfig{}, err
	}
	var target targetConfig
	if err := json.Unmarshal(data, &target); err != nil {
		return targetConfig{}, errors.New("全局目标配置损坏，请重新执行 playmesh-cli to")
	}
	if target.BaseURL == "" || target.Token == "" {
		return targetConfig{}, errors.New("全局目标配置不完整，请重新执行 playmesh-cli to")
	}
	return target, nil
}
