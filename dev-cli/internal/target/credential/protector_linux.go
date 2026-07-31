//go:build linux

package credential

import (
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

const (
	linuxTokenStorage  = "linux-secret-service"
	linuxSecretAccount = "playmesh-cli-target"
)

func platformProtect(token string) (string, string, error) {
	if token == "" {
		return "", "", errors.New("目标 App token 不能为空")
	}
	secretTool, err := exec.LookPath("secret-tool")
	if err != nil {
		return "", "", errors.New(
			"系统缺少 secret-tool，无法安全保存 token；请安装 libsecret-tools",
		)
	}
	command := exec.Command(
		secretTool,
		"store",
		"--label=Playmesh CLI target",
		"application",
		"playmesh-cli",
		"account",
		linuxSecretAccount,
	)
	command.Stdin = strings.NewReader(token)
	if output, err := command.CombinedOutput(); err != nil {
		return "", "", fmt.Errorf("写入 Linux Secret Service: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return linuxTokenStorage, linuxSecretAccount, nil
}

func platformUnprotect(storage, reference string) (string, error) {
	if storage != linuxTokenStorage || reference == "" {
		return "", fmt.Errorf("不支持的 token 存储方式 %q", storage)
	}
	secretTool, err := exec.LookPath("secret-tool")
	if err != nil {
		return "", err
	}
	command := exec.Command(
		secretTool,
		"lookup",
		"application",
		"playmesh-cli",
		"account",
		reference,
	)
	output, err := command.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}
