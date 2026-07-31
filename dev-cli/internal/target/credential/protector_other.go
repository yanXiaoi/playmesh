//go:build !windows && !darwin && !linux

package credential

import "errors"

func platformProtect(token string) (string, string, error) {
	return "", "", errors.New("当前平台不支持安全 token 存储")
}

func platformUnprotect(storage, protected string) (string, error) {
	return "", errors.New("当前平台不支持安全 token 存储")
}
