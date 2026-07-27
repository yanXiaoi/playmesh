package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

var (
	gameSDKVersionPattern = regexp.MustCompile(`const\s+PLAYMESH_SDK_VERSION\s*=\s*["'](\d+\.\d+\.\d+)["']`)
	appSDKVersionPattern  = regexp.MustCompile(`const\s+PLAYMESH_APP_SDK_VERSION\s*=\s*["'](\d+\.\d+\.\d+)["']`)
)

type sdkBundle struct {
	GameSDKVersion string            `json:"gameSdkVersion"`
	AppSDKVersion  string            `json:"appSdkVersion"`
	Encoding       string            `json:"encoding"`
	Files          map[string]string `json:"files"`
}

type sdkVersions struct {
	Game string
	App  string
}

func fetchSDK(ctx context.Context, client *apiClient) (sdkBundle, error) {
	var bundle sdkBundle
	if err := client.json(ctx, "GET", "/dev/api/sdk", nil, &bundle); err != nil {
		return sdkBundle{}, err
	}
	if bundle.Encoding != "base64" {
		return sdkBundle{}, errors.New("目标 App 返回了不支持的 SDK 编码")
	}
	return bundle, nil
}

func installSDK(projectRoot string, bundle sdkBundle) (sdkVersions, error) {
	required := []string{"playmesh.js", "playmesh-app.js", "playmesh.d.ts", "playmesh-app.d.ts"}
	decoded := make(map[string][]byte, len(required))
	for _, name := range required {
		value, ok := bundle.Files[name]
		if !ok {
			return sdkVersions{}, fmt.Errorf("目标 App SDK 缺少 %s", name)
		}
		data, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return sdkVersions{}, fmt.Errorf("解码 %s: %w", name, err)
		}
		decoded[name] = data
	}
	versions, err := versionsFromSDKBytes(decoded["playmesh.js"], decoded["playmesh-app.js"])
	if err != nil {
		return sdkVersions{}, err
	}
	if versions.Game != bundle.GameSDKVersion || versions.App != bundle.AppSDKVersion {
		return sdkVersions{}, errors.New("目标 App SDK 文件版本与接口声明不一致")
	}
	parent := filepath.Join(projectRoot, "playmesh")
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return sdkVersions{}, err
	}
	temporary, err := os.MkdirTemp(parent, "sdk-new-")
	if err != nil {
		return sdkVersions{}, err
	}
	defer os.RemoveAll(temporary)
	for _, name := range required {
		if err := os.WriteFile(filepath.Join(temporary, name), decoded[name], 0o644); err != nil {
			return sdkVersions{}, err
		}
	}
	if err := replaceDirectory(temporary, filepath.Join(parent, "sdk")); err != nil {
		return sdkVersions{}, err
	}
	return versions, nil
}

func versionsFromSDK(projectRoot string) (sdkVersions, error) {
	game, err := os.ReadFile(filepath.Join(projectRoot, "playmesh", "sdk", "playmesh.js"))
	if err != nil {
		return sdkVersions{}, errors.New("当前项目缺少 playmesh/sdk/playmesh.js，请执行 playmesh-cli sdk")
	}
	app, err := os.ReadFile(filepath.Join(projectRoot, "playmesh", "sdk", "playmesh-app.js"))
	if err != nil {
		return sdkVersions{}, errors.New("当前项目缺少 playmesh/sdk/playmesh-app.js，请执行 playmesh-cli sdk")
	}
	return versionsFromSDKBytes(game, app)
}

func versionsFromSDKBytes(game, app []byte) (sdkVersions, error) {
	gameMatch := gameSDKVersionPattern.FindSubmatch(game)
	appMatch := appSDKVersionPattern.FindSubmatch(app)
	if len(gameMatch) != 2 || len(appMatch) != 2 {
		return sdkVersions{}, errors.New("无法从当前项目 SDK 文件读取版本")
	}
	return sdkVersions{Game: string(gameMatch[1]), App: string(appMatch[1])}, nil
}

func updateManifestSDKVersions(projectRoot string, versions sdkVersions) (string, error) {
	path := filepath.Join(projectRoot, "main.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("当前目录缺少 main.json")
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", fmt.Errorf("main.json 无效: %w", err)
	}
	projectID, _ := manifest["id"].(string)
	if projectID == "" {
		return "", errors.New("main.json.id 不能为空")
	}
	manifest = projectManifest(manifest)
	manifest["sdkVersion"] = versions.Game
	manifest["appSdkVersion"] = versions.App
	encoded, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	encoded = append(encoded, '\n')
	temporary := path + ".playmesh-tmp"
	if err := os.WriteFile(temporary, encoded, 0o644); err != nil {
		return "", err
	}
	if err := replaceFile(temporary, path); err != nil {
		return "", err
	}
	return projectID, nil
}
