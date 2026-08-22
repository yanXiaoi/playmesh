package packages

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"io"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"

	"go-server/internal/config"
	"go-server/internal/mailer"
	"go-server/internal/store"
)

func TestSafeRootIconRequiresCompletePngDecode(t *testing.T) {
	var encoded bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 1, 1))
	icon.Pix = []byte{0x18, 0xA8, 0xC9, 0xFF}
	if err := png.Encode(&encoded, icon); err != nil {
		t.Fatal(err)
	}
	valid := encoded.Bytes()
	if !isSafeRootIcon(valid) {
		t.Fatal("complete PNG must be accepted")
	}
	if len(valid) < 33 {
		t.Fatalf("unexpected encoded PNG length: %d", len(valid))
	}
	configOnly := valid[:33]
	if _, err := png.DecodeConfig(bytes.NewReader(configOnly)); err != nil {
		t.Fatalf("test fixture must contain a valid PNG header: %v", err)
	}
	if isSafeRootIcon(configOnly) {
		t.Fatal("header-only PNG must be ignored because full decode fails")
	}
}

func TestParseManifestIndexesFiveTagsWithoutRejectingAdditionalTags(t *testing.T) {
	summary, findings := parseManifest([]byte(
		`{"id":"com.example.six","name":"Six","version":"1.0.0",` +
			`"tags":["one","two","three","four","five","six"]}`,
	))
	if len(findings) != 0 {
		t.Fatalf("额外标签不应阻止上传: %v", findings)
	}
	if summary.TagsText != "one,two,three,four,five" {
		t.Fatalf("列表标签索引未安全截取: %q", summary.TagsText)
	}
	if !strings.Contains(summary.JSON, `"six"`) {
		t.Fatalf("原始 Manifest 标签不应丢失: %s", summary.JSON)
	}
}

func TestInspectArchiveDoesNotRestrictNonEntryFileTypes(t *testing.T) {
	_, findings := inspectTestArchive(t, testPackageManifest(), map[string]string{
		"app/game.exe":      "MZ arbitrary browser download",
		"app/module.wasm":   "\x00asm",
		"app/archive.bin":   "arbitrary bytes",
		"app/source.custom": "custom resource",
		"app/no-extension":  "extensionless resource",
	})
	if len(findings) != 0 {
		t.Fatalf("非入口文件不应按扩展名或文件类型拒绝: %#v", findings)
	}
}

func TestInspectArchiveRequiresUsableDeclaredHTMLGameEntry(t *testing.T) {
	manifest := testPackageManifest()
	manifest["entries"] = map[string]any{"game": "pages/home.html?scene=main"}
	invalid := []struct {
		name  string
		files map[string]string
	}{
		{name: "missing", files: nil},
		{name: "empty", files: map[string]string{"app/pages/home.html": " \r\n\t"}},
		{name: "invalid UTF-8", files: map[string]string{
			"app/pages/home.html": string([]byte{0xff, 0xfe, 0xfd}),
		}},
		{name: "NUL", files: map[string]string{
			"app/pages/home.html": "<!doctype html>\x00",
		}},
	}
	for _, testCase := range invalid {
		t.Run(testCase.name, func(t *testing.T) {
			_, findings := inspectTestArchiveWithoutDefaultEntry(
				t, manifest, testCase.files,
			)
			if !containsFindingText(findings, "entries.game") {
				t.Fatalf("无效网页入口未被拒绝: %#v", findings)
			}
		})
	}

	_, findings := inspectTestArchiveWithoutDefaultEntry(
		t,
		manifest,
		map[string]string{
			"app/pages/home.html": "\ufeff  <!doctype html><title>Game</title>",
		},
	)
	if len(findings) != 0 {
		t.Fatalf("正常 UTF-8 网页文本被拒绝: %#v", findings)
	}
}

func TestInspectArchiveAcceptsAppRelativeEntriesAndNestedReservedNames(
	t *testing.T,
) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["displayModes"] = []string{"single_screen_multiplayer"}
	manifest["entries"] = map[string]any{
		"game":       "screens/game/index.html",
		"controller": "controllers/pad.html",
	}
	manifest["authority"] = map[string]any{
		"entry": "services/authority.js",
	}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/screens/game/index.html":       "<!doctype html>",
		"app/controllers/pad.html":          "<!doctype html>",
		"app/services/authority.js":         "export {};",
		"app/assets/playmesh/allowed.js":    "export {};",
		"app/content/bucket/allowed.json":   "{}",
		"app/assets/application/index.html": "<!doctype html>",
	})
	if len(findings) != 0 {
		t.Fatalf("相对 app/ 入口或嵌套同名目录被拒绝: %#v", findings)
	}
}

func TestInspectArchiveAllowsUserAppDirectory(t *testing.T) {
	manifest := testPackageManifest()
	manifest["entries"] = map[string]any{"game": "app/index.html"}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/app/index.html":              "<!doctype html>",
		"app/app/playmesh/user-script.js": "export {};",
	})
	if len(findings) != 0 {
		t.Fatalf("用户 app/ 目录被错误拒绝: %#v", findings)
	}
}

func TestInspectArchiveAcceptsHTMLManifestEntryQueries(t *testing.T) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["displayModes"] = []string{"single_screen_multiplayer"}
	manifest["entries"] = map[string]any{
		"game": "screens/game/index.html?" +
			"scene=current_scene&mode=solo&mode=coop",
		"controller": "controllers/pad.html?" +
			"layout=compact%20pad&theme=dark",
	}
	manifest["authority"] = map[string]any{"entry": "authority.js"}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/screens/game/index.html": "<!doctype html>",
		"app/controllers/pad.html":    "<!doctype html>",
		"app/authority.js":            "export {};",
	})
	if len(findings) != 0 {
		t.Fatalf("安全查询参数或物理入口路径拆分被拒绝: %#v", findings)
	}
}

func TestInspectArchiveAppliesRemainingManifestEntryQueryContentRules(t *testing.T) {
	cases := []struct {
		name   string
		entry  string
		ruleID string
	}{
		{
			name:   "HTML Data URL",
			entry:  "index.html?target=data:text/html,<script></script>",
			ruleID: "html-data-url",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := testPackageManifest()
			manifest["entries"] = map[string]any{"game": testCase.entry}
			_, findings := inspectTestArchive(t, manifest, map[string]string{
				"app/index.html": "<!doctype html>",
			})
			if !containsFindingText(
				findings,
				"["+testCase.ruleID+"]: main.json.entries.game 查询参数",
			) {
				t.Fatalf(
					"入口查询中的活动内容规则 %s 未命中明确字段: %#v",
					testCase.ruleID,
					findings,
				)
			}
		})
	}
}

func TestInspectArchiveAcceptsRetiredDefaultContentPatterns(t *testing.T) {
	_, findings := inspectTestArchive(t, testPackageManifest(), map[string]string{
		"app/Extensions/Physics3DBehavior/jolt-physics.wasm.js":                    `const localResource = "file://physics-cache";`,
		"app/msx03fex-2bu1ewi6-gdjs-evtsext__gamepads__onfirstsceneloaded-func.js": `const template = "<iframe src='controller.html'></iframe>";`,
		"app/pixi-renderers/draco/gltf/draco_wasm_wrapper.js":                      `const decoder = "file://draco/decoder.wasm";`,
		"app/pixi-renderers/pixi.js":                                               `const link = "javascript:void(0)";`,
		"app/ResourceLoader.js":                                                    `const fallback = "file://resource-cache";`,
	})
	if len(findings) != 0 {
		t.Fatalf("已取消的默认内容模式不应阻止上传: %#v", findings)
	}
}

func TestInspectArchiveAcceptsExternalLinksAndFunctionConstructor(t *testing.T) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["displayModes"] = []string{"single_screen_multiplayer"}
	manifest["entries"] = map[string]any{
		"game": "index.html?target=https%253A%252F%252Fcdn.example/game",
		"controller": "controller.html?" +
			"socket=wss%253A%252F%252Frelay.example",
	}
	manifest["authority"] = map[string]any{"entry": "authority.js"}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html": "<!doctype html><script " +
			`src="https://cdn.example/game.js"></script>`,
		"app/controller.html": "<!doctype html><script " +
			`src="//cdn.example/controller.js"></script>`,
		"app/authority.js": "export {};",
		"app/runtime.js": `const factory = new Function("source", source);` +
			`const socket = new WebSocket("wss://relay.example");`,
		"app/style.css": `body{background-image:url("//cdn.example/a.png")}`,
	})
	if len(findings) != 0 {
		t.Fatalf("外部链接或动态 Function 不应阻止上传: %#v", findings)
	}
}

func TestInspectArchiveIgnoresUnknownManifestFieldsDuringContentScan(
	t *testing.T,
) {
	manifest := testPackageManifest()
	manifest["untrustedExtra"] = "https%253A%252F%252Fevil.example"
	summary, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html": "<!doctype html>",
	})
	if len(findings) != 0 {
		t.Fatalf("未知 main.json 字段不应参与云分发内容扫描: %#v", findings)
	}
	if !strings.Contains(summary.JSON, `"untrustedExtra":"https%253A%252F%252Fevil.example"`) {
		t.Fatalf("未知 main.json 字段应原样保留: %s", summary.JSON)
	}
}

func TestInspectArchiveRejectsUnusableDeclaredGameEntry(t *testing.T) {
	cases := map[string]string{
		"根绝对路径":    "/index.html",
		"平台保留目录":   "playmesh/index.html",
		"反斜杠":      `assets\index.html`,
		"上级点段":     "assets/../index.html",
		"Fragment": "index.html#game",
		"非 HTML":   "game.js",
		"不存在":      "missing.html",
	}
	for name, entry := range cases {
		t.Run(name, func(t *testing.T) {
			manifest := testPackageManifest()
			manifest["entries"] = map[string]any{"game": entry}
			_, findings := inspectTestArchiveWithoutDefaultEntry(t, manifest, map[string]string{
				"app/index.html": "<!doctype html>",
			})
			if !containsFindingText(findings, "entries.game") {
				t.Fatalf("不可用的主网页入口未被拒绝 %q: %#v", entry, findings)
			}
		})
	}
}

func TestInspectArchiveDoesNotEnforceAuthorityEntryShape(t *testing.T) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["authority"] = map[string]any{
		"entry": "authority.js?worker=1",
	}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html":   "<!doctype html>",
		"app/authority.js": "export {};",
	})
	if len(findings) != 0 {
		t.Fatalf("服务端不应按当前 Authority 结构拒绝上传: %#v", findings)
	}
}

func TestInspectArchiveDoesNotEnforceNonGameEntryExtensions(t *testing.T) {
	cases := []struct {
		name      string
		configure func(map[string]any)
		files     map[string]string
	}{
		{
			name: "控制器入口必须是 HTML",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
				manifest["displayModes"] = []string{"single_screen_multiplayer"}
				manifest["entries"] = map[string]any{
					"game":       "index.html",
					"controller": "controller.js",
				}
				manifest["authority"] = map[string]any{"entry": "authority.js"}
			},
			files: map[string]string{
				"app/index.html":    "<!doctype html>",
				"app/controller.js": "export {};",
				"app/authority.js":  "export {};",
			},
		},
		{
			name: "Authority 入口必须是 JavaScript",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
				manifest["authority"] = map[string]any{
					"entry": "authority.html",
				}
			},
			files: map[string]string{
				"app/index.html":     "<!doctype html>",
				"app/authority.html": "<!doctype html>",
			},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := testPackageManifest()
			testCase.configure(manifest)
			_, findings := inspectTestArchive(t, manifest, testCase.files)
			if len(findings) != 0 {
				t.Fatalf("服务端不应按当前入口扩展名拒绝上传: %#v", findings)
			}
		})
	}
}

func TestInspectArchiveRejectsReservedAppDirectories(t *testing.T) {
	for _, entry := range []string{
		"app/playmesh/file.js",
		"app/PLAYMESH/file.js",
		"app/bucket/file.js",
		"app/BuCkEt/file.js",
		"app/%70laymesh/file.js",
		"app/%62ucket/file.js",
		"app/assets/%zz/file.js",
	} {
		t.Run(strings.ReplaceAll(entry, "/", "_"), func(t *testing.T) {
			_, findings := inspectTestArchive(
				t,
				testPackageManifest(),
				map[string]string{
					"app/index.html": "<!doctype html>",
					entry:            "export {};",
				},
			)
			if len(findings) == 0 {
				t.Fatalf("平台保留目录绕过未被拒绝: %s", entry)
			}
		})
	}
}

func TestInspectArchiveDoesNotEnforceSDKVersions(t *testing.T) {
	cases := []struct {
		name   string
		field  string
		value  any
		remove bool
	}{
		{
			name: "缺少 Game SDK 版本", field: "sdkVersion", remove: true,
		},
		{
			name: "未来 Game SDK 版本", field: "sdkVersion", value: "99.0.0",
		},
		{
			name: "缺少 App SDK 版本", field: "appSdkVersion", remove: true,
		},
		{
			name: "非语义 App SDK 版本", field: "appSdkVersion", value: map[string]any{
				"channel": "next",
			},
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := testPackageManifest()
			if testCase.remove {
				delete(manifest, testCase.field)
			} else {
				manifest[testCase.field] = testCase.value
			}
			_, findings := inspectTestArchive(t, manifest, map[string]string{
				"app/index.html": "<!doctype html>",
			})
			if len(findings) != 0 {
				t.Fatalf("SDK 声明不应由上传服务限制: %#v", findings)
			}
		})
	}
}

func TestInspectArchiveDoesNotEnforceUnrelatedManifestShape(t *testing.T) {
	cases := []struct {
		name      string
		configure func(map[string]any)
	}{
		{"多人字段尚未定义", func(manifest map[string]any) {
			manifest["modes"] = []string{"multiplayer"}
			delete(manifest, "authority")
		}},
		{"未来非入口结构", func(manifest map[string]any) {
			manifest["players"] = map[string]any{"future": true}
			manifest["runtime"] = []any{"next"}
		}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := testPackageManifest()
			testCase.configure(manifest)
			_, findings := inspectTestArchive(t, manifest, nil)
			if len(findings) != 0 {
				t.Fatalf("非核心 Manifest 结构不应阻止上传: %#v", findings)
			}
		})
	}
}

func TestInspectArchiveDoesNotRejectOptionalMetadataShape(t *testing.T) {
	manifest := testPackageManifest()
	manifest["author"] = strings.Repeat("a", 200)
	manifest["remarks"] = strings.Repeat("r", 3000)
	manifest["tags"] = []any{
		strings.Repeat("t", 80), "one", "two", "three", "four", "five", "six",
	}
	manifest["players"] = "future-shape"
	_, findings := inspectTestArchive(t, manifest, nil)
	if len(findings) != 0 {
		t.Fatalf("非核心 Manifest 字段不应阻止上传: %#v", findings)
	}
}

func TestInspectArchiveStillRequiresServerMetadata(t *testing.T) {
	cases := []struct {
		field   string
		finding string
	}{
		{"id", "main.json.id 缺失或格式无效"},
		{"name", "main.json.name 缺失或过长"},
		{"version", "main.json.version 必须是无前缀的 MAJOR.MINOR.PATCH"},
	}
	for _, testCase := range cases {
		t.Run(testCase.field, func(t *testing.T) {
			manifest := testPackageManifest()
			delete(manifest, testCase.field)
			_, findings := inspectTestArchive(t, manifest, nil)
			if !containsFinding(findings, testCase.finding) {
				t.Fatalf("缺少服务端核心字段 %s 未被拒绝: %#v", testCase.field, findings)
			}
		})
	}
}

func TestDeleteStoredFilesRemovesFilesAndIsRetrySafe(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "game.zip")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := DeleteStoredFiles(root, archive); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(archive); !os.IsNotExist(err) {
		t.Fatalf("删除后原文件仍可见: %v", err)
	}
	if err := DeleteStoredFiles(root, archive); err != nil {
		t.Fatal(err)
	}
}

func testPackageManifest() map[string]any {
	return map[string]any{
		"id":            "com.example.entries",
		"name":          "Entries",
		"version":       "1.0.0",
		"sdkVersion":    "4.1.0",
		"appSdkVersion": "3.3.0",
		"entries": map[string]any{
			"game": "index.html",
		},
	}
}

func inspectTestArchive(
	t *testing.T,
	manifest map[string]any,
	files map[string]string,
) (manifestSummary, []string) {
	t.Helper()
	return inspectTestArchiveWithDefaultEntry(t, manifest, files, true)
}

func inspectTestArchiveWithoutDefaultEntry(
	t *testing.T,
	manifest map[string]any,
	files map[string]string,
) (manifestSummary, []string) {
	t.Helper()
	return inspectTestArchiveWithDefaultEntry(t, manifest, files, false)
}

func inspectTestArchiveWithDefaultEntry(
	t *testing.T,
	manifest map[string]any,
	files map[string]string,
	includeDefaultEntry bool,
) (manifestSummary, []string) {
	t.Helper()
	archivePath := filepath.Join(t.TempDir(), "game.zip")
	output, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(output)
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	allFiles := make(map[string]string, len(files)+2)
	allFiles["main.json"] = string(manifestBytes)
	if includeDefaultEntry {
		if entries, ok := manifest["entries"].(map[string]any); ok {
			if rawEntry, ok := entries["game"].(string); ok {
				entryPath, _, _ := strings.Cut(rawEntry, "?")
				physicalPath := "app/" + entryPath
				if cleaned, valid := safeArchivePath(physicalPath); valid &&
					strings.ToLower(path.Ext(cleaned)) == ".html" {
					allFiles[cleaned] = "<!doctype html><title>Test Game</title>"
				}
			}
		}
	}
	for name, content := range files {
		allFiles[name] = content
	}
	for name, content := range allFiles {
		entry, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(entry, content); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	service := &Service{
		config:       cfg,
		contentRules: compileContentRules(cfg.Scanner.ContentRules),
	}
	return service.inspectArchive(archivePath)
}

func containsFindingText(findings []string, expected string) bool {
	for _, finding := range findings {
		if strings.Contains(finding, expected) {
			return true
		}
	}
	return false
}

func TestCleanupDeletingRetriesPersistedRecords(t *testing.T) {
	root := t.TempDir()
	storage := config.Storage{
		DatabasePath:        filepath.Join(root, "server.db"),
		GamesDirectory:      filepath.Join(root, "games"),
		QuarantineDirectory: filepath.Join(root, "quarantine"),
		MaxConcurrentScans:  1,
	}
	database, err := store.Open(storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	archive := filepath.Join(storage.GamesDirectory, "game.zip")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	game, err := database.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID: "com.example.cleanup", Name: "Cleanup", Author: "Owner",
		Version: "1.0.0", OwnerUserID: owner.ID, Status: store.StatusPending,
		OriginalFilename: "game.zip", StoredPath: archive,
		ManifestJSON: `{"id":"com.example.cleanup","version":"1.0.0"}`,
		ScanStatus:   "clean", ScanReport: "{}",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.BeginDeleteOwnedGame(
		ctx, game.ID, store.UserReviewActor(owner.ID),
	); err != nil {
		t.Fatal(err)
	}
	service := New(
		config.Config{Storage: storage}, database, mailer.New(config.Mail{}),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	completed, err := service.CleanupDeleting(ctx)
	if err != nil || completed != 1 {
		t.Fatalf("后台清理 completed=%d err=%v", completed, err)
	}
	if _, err := database.GetGame(ctx, game.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("后台清理后记录仍存在: %v", err)
	}
	if _, err := os.Stat(archive); !os.IsNotExist(err) {
		t.Fatalf("后台清理后文件仍存在: %v", err)
	}
}

func TestCleanupDeletingRemovesOnlyUnreferencedGeneratedArtifacts(t *testing.T) {
	root := t.TempDir()
	storage := config.Storage{
		DatabasePath:        filepath.Join(root, "server.db"),
		GamesDirectory:      filepath.Join(root, "games"),
		QuarantineDirectory: filepath.Join(root, "quarantine"),
		MaxConcurrentScans:  1,
	}
	database, err := store.Open(storage, store.Settings{})
	if err != nil {
		t.Fatal(err)
	}
	defer database.Close()
	ctx := context.Background()
	owner, err := database.CreateUser(ctx, "owner@example.com", "hash", "active")
	if err != nil {
		t.Fatal(err)
	}
	referencedArchive := filepath.Join(
		storage.GamesDirectory,
		"1710000000000-aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb.zip",
	)
	referencedIcon := filepath.Join(
		storage.GamesDirectory,
		"1710000000001-aaaaaaaaaaaaaaaa-cccccccccccccccc.png",
	)
	for _, filePath := range []string{referencedArchive, referencedIcon} {
		if err := os.WriteFile(filePath, []byte("referenced"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := database.CreateOwnedGame(ctx, store.CreateGameInput{
		PackageID: "com.example.referenced", Name: "Referenced", Author: "Owner",
		Version: "1.0.0", OwnerUserID: owner.ID, Status: store.StatusPending,
		OriginalFilename: "game.zip", StoredPath: referencedArchive,
		IconPath:     referencedIcon,
		ManifestJSON: `{"id":"com.example.referenced","version":"1.0.0"}`,
		ScanStatus:   "clean", ScanReport: "{}",
	}); err != nil {
		t.Fatal(err)
	}
	orphaned := []string{
		filepath.Join(
			storage.GamesDirectory,
			"1710000000002-dddddddddddddddd-eeeeeeeeeeeeeeee.zip",
		),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000003-dddddddddddddddd-ffffffffffffffff.png",
		),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000004-dddddddddddddddd-1111111111111111.zip.tmp",
		),
		filepath.Join(storage.QuarantineDirectory, "upload-12345.zip"),
		filepath.Join(storage.QuarantineDirectory, "normalized-67890.zip"),
	}
	preserved := []string{
		referencedArchive,
		referencedIcon,
		filepath.Join(storage.GamesDirectory, "operator-file.zip"),
		filepath.Join(
			storage.GamesDirectory,
			"1710000000005-DDDDDDDDDDDDDDDD-2222222222222222.zip",
		),
		filepath.Join(storage.QuarantineDirectory, "operator-file.zip"),
	}
	for _, filePath := range append(orphaned, preserved[2:]...) {
		if err := os.WriteFile(filePath, []byte("artifact"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	generatedDirectory := filepath.Join(
		storage.GamesDirectory,
		"1710000000006-dddddddddddddddd-3333333333333333.zip",
	)
	if err := os.Mkdir(generatedDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	service := New(
		config.Config{Storage: storage}, database, mailer.New(config.Mail{}),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	completed, err := service.CleanupDeleting(ctx)
	if err != nil || completed != 0 {
		t.Fatalf("orphan cleanup completed=%d err=%v", completed, err)
	}
	for _, filePath := range orphaned {
		if _, err := os.Stat(filePath); !os.IsNotExist(err) {
			t.Fatalf("orphan artifact remains: %s: %v", filePath, err)
		}
	}
	for _, filePath := range preserved {
		if _, err := os.Stat(filePath); err != nil {
			t.Fatalf("referenced or unrelated file removed: %s: %v", filePath, err)
		}
	}
	if info, err := os.Stat(generatedDirectory); err != nil || !info.IsDir() {
		t.Fatalf("generated-looking directory must be preserved: %v", err)
	}
}
