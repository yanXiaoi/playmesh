//go:build darwin

package credential

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

const (
	macOSTokenStorage = "macos-keychain"
	macOSKeychainItem = "playmesh-cli-target"
)

func platformProtect(token string) (string, string, error) {
	if token == "" {
		return "", "", errors.New("目标 App token 不能为空")
	}
	command := exec.Command(
		"/usr/bin/security",
		"add-generic-password",
		"-U",
		"-s",
		"playmesh-cli",
		"-a",
		macOSKeychainItem,
		"-w",
		token,
	)
	if output, err := command.CombinedOutput(); err != nil {
		return "", "", fmt.Errorf("写入 macOS Keychain: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return macOSTokenStorage, macOSKeychainItem, nil
}

func platformUnprotect(storage, reference string) (string, error) {
	if storage != macOSTokenStorage || reference == "" {
		return "", fmt.Errorf("不支持的 token 存储方式 %q", storage)
	}
	command := exec.Command(
		"/usr/bin/security",
		"find-generic-password",
		"-s",
		"playmesh-cli",
		"-a",
		reference,
		"-w",
	)
	output, err := command.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}
