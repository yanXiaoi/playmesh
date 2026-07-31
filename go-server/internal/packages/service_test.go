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

func TestParseManifestLimitsTagsToFive(t *testing.T) {
	_, fiveFindings := parseManifest([]byte(
		`{"id":"com.example.five","name":"Five","version":"1.0.0",` +
			`"tags":["one","two","three","four","five"]}`,
	))
	if len(fiveFindings) != 0 {
		t.Fatalf("five tags must be accepted: %v", fiveFindings)
	}

	_, sixFindings := parseManifest([]byte(
		`{"id":"com.example.six","name":"Six","version":"1.0.0",` +
			`"tags":["one","two","three","four","five","six"]}`,
	))
	if len(sixFindings) != 1 ||
		sixFindings[0] != "main.json.tags 最多只能包含 5 个标签" {
		t.Fatalf("six tags must be rejected: %v", sixFindings)
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

func TestInspectArchiveRejectsManifestEntryQueryContentRules(t *testing.T) {
	cases := []struct {
		name   string
		entry  string
		ruleID string
	}{
		{
			name:   "HTTP",
			entry:  "index.html?target=http://evil.example/game",
			ruleID: "external-http-ws",
		},
		{
			name:   "HTTPS",
			entry:  "index.html?target=https://evil.example/game",
			ruleID: "external-http-ws",
		},
		{
			name:   "WebSocket",
			entry:  "index.html?target=ws://evil.example/socket",
			ruleID: "external-http-ws",
		},
		{
			name:   "Secure WebSocket",
			entry:  "index.html?target=wss://evil.example/socket",
			ruleID: "external-http-ws",
		},
		{
			name:   "File",
			entry:  "index.html?target=file://server/share",
			ruleID: "file-protocol",
		},
		{
			name:   "JavaScript",
			entry:  "index.html?target=javascript:alert(1)",
			ruleID: "javascript-url",
		},
		{
			name:   "HTML Data URL",
			entry:  "index.html?target=data:text/html,<script></script>",
			ruleID: "html-data-url",
		},
		{
			name:   "百分号编码 HTTPS",
			entry:  "index.html?target=https%3A%2F%2Fevil.example/game",
			ruleID: "external-http-ws",
		},
		{
			name: "多重编码 HTTPS",
			entry: "index.html?target=" +
				"https%25253A%25252F%25252Fevil.example/game",
			ruleID: "external-http-ws",
		},
		{
			name: "分段多重编码 HTTPS",
			entry: "index.html?target=" +
				"h%2574tps%253A%252F%252Fevil.example/game",
			ruleID: "external-http-ws",
		},
		{
			name: "其他参数解码为百分号时仍扫描后续外链",
			entry: "index.html?label=100%2525&target=" +
				"https%253A%252F%252Fevil.example/game",
			ruleID: "external-http-ws",
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

func TestInspectArchiveScansControllerEntryQuery(t *testing.T) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["displayModes"] = []string{"single_screen_multiplayer"}
	manifest["entries"] = map[string]any{
		"game": "index.html",
		"controller": "controller.html?" +
			"socket=wss%253A%252F%252Fevil.example",
	}
	manifest["authority"] = map[string]any{"entry": "authority.js"}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html":      "<!doctype html>",
		"app/controller.html": "<!doctype html>",
		"app/authority.js":    "export {};",
	})
	if !containsFindingText(
		findings,
		"[external-http-ws]: main.json.entries.controller 查询参数",
	) {
		t.Fatalf("控制器入口查询未按 HTML 活动内容扫描: %#v", findings)
	}
}

func TestInspectArchiveIgnoresUnknownManifestFieldsDuringContentScan(
	t *testing.T,
) {
	manifest := testPackageManifest()
	manifest["untrustedExtra"] = "https%253A%252F%252Fevil.example"
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html": "<!doctype html>",
	})
	if len(findings) != 0 {
		t.Fatalf("未知 main.json 字段不应参与云分发内容扫描: %#v", findings)
	}
}

func TestInspectArchiveRejectsUnsafeManifestEntries(t *testing.T) {
	cases := map[string]string{
		"根绝对路径":     "/index.html",
		"平台保留目录":    "playmesh/index.html",
		"平台保留目录大小写": "BuCkEt/index.html",
		"百分号编码":     "%70laymesh/index.html",
		"非编码百分号":    "assets/%zz/index.html",
		"反斜杠":       `assets\index.html`,
		"上级点段":      "assets/../index.html",
		"当前点段":      "assets/./index.html",
		"空路径段":      "assets//index.html",
		"空查询参数":     "index.html?",
		"查询参数无效编码":  "index.html?scene=%zz",
		"Fragment":  "index.html#game",
		"外部 URL":    "https://example.com/index.html",
	}
	for name, entry := range cases {
		t.Run(name, func(t *testing.T) {
			manifest := testPackageManifest()
			manifest["entries"] = map[string]any{"game": entry}
			_, findings := inspectTestArchive(t, manifest, map[string]string{
				"app/index.html": "<!doctype html>",
			})
			if !containsFinding(findings, "main.json.entries.game") {
				t.Fatalf("危险入口 %q 未被拒绝: %#v", entry, findings)
			}
		})
	}
}

func TestInspectArchiveRejectsAuthorityEntryQuery(t *testing.T) {
	manifest := testPackageManifest()
	manifest["modes"] = []string{"multiplayer"}
	manifest["authority"] = map[string]any{
		"entry": "authority.js?worker=1",
	}
	_, findings := inspectTestArchive(t, manifest, map[string]string{
		"app/index.html":   "<!doctype html>",
		"app/authority.js": "export {};",
	})
	if !containsFinding(
		findings,
		"main.json.authority.entry 不允许查询参数",
	) {
		t.Fatalf("Authority 查询参数未被拒绝: %#v", findings)
	}
}

func TestInspectArchiveRejectsWrongManifestEntryExtensions(t *testing.T) {
	cases := []struct {
		name         string
		configure    func(map[string]any)
		files        map[string]string
		findingField string
	}{
		{
			name: "游戏入口必须是 HTML",
			configure: func(manifest map[string]any) {
				manifest["entries"] = map[string]any{"game": "game.js"}
			},
			files: map[string]string{
				"app/game.js": "export {};",
			},
			findingField: "main.json.entries.game 必须是 .html 文件",
		},
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
			findingField: "main.json.entries.controller 必须是 .html 文件",
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
			findingField: "main.json.authority.entry 必须是 .js 或 .mjs 文件",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			manifest := testPackageManifest()
			testCase.configure(manifest)
			_, findings := inspectTestArchive(t, manifest, testCase.files)
			if !containsFinding(findings, testCase.findingField) {
				t.Fatalf("错误入口扩展名未被拒绝: %#v", findings)
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

func TestInspectArchiveRequiresCurrentSDKVersions(t *testing.T) {
	cases := []struct {
		name         string
		field        string
		value        any
		remove       bool
		findingField string
	}{
		{
			name:         "缺少 Game SDK 版本",
			field:        "sdkVersion",
			remove:       true,
			findingField: "main.json.sdkVersion 必须显式声明为 4.0.0",
		},
		{
			name:         "旧 Game SDK 版本",
			field:        "sdkVersion",
			value:        "3.2.0",
			findingField: "main.json.sdkVersion 必须显式声明为 4.0.0",
		},
		{
			name:         "缺少 App SDK 版本",
			field:        "appSdkVersion",
			remove:       true,
			findingField: "main.json.appSdkVersion 必须显式声明为 3.2.0",
		},
		{
			name:         "旧 App SDK 版本",
			field:        "appSdkVersion",
			value:        "3.1.0",
			findingField: "main.json.appSdkVersion 必须显式声明为 3.2.0",
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
			if !containsFinding(findings, testCase.findingField) {
				t.Fatalf("非当前 SDK 契约未被拒绝: %#v", findings)
			}
		})
	}
}

func TestInspectArchiveRequiresResolvedManifestEntries(t *testing.T) {
	t.Run("游戏入口声明", func(t *testing.T) {
		manifest := testPackageManifest()
		delete(manifest, "entries")
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html": "<!doctype html>",
		})
		if !containsFinding(findings, "main.json.entries.game 必须显式声明") {
			t.Fatalf("缺少游戏入口声明未被拒绝: %#v", findings)
		}
	})

	t.Run("游戏入口文件", func(t *testing.T) {
		_, findings := inspectTestArchive(t, testPackageManifest(), nil)
		if !containsFinding(findings, "main.json.entries.game 对应文件不存在") {
			t.Fatalf("缺少游戏入口文件未被拒绝: %#v", findings)
		}
	})

	t.Run("单屏多人控制器声明", func(t *testing.T) {
		manifest := testPackageManifest()
		manifest["modes"] = []string{"multiplayer"}
		manifest["displayModes"] = []string{"single_screen_multiplayer"}
		manifest["authority"] = map[string]any{"entry": "authority.js"}
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html":   "<!doctype html>",
			"app/authority.js": "export {};",
		})
		if !containsFinding(
			findings,
			"main.json.entries.controller 必须显式声明",
		) {
			t.Fatalf("缺少控制器入口声明未被拒绝: %#v", findings)
		}
	})

	t.Run("单屏多人控制器文件", func(t *testing.T) {
		manifest := testPackageManifest()
		manifest["modes"] = []string{"multiplayer"}
		manifest["displayModes"] = []string{"single_screen_multiplayer"}
		manifest["entries"] = map[string]any{
			"game":       "index.html",
			"controller": "controller/index.html",
		}
		manifest["authority"] = map[string]any{"entry": "authority.js"}
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html":   "<!doctype html>",
			"app/authority.js": "export {};",
		})
		if !containsFinding(
			findings,
			"main.json.entries.controller 对应文件不存在",
		) {
			t.Fatalf("缺少控制器入口文件未被拒绝: %#v", findings)
		}
	})

	t.Run("多人 Authority 声明", func(t *testing.T) {
		manifest := testPackageManifest()
		manifest["modes"] = []string{"multiplayer"}
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html": "<!doctype html>",
		})
		if !containsFinding(findings, "多人游戏缺少 main.json.authority.entry") {
			t.Fatalf("缺少 Authority 声明未被拒绝: %#v", findings)
		}
	})

	t.Run("Authority 入口文件", func(t *testing.T) {
		manifest := testPackageManifest()
		manifest["modes"] = []string{"multiplayer"}
		manifest["authority"] = map[string]any{"entry": "authority.js"}
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html": "<!doctype html>",
		})
		if !containsFinding(
			findings,
			"main.json.authority.entry 对应文件不存在",
		) {
			t.Fatalf("缺少 Authority 文件未被拒绝: %#v", findings)
		}
	})

	t.Run("非联机模式忽略控制器与 Authority", func(t *testing.T) {
		manifest := testPackageManifest()
		manifest["entries"] = map[string]any{
			"game":       "index.html",
			"controller": "missing/controller.html",
		}
		manifest["authority"] = map[string]any{"entry": "missing/authority.js"}
		_, findings := inspectTestArchive(t, manifest, map[string]string{
			"app/index.html": "<!doctype html>",
		})
		if containsFinding(findings, "main.json.entries.controller") ||
			containsFinding(findings, "main.json.authority") {
			t.Fatalf("非联机模式不应校验控制器或 Authority: %#v", findings)
		}
	})
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
		"sdkVersion":    requiredGameSDKVersion,
		"appSdkVersion": requiredAppSDKVersion,
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
	allFiles := make(map[string]string, len(files)+1)
	allFiles["main.json"] = string(manifestBytes)
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
