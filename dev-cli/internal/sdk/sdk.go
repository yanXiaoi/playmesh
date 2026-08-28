package sdk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	manifestmodel "github.com/yanXiaoi/playmesh/dev-cli/internal/manifest"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/target"
)

var (
	gameSDKVersionPattern = regexp.MustCompile(`const\s+PLAYMESH_SDK_VERSION\s*=\s*["']([^"']+)["']`)
	appSDKVersionPattern  = regexp.MustCompile(`const\s+PLAYMESH_APP_SDK_VERSION\s*=\s*["']([^"']+)["']`)
)

type Bundle struct {
	GameSDKVersion string            `json:"gameSdkVersion"`
	AppSDKVersion  string            `json:"appSdkVersion"`
	Encoding       string            `json:"encoding"`
	Files          map[string]string `json:"files"`
}

type Versions struct {
	Game string
	App  string
}

func Fetch(ctx context.Context, client *target.Client) (Bundle, error) {
	var bundle Bundle
	if err := client.JSON(ctx, "GET", "/dev/api/sdk", nil, &bundle); err != nil {
		return Bundle{}, err
	}
	if bundle.Encoding != "base64" {
		return Bundle{}, errors.New("目标 App 返回了不支持的 SDK 编码")
	}
	return bundle, nil
}

func Install(projectRoot string, bundle Bundle) (Versions, error) {
	return InstallAt(filepath.Join(projectRoot, "playmesh", "sdk"), bundle)
}

func InstallAt(sdkRoot string, bundle Bundle) (Versions, error) {
	required := []string{
		"playmesh-main.js",
		"playmesh-app.js",
		"playmesh-main.d.ts",
		"playmesh-app.d.ts",
	}
	decoded := make(map[string][]byte, len(required))
	for _, name := range required {
		value, ok := bundle.Files[name]
		if !ok {
			return Versions{}, fmt.Errorf("目标 App SDK 缺少 %s", name)
		}
		data, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return Versions{}, fmt.Errorf("解码 %s: %w", name, err)
		}
		decoded[name] = data
	}
	versions, err := VersionsFromBytes(
		decoded["playmesh-main.js"],
		decoded["playmesh-app.js"],
	)
	if err != nil {
		return Versions{}, err
	}
	parent := filepath.Dir(sdkRoot)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return Versions{}, err
	}
	temporary, err := os.MkdirTemp(parent, "sdk-new-")
	if err != nil {
		return Versions{}, err
	}
	defer os.RemoveAll(temporary)
	for _, name := range required {
		if err := os.WriteFile(filepath.Join(temporary, name), decoded[name], 0o644); err != nil {
			return Versions{}, err
		}
	}
	if err := fsutil.ReplaceDirectory(temporary, sdkRoot); err != nil {
		return Versions{}, err
	}
	return versions, nil
}

func VersionsFromProject(projectRoot string) (Versions, error) {
	return VersionsAt(filepath.Join(projectRoot, "playmesh", "sdk"))
}

func VersionsAt(sdkRoot string) (Versions, error) {
	game, err := os.ReadFile(filepath.Join(sdkRoot, "playmesh-main.js"))
	if err != nil {
		return Versions{}, errors.New("当前项目缺少 Game SDK，请在已初始化项目中执行 playmesh-cli update")
	}
	app, err := os.ReadFile(filepath.Join(sdkRoot, "playmesh-app.js"))
	if err != nil {
		return Versions{}, errors.New("当前项目缺少 App SDK，请执行 playmesh-cli update")
	}
	versions, err := VersionsFromBytes(game, app)
	if err != nil {
		return Versions{}, err
	}
	return versions, nil
}

func VersionsFromBytes(game, app []byte) (Versions, error) {
	gameMatch := gameSDKVersionPattern.FindSubmatch(game)
	appMatch := appSDKVersionPattern.FindSubmatch(app)
	if len(gameMatch) != 2 || len(appMatch) != 2 {
		return Versions{}, errors.New("无法从当前项目 SDK 文件读取版本")
	}
	return Versions{Game: string(gameMatch[1]), App: string(appMatch[1])}, nil
}

func UpdateManifestVersions(projectRoot string, versions Versions) (string, error) {
	path := filepath.Join(projectRoot, "main.json")
	info, statErr := os.Lstat(path)
	if statErr != nil {
		return "", errors.New("当前目录缺少 main.json")
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", errors.New("main.json 必须是非符号链接的普通文件")
	}
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
	projected := manifestmodel.Project(manifest)
	projected["sdkVersion"] = versions.Game
	projected["appSdkVersion"] = versions.App
	encoded, err := json.MarshalIndent(projected, "", "  ")
	if err != nil {
		return "", err
	}
	encoded = append(encoded, '\n')
	temporary := path + ".playmesh-tmp"
	if err := os.WriteFile(temporary, encoded, 0o644); err != nil {
		return "", err
	}
	if err := fsutil.ReplaceFile(temporary, path); err != nil {
		return "", err
	}
	return projectID, nil
}
