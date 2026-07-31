package cocos

import (
	"bytes"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	manifestmodel "github.com/yanXiaoi/playmesh/dev-cli/internal/manifest"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/scaffold"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

//go:embed all:extension all:preview-template
var cocosExtensionFiles embed.FS

const (
	playmeshPreviewGateStart     = "<!-- playmesh:auto-preview:start -->"
	playmeshPreviewGateEnd       = "<!-- playmesh:auto-preview:end -->"
	playmeshPreviewRuntimeIgnore = "/preview-template/playmesh-preview-runtime.json"
	playmeshPreviewGateTag       = playmeshPreviewGateStart + "\n" +
		`<script src="/playmesh-preview-gate.js"></script>` + "\n" +
		playmeshPreviewGateEnd + "\n"
)

const legacyGeneratedPreviewTemplate = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <!-- playmesh:auto-preview:start -->
  <script src="/playmesh-preview-gate.js"></script>
  <!-- playmesh:auto-preview:end -->
</head>
<body>
  <%- include(cocosTemplate, {}) %>
</body>
</html>`

const playmeshCLIProjectSchema = `{
  "title": "Playmesh CLI project configuration",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "packageRoot", "sdkRoot", "integration"],
  "properties": {
    "$schema": { "type": "string" },
    "schemaVersion": { "const": 1 },
    "packageRoot": { "const": "playmesh/package" },
    "sdkRoot": { "const": "playmesh/sdk" },
    "integration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "type",
        "projectRoot",
        "platform",
        "outputDirectory",
        "entry",
        "autoRunAfterBuild"
      ],
      "properties": {
        "type": { "const": "cocos" },
        "projectRoot": { "type": "string", "minLength": 1 },
        "platform": { "enum": ["web-mobile", "web-desktop"] },
        "outputDirectory": { "type": "string", "minLength": 1 },
        "entry": { "type": "string", "minLength": 1 },
        "autoRunAfterBuild": { "type": "boolean" },
        "previewBridgePort": {
          "type": "integer",
          "minimum": 0,
          "maximum": 65535,
          "description": "0 或省略时由系统自动分配；1-65535 时固定使用该端口。"
        }
      }
    }
  }
}
`

const ProjectSchema = playmeshCLIProjectSchema

type Cocos struct{}

type previewPageSource struct {
	mapping development.Mapping
}

type previewPageMapping struct {
	pageURL      *url.URL
	entry        string
	rootFallback *development.HTTPMapping
	reloadNotice sync.Once
}

func newPreviewPageSource(pageURL *url.URL) (development.Source, error) {
	if pageURL == nil ||
		(pageURL.Scheme != "http" && pageURL.Scheme != "https") ||
		pageURL.Host == "" ||
		pageURL.User != nil {
		return nil, errors.New("Cocos 预览页面地址必须是有效的 HTTP URL")
	}
	page := *pageURL
	page.Fragment = ""
	if page.Path == "" {
		page.Path = "/"
	}
	entry, err := cocosPreviewDevelopmentEntry(&page)
	if err != nil {
		return nil, err
	}
	rootURL := &url.URL{Scheme: page.Scheme, Host: page.Host}
	rootFallback, err := development.NewHTTPMapping(rootURL, nil)
	if err != nil {
		return nil, err
	}
	return previewPageSource{
		mapping: &previewPageMapping{
			pageURL:      &page,
			entry:        entry,
			rootFallback: rootFallback,
		},
	}, nil
}

func cocosPreviewDevelopmentEntry(pageURL *url.URL) (string, error) {
	decoded, err := url.PathUnescape(pageURL.EscapedPath())
	if err != nil || strings.Contains(decoded, "\\") {
		return "", errors.New("Cocos 预览页面路径无效")
	}
	entry := strings.TrimPrefix(decoded, "/")
	switch {
	case entry == "":
		entry = "index.html"
	case strings.HasSuffix(entry, "/"):
		entry += "index.html"
	case !strings.HasSuffix(strings.ToLower(entry), ".html"):
		// main.json 的 Web 入口必须是 HTML 文件。对无扩展名路由
		// 只增加一个开发态别名，并在 MapRequest 中映回完整预览 URL。
		entry += ".html"
	}
	if pageURL.RawQuery != "" || pageURL.ForceQuery {
		entry += "?" + pageURL.RawQuery
	}
	if err := webpath.ValidateWebEntryURL(
		entry,
		"Cocos 临时开发入口",
	); err != nil {
		return "", err
	}
	return entry, nil
}

func (source previewPageSource) Start(
	ctx context.Context,
) (development.Mapping, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return source.mapping, nil
}

func (previewPageSource) Stop(context.Context) error {
	return nil
}

func (mapping *previewPageMapping) SourceURI() *url.URL {
	return mapping.rootFallback.SourceURI()
}

func (mapping *previewPageMapping) DevelopmentGameEntry() string {
	return mapping.entry
}

func (mapping *previewPageMapping) MapRequest(
	requestURL *url.URL,
) (*url.URL, error) {
	mapped, err := mapping.rootFallback.MapRequest(requestURL)
	if err != nil {
		return nil, err
	}
	requestPath := strings.TrimPrefix(requestURL.Path, "/")
	if requestPath == webpath.WebEntryPath(mapping.entry) {
		page := *mapping.pageURL
		page.RawQuery = requestURL.RawQuery
		page.ForceQuery = requestURL.ForceQuery
		return &page, nil
	}
	return mapped, nil
}

func (mapping *previewPageMapping) RequestHeaders() http.Header {
	return mapping.rootFallback.RequestHeaders()
}

func (mapping *previewPageMapping) MapResponse(response *http.Response) error {
	if response != nil &&
		response.Request != nil &&
		response.Request.URL != nil &&
		response.StatusCode >= http.StatusOK &&
		response.StatusCode < http.StatusMultipleChoices &&
		strings.HasSuffix(
			strings.ToLower(response.Request.URL.Path),
			".js",
		) {
		// Cocos Creator 3.8 的 settings.js、assets/*/index.js 等动态脚本
		// 会错误声明为 text/html，WebView 会据此拒绝脚本；适配器只根据
		// 请求扩展名修正 MIME，不读取或改写响应体。
		response.Header.Set(
			"Content-Type",
			"application/javascript; charset=utf-8",
		)
	}
	if response != nil &&
		response.Request != nil &&
		response.Request.URL != nil &&
		response.StatusCode >= http.StatusOK &&
		response.StatusCode < http.StatusMultipleChoices &&
		strings.HasSuffix(
			strings.ToLower(response.Request.URL.Path),
			"/preview-app/index.js",
		) {
		if err := rewriteCocosPreviewReload(response); err != nil {
			return err
		}
		mapping.reloadNotice.Do(func() {
			fmt.Println(
				"[dev Cocos] 已接管 App 内的 Cocos 热刷新：资源稳定后再刷新游戏页面。",
			)
		})
	}
	return nil
}

func rewriteCocosPreviewReload(response *http.Response) error {
	if response.Body == nil {
		return errors.New("Cocos preview-app/index.js 响应体为空")
	}
	content, err := io.ReadAll(response.Body)
	closeErr := response.Body.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	for _, event := range []string{"reload", "disconnect"} {
		pattern := regexp.MustCompile(
			`(\.on\((?:"browser:` + event +
				`"|'browser:` + event +
				`'),function\(\)\{)window\.location\.reload\(\)(\}\))`,
		)
		if !pattern.Match(content) {
			return fmt.Errorf(
				"Cocos preview-app/index.js 未包含可识别的 browser:%s 处理器；请更新 Cocos 适配器",
				event,
			)
		}
		replacement := []byte(
			`${1}globalThis.__playmeshCocosReload?` +
				`globalThis.__playmeshCocosReload("` + event + `"):` +
				`window.location.reload()${2}`,
		)
		content = pattern.ReplaceAll(content, replacement)
	}
	response.Body = io.NopCloser(bytes.NewReader(content))
	response.ContentLength = int64(len(content))
	response.Header.Set("Content-Length", fmt.Sprintf("%d", len(content)))
	response.Header.Del("ETag")
	return nil
}

func (Cocos) ID() string {
	return "cocos"
}

func (Cocos) Detect(root string) error {
	return validateCocosProject(root)
}

func (Cocos) Defaults(root string) (scaffold.Defaults, error) {
	name := filepath.Base(root)
	for _, descriptor := range []string{"package.json", "project.json"} {
		data, err := os.ReadFile(filepath.Join(root, descriptor))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return scaffold.Defaults{}, err
		}
		var value struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(data, &value) == nil && strings.TrimSpace(value.Name) != "" {
			name = strings.TrimSpace(value.Name)
			break
		}
	}
	orientation := "landscape"
	projectOrientation, found, err := cocosProjectOrientation(
		root,
		"web-mobile",
	)
	if err != nil {
		return scaffold.Defaults{}, err
	}
	if found {
		orientation = projectOrientation
	}
	return scaffold.Defaults{
		Name:                  name,
		Version:               "0.1.0",
		Description:           "Cocos Creator game",
		Mode:                  "solo",
		Orientation:           orientation,
		DisplayMode:           "multi_screen",
		ControllerOrientation: "portrait",
		ControllerEntry:       "controller/index.html",
		AuthorityEntry:        "static/js/service/index.js",
		MinPlayers:            2,
		MaxPlayers:            5,
		Tags:                  "cocos",
	}, nil
}

func (Cocos) Configuration(root string) (project.Config, error) {
	config := project.Config{
		Schema:        "./playmesh/playmesh-cli.schema.json",
		SchemaVersion: 1,
		PackageRoot:   "playmesh/package",
		SDKRoot:       "playmesh/sdk",
		Integration: &project.IntegrationConfig{
			Type:              "cocos",
			ProjectRoot:       ".",
			Platform:          "web-mobile",
			OutputDirectory:   ".",
			Entry:             "index.html",
			AutoRunAfterBuild: true,
		},
	}
	context, err := project.FromConfig(
		filepath.Clean(root),
		filepath.Join(root, project.ConfigName),
		&config,
	)
	if err != nil {
		return project.Config{}, err
	}
	if err := validateCocosIntegration(context); err != nil {
		return project.Config{}, err
	}
	return config, nil
}

func (Cocos) ProjectManifestPath(
	value project.Context,
) (string, error) {
	return filepath.Join(value.PackageRoot, "main.json"), nil
}

func (Cocos) Finalize(value project.Context) error {
	if err := (Cocos{}).Update(value); err != nil {
		return err
	}
	fmt.Println("Web 构建完成后扩展会自动上传并运行到目标 App。")
	fmt.Println("首次使用请在 Cocos 扩展管理器中刷新并在已安装扩展中启用 Playmesh 扩展。")
	return nil
}

func (Cocos) Update(value project.Context) error {
	if err := validateCocosIntegration(value); err != nil {
		return err
	}
	if err := validateCocosProject(value.ProjectRoot); err != nil {
		return err
	}
	if err := configureCocosManifest(value); err != nil {
		return err
	}
	schemaPath := filepath.Join(value.WorkspaceRoot, "playmesh", "playmesh-cli.schema.json")
	if err := fsutil.WriteAtomicFile(schemaPath, []byte(playmeshCLIProjectSchema), 0o644); err != nil {
		return err
	}
	if err := installCocosTypeReference(value); err != nil {
		return err
	}
	if err := installCocosPreviewTemplate(value.WorkspaceRoot); err != nil {
		return err
	}
	// Install the preview files before exposing the extension to Creator.
	// Creator may load a newly discovered project extension immediately; in
	// that case its dynamically allocated bridge port must be written after
	// the preview directory is ready.
	if err := installCocosExtension(value.WorkspaceRoot); err != nil {
		return err
	}
	fmt.Println("Cocos Creator 项目已接入 Playmesh。")
	return nil
}

func (Cocos) PrepareDevelopment(
	ctx context.Context,
	value project.Context,
	args []string,
) (development.Source, error) {
	if err := validateCocosIntegration(value); err != nil {
		return nil, err
	}
	if err := validateCocosProject(value.ProjectRoot); err != nil {
		return nil, err
	}
	if len(args) != 1 {
		return nil, errors.New(
			"用法：playmesh-cli dev <cocos-preview-url>",
		)
	}
	raw := strings.TrimSpace(args[0])
	if raw == "" {
		return nil, errors.New("Cocos 预览服务器地址不能为空")
	}
	baseURL, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("Cocos 预览服务器地址无效: %w", err)
	}
	// dev may be launched by an older generated gate before the user has run
	// `playmesh-cli update`. Refresh the local preview integration here so the
	// App's following request receives the current complete Cocos template.
	if err := installCocosPreviewTemplate(value.WorkspaceRoot); err != nil {
		return nil, fmt.Errorf("刷新 Cocos 预览模板失败: %w", err)
	}
	return newPreviewPageSource(baseURL)
}

func (Cocos) PrepareRelease(
	ctx context.Context,
	value project.Context,
) error {
	if err := validateCocosIntegration(value); err != nil {
		return err
	}
	if err := validateCocosProject(value.ProjectRoot); err != nil {
		return err
	}
	entry := filepath.Join(
		value.AppRoot,
		filepath.FromSlash(value.Config.Integration.Entry),
	)
	if err := webpath.RejectSymlinkPath(value.AppRoot, entry); err != nil {
		return err
	}
	info, err := os.Stat(entry)
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf(
			"Cocos 正式构建结果缺少入口 %s；请先完成 Web 构建",
			value.Config.Integration.Entry,
		)
	}
	return nil
}

func (Cocos) PrepareUpload(
	ctx context.Context,
	value project.Context,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := validateCocosIntegration(value); err != nil {
		return err
	}
	return configureCocosManifest(value)
}

func validateCocosProject(root string) error {
	for _, directory := range []string{"assets", "settings"} {
		info, err := os.Stat(filepath.Join(root, directory))
		if err != nil || !info.IsDir() {
			return fmt.Errorf("当前目录不是 Cocos Creator 3.x 项目：缺少 %s/", directory)
		}
	}
	hasDescriptor := false
	versions := make([]string, 0, 2)
	for _, name := range []string{"project.json", "package.json"} {
		path := filepath.Join(root, name)
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			hasDescriptor = true
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			if candidate := cocosDescriptorVersion(name, data); candidate != "" {
				versions = append(versions, candidate)
			}
		}
	}
	if !hasDescriptor {
		return errors.New("当前目录不是 Cocos Creator 3.x 项目：缺少 project.json 或 package.json")
	}
	if len(versions) == 0 {
		return errors.New(
			"当前目录不是可识别的 Cocos Creator 3.x 项目：描述文件缺少引擎版本",
		)
	}
	versionPattern := regexp.MustCompile(`^[vV]?([0-9]+)\.`)
	for _, version := range versions {
		match := versionPattern.FindStringSubmatch(version)
		if len(match) == 2 && match[1] == "3" {
			return nil
		}
	}
	return fmt.Errorf(
		"当前项目使用 Cocos Creator %s；Playmesh 只支持 Cocos Creator 3.x",
		strings.Join(versions, " / "),
	)
}

func validateCocosIntegration(project project.Context) error {
	integration := project.Config.Integration
	if integration == nil || integration.Type != "cocos" {
		return errors.New("当前配置不是 Cocos 项目")
	}
	if integration.Platform != "web-mobile" && integration.Platform != "web-desktop" {
		return errors.New("Cocos integration.platform 只支持 web-mobile 或 web-desktop")
	}
	if integration.PreviewBridgePort < 0 || integration.PreviewBridgePort > 65535 {
		return errors.New("Cocos integration.previewBridgePort 必须是 0 或 1-65535 的整数")
	}
	if _, err := webpath.ResolveAppOutputDirectory(
		project.AppRoot,
		integration.OutputDirectory,
	); err != nil {
		return err
	}
	if err := webpath.ValidateWebEntry(
		integration.Entry,
		"playmesh-cli.json.integration.entry",
	); err != nil {
		return err
	}
	expectedEntry := "index.html"
	if integration.OutputDirectory != "." {
		expectedEntry = strings.TrimSuffix(
			integration.OutputDirectory,
			"/",
		) + "/index.html"
	}
	if integration.Entry != expectedEntry {
		return fmt.Errorf("Cocos integration.entry 必须是 %s", expectedEntry)
	}
	return nil
}

func cocosDescriptorVersion(name string, data []byte) string {
	var descriptor map[string]any
	if json.Unmarshal(data, &descriptor) != nil {
		return ""
	}
	for _, path := range [][]string{
		{"creator", "version"},
		{"editor", "version"},
		{"engine", "version"},
		{"creatorVersion"},
		{"engineVersion"},
	} {
		var value any = descriptor
		for _, segment := range path {
			object, ok := value.(map[string]any)
			if !ok {
				value = nil
				break
			}
			value = object[segment]
		}
		if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	if name == "project.json" {
		if version, ok := descriptor["version"].(string); ok {
			return strings.TrimSpace(version)
		}
	}
	return ""
}

func configureCocosManifest(project project.Context) error {
	path := filepath.Join(project.PackageRoot, "main.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("main.json 无效: %w", err)
	}
	orientation, found, err := cocosProjectOrientation(
		project.ProjectRoot,
		project.Config.Integration.Platform,
	)
	if err != nil {
		return err
	}
	if !found {
		existing, _ := manifest["orientation"].(string)
		orientation = strings.TrimSpace(existing)
	}
	applyCocosManifest(
		manifest,
		filepath.ToSlash(project.Config.Integration.Entry),
		orientation,
	)
	encoded, err := json.MarshalIndent(manifestmodel.Project(manifest), "", "  ")
	if err != nil {
		return err
	}
	return fsutil.WriteAtomicFile(path, append(encoded, '\n'), 0o644)
}

func applyCocosManifest(
	manifest map[string]any,
	gameEntry string,
	orientation string,
) {
	entries, _ := manifest["entries"].(map[string]any)
	if entries == nil {
		entries = map[string]any{}
	}
	entries["game"] = gameEntry
	if orientation != "" {
		manifest["orientation"] = orientation
	}
	if !stringListContains(
		manifest["displayModes"],
		"single_screen_multiplayer",
	) {
		delete(entries, "controller")
		delete(manifest, "controllerOrientation")
	}
	manifest["entries"] = entries
}

func cocosProjectOrientation(
	root string,
	platform string,
) (string, bool, error) {
	profileOrientation, found, err := cocosBuildProfileOrientation(
		root,
		platform,
	)
	if err != nil {
		return "", false, err
	}
	if found && profileOrientation != "auto" {
		return profileOrientation, true, nil
	}
	for _, relative := range []string{
		"settings/v2/packages/project.json",
		"settings/v1/packages/project.json",
		"settings/packages/project.json",
	} {
		path := filepath.Join(root, filepath.FromSlash(relative))
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", false, err
		}
		var settings struct {
			General struct {
				DesignResolution struct {
					Width  float64 `json:"width"`
					Height float64 `json:"height"`
				} `json:"designResolution"`
			} `json:"general"`
		}
		if err := json.Unmarshal(data, &settings); err != nil {
			return "", false, fmt.Errorf(
				"Cocos 项目设置 %s 无效: %w",
				relative,
				err,
			)
		}
		width := settings.General.DesignResolution.Width
		height := settings.General.DesignResolution.Height
		if width <= 0 || height <= 0 || width == height {
			return "", false, nil
		}
		if width > height {
			return "landscape", true, nil
		}
		return "portrait", true, nil
	}
	return "", false, nil
}

func cocosBuildProfileOrientation(
	root string,
	platform string,
) (string, bool, error) {
	for _, version := range []string{"v2", "v1"} {
		relative := filepath.ToSlash(filepath.Join(
			"profiles",
			version,
			"packages",
			platform+".json",
		))
		data, err := os.ReadFile(
			filepath.Join(root, filepath.FromSlash(relative)),
		)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return "", false, err
		}
		var profile struct {
			Builder struct {
				Common struct {
					Orientation string `json:"orientation"`
				} `json:"common"`
				TaskOptions map[string]struct {
					Orientation string `json:"orientation"`
				} `json:"taskOptionsMap"`
			} `json:"builder"`
		}
		if err := json.Unmarshal(data, &profile); err != nil {
			return "", false, fmt.Errorf(
				"Cocos 构建配置 %s 无效: %w",
				relative,
				err,
			)
		}
		keys := make([]string, 0, len(profile.Builder.TaskOptions))
		for key := range profile.Builder.TaskOptions {
			keys = append(keys, key)
		}
		sort.Sort(sort.Reverse(sort.StringSlice(keys)))
		for _, key := range keys {
			orientation := strings.ToLower(strings.TrimSpace(
				profile.Builder.TaskOptions[key].Orientation,
			))
			if orientation == "" {
				continue
			}
			if !validCocosOrientation(orientation) {
				return "", false, fmt.Errorf(
					"Cocos 构建配置 %s 的 orientation %q 无效",
					relative,
					orientation,
				)
			}
			return orientation, true, nil
		}
		orientation := strings.ToLower(strings.TrimSpace(
			profile.Builder.Common.Orientation,
		))
		if orientation == "" {
			return "", false, nil
		}
		if !validCocosOrientation(orientation) {
			return "", false, fmt.Errorf(
				"Cocos 构建配置 %s 的 orientation %q 无效",
				relative,
				orientation,
			)
		}
		return orientation, true, nil
	}
	return "", false, nil
}

func validCocosOrientation(value string) bool {
	return value == "auto" || value == "portrait" || value == "landscape"
}

func stringListContains(value any, expected string) bool {
	values, ok := value.([]any)
	if !ok {
		return false
	}
	for _, value := range values {
		if text, ok := value.(string); ok && text == expected {
			return true
		}
	}
	return false
}

func installCocosTypeReference(project project.Context) error {
	assetsRoot := filepath.Join(project.WorkspaceRoot, "assets")
	referencePath := filepath.Join(assetsRoot, "playmesh-sdk.d.ts")
	game, err := filepath.Rel(
		assetsRoot,
		filepath.Join(project.SDKRoot, "playmesh-main.d.ts"),
	)
	if err != nil {
		return err
	}
	app, err := filepath.Rel(assetsRoot, filepath.Join(project.SDKRoot, "playmesh-app.d.ts"))
	if err != nil {
		return err
	}
	content := fmt.Sprintf(
		"/// <reference path=%q />\n/// <reference path=%q />\n",
		filepath.ToSlash(game),
		filepath.ToSlash(app),
	)
	return fsutil.WriteAtomicFile(referencePath, []byte(content), 0o644)
}

func installCocosExtension(root string) error {
	target := filepath.Join(root, "extensions", "playmesh")
	if _, err := os.Stat(target); err == nil {
		if _, markerErr := os.Stat(filepath.Join(target, ".playmesh-generated")); markerErr != nil {
			return errors.New("extensions/playmesh 已存在且不是 CLI 生成的扩展，拒绝覆盖")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	parent := filepath.Dir(target)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	temporary, err := os.MkdirTemp(parent, "playmesh-extension-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	err = fs.WalkDir(cocosExtensionFiles, "extension", func(source string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if source == "extension" {
			return nil
		}
		relative, err := filepath.Rel("extension", source)
		if err != nil {
			return err
		}
		destination := filepath.Join(temporary, relative)
		if entry.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		data, err := cocosExtensionFiles.ReadFile(source)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return err
		}
		return os.WriteFile(destination, data, 0o644)
	})
	if err != nil {
		return err
	}
	return fsutil.ReplaceDirectory(temporary, target)
}

func installCocosPreviewTemplate(root string) error {
	previewRoot := filepath.Join(root, "preview-template")
	if err := webpath.RejectSymlinkPath(root, previewRoot); err != nil {
		return fmt.Errorf("Cocos 预览模板路径无效: %w", err)
	}
	if err := ignoreCocosPreviewRuntime(root); err != nil {
		return err
	}
	if err := os.MkdirAll(previewRoot, 0o755); err != nil {
		return err
	}

	for _, name := range []string{
		"playmesh-preview-gate.js",
		"playmesh-preview-handoff.html",
		"playmesh-preview-handoff.js",
	} {
		source, err := cocosExtensionFiles.ReadFile("preview-template/" + name)
		if err != nil {
			return err
		}
		if err := fsutil.WriteAtomicFile(
			filepath.Join(previewRoot, name),
			source,
			0o644,
		); err != nil {
			return err
		}
	}

	foundIndex := false
	for _, name := range []string{"index.ejs", "index.html"} {
		indexPath := filepath.Join(previewRoot, name)
		info, statErr := os.Lstat(indexPath)
		if errors.Is(statErr, os.ErrNotExist) {
			continue
		}
		if statErr != nil {
			return statErr
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("Cocos 预览模板必须是普通文件: %s", indexPath)
		}
		foundIndex = true
		content, readErr := os.ReadFile(indexPath)
		if readErr != nil {
			return readErr
		}
		if bytes.Contains(content, []byte(playmeshPreviewGateStart)) {
			if name == "index.ejs" &&
				isLegacyGeneratedPreviewTemplate(content) {
				replacement, sourceErr := cocosExtensionFiles.ReadFile(
					"preview-template/index.ejs",
				)
				if sourceErr != nil {
					return sourceErr
				}
				if err := fsutil.WriteAtomicFile(
					indexPath,
					replacement,
					0o644,
				); err != nil {
					return err
				}
			}
			continue
		}
		patched, patchErr := injectCocosPreviewGate(name, content)
		if patchErr != nil {
			return patchErr
		}
		if err := fsutil.WriteAtomicFile(indexPath, patched, 0o644); err != nil {
			return err
		}
	}
	if foundIndex {
		return nil
	}

	indexSource, err := cocosExtensionFiles.ReadFile(
		"preview-template/index.ejs",
	)
	if err != nil {
		return err
	}
	return fsutil.WriteAtomicFile(
		filepath.Join(previewRoot, "index.ejs"),
		indexSource,
		0o644,
	)
}

func isLegacyGeneratedPreviewTemplate(content []byte) bool {
	normalized := strings.ReplaceAll(string(content), "\r\n", "\n")
	return strings.TrimSpace(normalized) ==
		strings.TrimSpace(legacyGeneratedPreviewTemplate)
}

func ignoreCocosPreviewRuntime(root string) error {
	ignorePath := filepath.Join(root, ".gitignore")
	info, err := os.Lstat(ignorePath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil && !info.Mode().IsRegular() {
		return errors.New("Cocos 项目的 .gitignore 必须是普通文件")
	}
	var content []byte
	if err == nil {
		content, err = os.ReadFile(ignorePath)
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(content), "\n") {
			if strings.TrimSpace(strings.TrimSuffix(line, "\r")) == playmeshPreviewRuntimeIgnore {
				return nil
			}
		}
	}
	newline := []byte("\n")
	if bytes.Contains(content, []byte("\r\n")) {
		newline = []byte("\r\n")
	}
	if len(content) > 0 && content[len(content)-1] != '\n' {
		content = append(content, newline...)
	}
	content = append(content, []byte(playmeshPreviewRuntimeIgnore)...)
	content = append(content, newline...)
	return fsutil.WriteAtomicFile(ignorePath, content, 0o644)
}

func injectCocosPreviewGate(name string, content []byte) ([]byte, error) {
	if name == "index.ejs" {
		includePattern := regexp.MustCompile(
			`(?m)<%-\s*include\s*\(\s*cocosTemplate\s*,\s*\{\s*\}\s*\)\s*%>`,
		)
		location := includePattern.FindIndex(content)
		if location == nil {
			return nil, errors.New(
				"preview-template/index.ejs 缺少 Cocos cocosTemplate include，无法安全安装 Playmesh 自动预览门禁",
			)
		}
		return append(
			append(
				append([]byte(nil), content[:location[0]]...),
				[]byte(playmeshPreviewGateTag)...,
			),
			content[location[0]:]...,
		), nil
	}

	scriptPattern := regexp.MustCompile(`(?i)<script\b`)
	if location := scriptPattern.FindIndex(content); location != nil {
		return append(
			append(
				append([]byte(nil), content[:location[0]]...),
				[]byte(playmeshPreviewGateTag)...,
			),
			content[location[0]:]...,
		), nil
	}
	headPattern := regexp.MustCompile(`(?i)</head\s*>`)
	if location := headPattern.FindIndex(content); location != nil {
		return append(
			append(
				append([]byte(nil), content[:location[0]]...),
				[]byte(playmeshPreviewGateTag)...,
			),
			content[location[0]:]...,
		), nil
	}
	return append([]byte(playmeshPreviewGateTag), content...), nil
}
