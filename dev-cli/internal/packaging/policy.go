package packaging

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	manifestmodel "github.com/yanXiaoi/playmesh/dev-cli/internal/manifest"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

var capabilityCodePattern = regexp.MustCompile(
	`^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+$`,
)

type packageManifestLayout struct {
	ID              string
	GameEntry       string
	ControllerEntry string
	AuthorityEntry  string
	Multiplayer     bool
	SingleScreen    bool
}

type ManifestLayout = packageManifestLayout

func LoadManifestLayout(
	packageRoot string,
	requireAppFiles bool,
) (ManifestLayout, []byte, error) {
	return loadPackageManifestLayout(packageRoot, requireAppFiles)
}

func loadPackageManifestLayout(
	packageRoot string,
	requireFiles bool,
) (packageManifestLayout, []byte, error) {
	path := filepath.Join(packageRoot, "main.json")
	info, statErr := os.Lstat(path)
	if statErr != nil {
		return packageManifestLayout{}, nil, errors.New(
			"当前项目缺少 main.json",
		)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return packageManifestLayout{}, nil, errors.New(
			"游戏包不允许符号链接: main.json",
		)
	}
	if !info.Mode().IsRegular() {
		return packageManifestLayout{}, nil, errors.New(
			"main.json 必须是普通文件",
		)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return packageManifestLayout{}, nil, errors.New(
			"当前项目缺少 main.json",
		)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return packageManifestLayout{}, nil, fmt.Errorf(
			"main.json 无效: %w",
			err,
		)
	}
	id, _ := manifest["id"].(string)
	if strings.TrimSpace(id) == "" {
		return packageManifestLayout{}, nil, errors.New(
			"main.json.id 不能为空",
		)
	}
	if err := requireManifestSDKVersion(
		manifest,
		"sdkVersion",
		sdk.RequiredGameVersion,
	); err != nil {
		return packageManifestLayout{}, nil, err
	}
	if err := requireManifestSDKVersion(
		manifest,
		"appSdkVersion",
		sdk.RequiredAppVersion,
	); err != nil {
		return packageManifestLayout{}, nil, err
	}
	multiplayer := stringListContains(manifest["modes"], "multiplayer")
	layout := packageManifestLayout{
		ID:          strings.TrimSpace(id),
		Multiplayer: multiplayer,
		SingleScreen: multiplayer && stringListContains(
			manifest["displayModes"],
			"single_screen_multiplayer",
		),
	}
	if rawEntries, exists := manifest["entries"]; exists {
		entries, ok := rawEntries.(map[string]any)
		if !ok {
			return packageManifestLayout{}, nil, errors.New(
				"main.json.entries 必须是对象",
			)
		}
		if raw, exists := entries["game"]; exists {
			layout.GameEntry, err = manifestEntryString(
				raw,
				"main.json.entries.game",
			)
			if err != nil {
				return packageManifestLayout{}, nil, err
			}
		}
		if raw, exists := entries["controller"]; exists && layout.SingleScreen {
			layout.ControllerEntry, err = manifestEntryString(
				raw,
				"main.json.entries.controller",
			)
			if err != nil {
				return packageManifestLayout{}, nil, err
			}
		}
		if !layout.SingleScreen {
			delete(entries, "controller")
			delete(manifest, "controllerOrientation")
		}
	}
	if layout.GameEntry == "" {
		return packageManifestLayout{}, nil, errors.New(
			"main.json 缺少 entries.game",
		)
	}
	if layout.SingleScreen && layout.ControllerEntry == "" {
		return packageManifestLayout{}, nil, errors.New(
			"single_screen_multiplayer 缺少 main.json.entries.controller",
		)
	}
	if rawAuthority, exists := manifest["authority"]; exists && layout.Multiplayer {
		authority, ok := rawAuthority.(map[string]any)
		if !ok {
			return packageManifestLayout{}, nil, errors.New(
				"main.json.authority 必须是对象",
			)
		}
		if raw, exists := authority["entry"]; exists {
			layout.AuthorityEntry, err = manifestEntryString(
				raw,
				"main.json.authority.entry",
			)
			if err != nil {
				return packageManifestLayout{}, nil, err
			}
		}
	}
	if !layout.Multiplayer {
		delete(manifest, "authority")
	}
	if layout.Multiplayer && layout.AuthorityEntry == "" {
		return packageManifestLayout{}, nil, errors.New(
			"多人游戏缺少 main.json.authority.entry",
		)
	}
	if err := validateHTMLManifestEntry(
		layout.GameEntry,
		"main.json.entries.game",
	); err != nil {
		return packageManifestLayout{}, nil, err
	}
	if layout.SingleScreen {
		if err := validateHTMLManifestEntry(
			layout.ControllerEntry,
			"main.json.entries.controller",
		); err != nil {
			return packageManifestLayout{}, nil, err
		}
	}
	if layout.Multiplayer {
		if err := validateJavaScriptManifestEntry(
			layout.AuthorityEntry,
			"main.json.authority.entry",
		); err != nil {
			return packageManifestLayout{}, nil, err
		}
	}
	if requireFiles {
		requiredEntries := map[string]string{
			"main.json.entries.game": layout.GameEntry,
		}
		if layout.SingleScreen {
			requiredEntries["main.json.entries.controller"] =
				layout.ControllerEntry
		}
		if layout.Multiplayer {
			requiredEntries["main.json.authority.entry"] =
				layout.AuthorityEntry
		}
		for field, entry := range requiredEntries {
			entryPath := webpath.WebEntryPath(entry)
			target := filepath.Join(
				packageRoot,
				"app",
				filepath.FromSlash(entryPath),
			)
			if err := webpath.RejectSymlinkPath(
				filepath.Join(packageRoot, "app"),
				target,
			); err != nil {
				return packageManifestLayout{}, nil, err
			}
			info, statErr := os.Stat(target)
			if statErr != nil || !info.Mode().IsRegular() {
				return packageManifestLayout{}, nil, fmt.Errorf(
					"%s 指向的文件不存在: app/%s",
					field,
					entryPath,
				)
			}
		}
	}
	projected, err := json.MarshalIndent(
		manifestmodel.Project(manifest),
		"",
		"  ",
	)
	if err != nil {
		return packageManifestLayout{}, nil, err
	}
	return layout, append(projected, '\n'), nil
}

func requireManifestSDKVersion(
	manifest map[string]any,
	field string,
	required string,
) error {
	value, ok := manifest[field].(string)
	if !ok || value != required {
		return fmt.Errorf(
			"main.json.%s 必须显式声明为 %s",
			field,
			required,
		)
	}
	return nil
}

func manifestEntryString(value any, field string) (string, error) {
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s 必须是字符串", field)
	}
	if text != strings.TrimSpace(text) {
		return "", fmt.Errorf("%s 不得包含首尾空白", field)
	}
	if text == "" {
		return "", fmt.Errorf("%s 不能为空", field)
	}
	return text, nil
}

func validateHTMLManifestEntry(value, field string) error {
	if err := webpath.ValidateWebEntryURL(value, field); err != nil {
		return err
	}
	if !strings.HasSuffix(
		strings.ToLower(webpath.WebEntryPath(value)),
		".html",
	) {
		return fmt.Errorf("%s 必须指向 HTML 文件", field)
	}
	return nil
}

func validateJavaScriptManifestEntry(value, field string) error {
	if err := webpath.ValidateWebEntry(value, field); err != nil {
		return err
	}
	lower := strings.ToLower(webpath.WebEntryPath(value))
	if !strings.HasSuffix(lower, ".js") &&
		!strings.HasSuffix(lower, ".mjs") {
		return fmt.Errorf("%s 必须指向 JavaScript 文件", field)
	}
	return nil
}

func stringListContains(value any, expected string) bool {
	items, ok := value.([]any)
	if !ok {
		return false
	}
	for _, item := range items {
		if text, ok := item.(string); ok && text == expected {
			return true
		}
	}
	return false
}

func validatePackageAppTree(appRoot string) error {
	return filepath.WalkDir(
		appRoot,
		func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			relative, err := filepath.Rel(appRoot, path)
			if err != nil {
				return err
			}
			if relative == "." {
				return nil
			}
			if entry.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("游戏包不允许符号链接: %s", path)
			}
			relativeURL := filepath.ToSlash(relative)
			if strings.Contains(relativeURL, "\\") {
				return fmt.Errorf(
					"游戏包路径不能包含反斜杠: %s",
					relative,
				)
			}
			segments := strings.Split(
				relativeURL,
				"/",
			)
			if len(segments) != 0 &&
				webpath.IsReservedWebRootSegment(segments[0]) {
				return fmt.Errorf(
					"app/ 一级目录 %q 是 Playmesh 平台保留命名空间",
					segments[0],
				)
			}
			if !entry.IsDir() && !entry.Type().IsRegular() {
				return fmt.Errorf(
					"游戏包只允许普通文件和目录: %s",
					path,
				)
			}
			return nil
		},
	)
}

func BuildDevelopmentBase(
	packageRoot string,
	gameEntryOverride string,
) ([]byte, string, error) {
	layout, manifest, err := loadPackageManifestLayout(packageRoot, false)
	if err != nil {
		return nil, "", err
	}
	if strings.TrimSpace(gameEntryOverride) != "" {
		gameEntryOverride = strings.TrimSpace(gameEntryOverride)
		if err := validateHTMLManifestEntry(
			gameEntryOverride,
			"临时 main.json.entries.game",
		); err != nil {
			return nil, "", err
		}
		var temporaryManifest map[string]any
		if err := json.Unmarshal(manifest, &temporaryManifest); err != nil {
			return nil, "", fmt.Errorf("main.json 无效: %w", err)
		}
		entries, _ := temporaryManifest["entries"].(map[string]any)
		if entries == nil {
			entries = map[string]any{}
			temporaryManifest["entries"] = entries
		}
		entries["game"] = gameEntryOverride
		manifest, err = json.MarshalIndent(
			manifestmodel.Project(temporaryManifest),
			"",
			"  ",
		)
		if err != nil {
			return nil, "", err
		}
		manifest = append(manifest, '\n')
		layout.GameEntry = gameEntryOverride
	}
	capabilities, hasCapabilities, err := loadOptionalCapabilities(
		packageRoot,
		layout.SingleScreen,
	)
	if err != nil {
		return nil, "", err
	}
	files := map[string][]byte{
		"main.json": manifest,
		"app/" + webpath.WebEntryPath(layout.GameEntry): []byte(
			"<!doctype html><meta charset=\"utf-8\"><title>Playmesh development</title>\n",
		),
	}
	if hasCapabilities {
		files["capabilities.json"] = capabilities
	}
	if layout.SingleScreen {
		files["app/"+webpath.WebEntryPath(layout.ControllerEntry)] = []byte(
			"<!doctype html><meta charset=\"utf-8\"><title>Playmesh controller development</title>\n",
		)
	}
	if layout.Multiplayer {
		files["app/"+webpath.WebEntryPath(layout.AuthorityEntry)] = []byte(
			"// Playmesh 开发态 Authority 占位脚本。\n",
		)
	}
	iconPath := filepath.Join(packageRoot, RootIconName)
	if info, statErr := os.Lstat(iconPath); statErr == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, "", errors.New("游戏包不允许符号链接: icon.png")
		}
		if info.Mode().IsRegular() && info.Size() <= maxRootIconBytes {
			icon, readErr := os.ReadFile(iconPath)
			if readErr != nil {
				return nil, "", readErr
			}
			if isSafeRootIcon(icon) {
				files[RootIconName] = icon
			}
		}
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return nil, "", statErr
	}
	packageBytes, err := zipFileMap(files)
	return packageBytes, layout.ID, err
}

func loadOptionalCapabilities(
	packageRoot string,
	allowControllerCapabilities bool,
) ([]byte, bool, error) {
	path := filepath.Join(packageRoot, "capabilities.json")
	info, statErr := os.Lstat(path)
	if errors.Is(statErr, os.ErrNotExist) {
		return nil, false, nil
	}
	if statErr != nil {
		return nil, false, statErr
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return nil, false, errors.New(
			"游戏包不允许符号链接: capabilities.json",
		)
	}
	if !info.Mode().IsRegular() {
		return nil, false, errors.New(
			"capabilities.json 必须是普通文件",
		)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, false, err
	}
	var capabilities map[string]any
	if err := json.Unmarshal(content, &capabilities); err != nil {
		return nil, false, fmt.Errorf("capabilities.json 无效: %w", err)
	}
	if capabilities == nil {
		return nil, false, errors.New(
			"capabilities.json 根节点必须是对象",
		)
	}
	for key, value := range capabilities {
		if key != "required" && key != "controllerRequired" {
			return nil, false, fmt.Errorf(
				"capabilities.json 包含未知字段: %s",
				key,
			)
		}
		items, ok := value.([]any)
		if !ok {
			return nil, false, fmt.Errorf(
				"capabilities.json.%s 必须是数组",
				key,
			)
		}
		seen := make(map[string]struct{}, len(items))
		for _, item := range items {
			code, ok := item.(string)
			if !ok || !capabilityCodePattern.MatchString(code) {
				return nil, false, fmt.Errorf(
					"capabilities.json.%s 包含无效能力代码",
					key,
				)
			}
			if _, exists := seen[code]; exists {
				return nil, false, fmt.Errorf(
					"capabilities.json.%s 包含重复值: %s",
					key,
					code,
				)
			}
			seen[code] = struct{}{}
		}
		if key == "controllerRequired" && len(items) != 0 &&
			!allowControllerCapabilities {
			return nil, false, errors.New(
				"非单屏多人游戏不能声明 capabilities.json.controllerRequired",
			)
		}
	}
	return content, true, nil
}

func zipFileMap(files map[string][]byte) ([]byte, error) {
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, name := range names {
		entry, err := writer.Create(name)
		if err != nil {
			_ = writer.Close()
			return nil, err
		}
		if _, err := entry.Write(files[name]); err != nil {
			_ = writer.Close()
			return nil, err
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}
