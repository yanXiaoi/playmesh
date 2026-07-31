//go:build windows

package credential

import (
	"encoding/base64"
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

const windowsTokenStorage = "windows-dpapi-current-user"

type windowsDataBlob struct {
	size uint32
	data *byte
}

var (
	crypt32DLL          = syscall.NewLazyDLL("crypt32.dll")
	kernel32DLL         = syscall.NewLazyDLL("kernel32.dll")
	cryptProtectData    = crypt32DLL.NewProc("CryptProtectData")
	cryptUnprotectData  = crypt32DLL.NewProc("CryptUnprotectData")
	windowsLocalFree    = kernel32DLL.NewProc("LocalFree")
	windowsTokenEntropy = []byte("Playmesh Developer CLI target token v2")
)

func platformProtect(token string) (string, string, error) {
	if token == "" {
		return "", "", errors.New("目标 App token 不能为空")
	}
	protected, err := windowsCryptProtect([]byte(token))
	if err != nil {
		return "", "", fmt.Errorf("使用 Windows DPAPI 保护 token: %w", err)
	}
	return windowsTokenStorage, base64.StdEncoding.EncodeToString(protected), nil
}

func platformUnprotect(storage, protected string) (string, error) {
	if storage != windowsTokenStorage {
		return "", fmt.Errorf("不支持的 token 存储方式 %q", storage)
	}
	data, err := base64.StdEncoding.DecodeString(protected)
	if err != nil {
		return "", err
	}
	plain, err := windowsCryptUnprotect(data)
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

func windowsCryptProtect(plain []byte) ([]byte, error) {
	input := windowsBlob(plain)
	entropy := windowsBlob(windowsTokenEntropy)
	var output windowsDataBlob
	result, _, callErr := cryptProtectData.Call(
		uintptr(unsafe.Pointer(&input)),
		0,
		uintptr(unsafe.Pointer(&entropy)),
		0,
		0,
		1,
		uintptr(unsafe.Pointer(&output)),
	)
	if result == 0 {
		return nil, callErr
	}
	return copyAndFreeWindowsBlob(output), nil
}

func windowsCryptUnprotect(protected []byte) ([]byte, error) {
	input := windowsBlob(protected)
	entropy := windowsBlob(windowsTokenEntropy)
	var output windowsDataBlob
	result, _, callErr := cryptUnprotectData.Call(
		uintptr(unsafe.Pointer(&input)),
		0,
		uintptr(unsafe.Pointer(&entropy)),
		0,
		0,
		1,
		uintptr(unsafe.Pointer(&output)),
	)
	if result == 0 {
		return nil, callErr
	}
	return copyAndFreeWindowsBlob(output), nil
}

func windowsBlob(data []byte) windowsDataBlob {
	if len(data) == 0 {
		return windowsDataBlob{}
	}
	return windowsDataBlob{size: uint32(len(data)), data: &data[0]}
}

func copyAndFreeWindowsBlob(blob windowsDataBlob) []byte {
	if blob.data == nil || blob.size == 0 {
		return nil
	}
	defer windowsLocalFree.Call(uintptr(unsafe.Pointer(blob.data)))
	return append([]byte(nil), unsafe.Slice(blob.data, int(blob.size))...)
}
