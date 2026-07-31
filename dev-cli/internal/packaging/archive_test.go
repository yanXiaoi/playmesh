package packaging

import (
	"archive/zip"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManifestVersionsComeFromLocalSDK(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "playmesh", "sdk"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-main.js"), `const PLAYMESH_SDK_VERSION = "4.0.0";`)
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.js"), `const PLAYMESH_APP_SDK_VERSION = "3.2.0";`)
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"9.9.9","appSdkVersion":"9.9.9","permissions":["keyboard"],"icon":"app/legacy.png","redundant":{"kept":false}}`)

	versions, err := versionsFromSDK(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := updateManifestSDKVersions(root, versions); err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	data, _ := os.ReadFile(filepath.Join(root, "main.json"))
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest["sdkVersion"] != "4.0.0" || manifest["appSdkVersion"] != "3.2.0" {
		t.Fatalf("manifest versions were not normalized: %#v", manifest)
	}
	if _, exists := manifest["permissions"]; exists {
		t.Fatalf("removed permissions field was preserved: %#v", manifest)
	}
	if _, exists := manifest["icon"]; exists {
		t.Fatalf("unknown field was preserved: %#v", manifest)
	}
	if _, exists := manifest["redundant"]; exists {
		t.Fatalf("ordinary unknown field was preserved: %#v", manifest)
	}
}

func TestInstallSDKUsesPlaymeshDirectoryAndPreservesLegacyState(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, ".playmesh", "sdk", "legacy.js"), "legacy")
	writeTestFile(t, filepath.Join(root, ".playmesh", "keep.txt"), "keep")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh.d.ts"), "obsolete")
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	bundle := sdkBundle{
		GameSDKVersion: requiredGameSDKVersion,
		AppSDKVersion:  requiredAppSDKVersion,
		Encoding:       "base64",
		Files: map[string]string{
			"playmesh-main.js":   encoded(`const PLAYMESH_SDK_VERSION = "4.0.0";`),
			"playmesh-app.js":    encoded(`const PLAYMESH_APP_SDK_VERSION = "3.2.0";`),
			"playmesh-main.d.ts": encoded("declare const playmesh: unknown;"),
			"playmesh-app.d.ts":  encoded("declare const playmeshApp: unknown;"),
		},
	}
	if _, err := installSDK(root, bundle); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "playmesh", "sdk", "playmesh-main.js")); err != nil {
		t.Fatalf("new SDK directory was not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "playmesh", "sdk", "playmesh-main.d.ts")); err != nil {
		t.Fatalf("new Game SDK declaration was not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "playmesh", "sdk", "playmesh.d.ts")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("obsolete playmesh.d.ts must be removed, got: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".playmesh", "sdk", "legacy.js")); err != nil {
		t.Fatalf("legacy .playmesh/sdk content must be preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".playmesh", "keep.txt")); err != nil {
		t.Fatalf("non-SDK legacy content must be preserved: %v", err)
	}
}

func TestInstallSDKRejectsNonCurrentVersionsWithoutWriting(t *testing.T) {
	encoded := func(value string) string {
		return base64.StdEncoding.EncodeToString([]byte(value))
	}
	cases := []struct {
		name string
		game string
		app  string
	}{
		{name: "旧 Game SDK", game: "3.2.0", app: requiredAppSDKVersion},
		{name: "旧 App SDK", game: requiredGameSDKVersion, app: "3.1.0"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			root := t.TempDir()
			bundle := sdkBundle{
				GameSDKVersion: testCase.game,
				AppSDKVersion:  testCase.app,
				Encoding:       "base64",
				Files: map[string]string{
					"playmesh-main.js": encoded(
						`const PLAYMESH_SDK_VERSION = "` +
							testCase.game + `";`,
					),
					"playmesh-app.js": encoded(
						`const PLAYMESH_APP_SDK_VERSION = "` +
							testCase.app + `";`,
					),
					"playmesh-main.d.ts": encoded(
						"declare const playmesh: unknown;",
					),
					"playmesh-app.d.ts": encoded(
						"declare const playmeshApp: unknown;",
					),
				},
			}
			_, err := installSDK(root, bundle)
			if err == nil || !strings.Contains(err.Error(), "版本不受支持") {
				t.Fatalf("非当前 SDK 必须被拒绝，得到 %v", err)
			}
			if _, statErr := os.Stat(
				filepath.Join(root, "playmesh", "sdk"),
			); !errors.Is(statErr, os.ErrNotExist) {
				t.Fatalf("拒绝的 SDK 不得写入项目: %v", statErr)
			}
		})
	}
}

func TestPackagePolicyRequiresExplicitCurrentRuntimeContract(t *testing.T) {
	cases := []struct {
		name      string
		configure func(map[string]any)
		want      string
	}{
		{
			name: "缺少 Game SDK 版本",
			configure: func(manifest map[string]any) {
				delete(manifest, "sdkVersion")
			},
			want: "main.json.sdkVersion 必须显式声明为 4.0.0",
		},
		{
			name: "旧 Game SDK 版本",
			configure: func(manifest map[string]any) {
				manifest["sdkVersion"] = "3.2.0"
			},
			want: "main.json.sdkVersion 必须显式声明为 4.0.0",
		},
		{
			name: "缺少 App SDK 版本",
			configure: func(manifest map[string]any) {
				delete(manifest, "appSdkVersion")
			},
			want: "main.json.appSdkVersion 必须显式声明为 3.2.0",
		},
		{
			name: "旧 App SDK 版本",
			configure: func(manifest map[string]any) {
				manifest["appSdkVersion"] = "3.1.0"
			},
			want: "main.json.appSdkVersion 必须显式声明为 3.2.0",
		},
		{
			name: "缺少游戏入口",
			configure: func(manifest map[string]any) {
				delete(manifest, "entries")
			},
			want: "main.json 缺少 entries.game",
		},
		{
			name: "游戏入口必须是 HTML",
			configure: func(manifest map[string]any) {
				manifest["entries"] = map[string]any{
					"game": "game.js",
				}
			},
			want: "main.json.entries.game 必须指向 HTML 文件",
		},
		{
			name: "游戏入口不得静默清理空白",
			configure: func(manifest map[string]any) {
				manifest["entries"] = map[string]any{
					"game": " index.html ",
				}
			},
			want: "main.json.entries.game 不得包含首尾空白",
		},
		{
			name: "控制器入口必须是 HTML",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
				manifest["displayModes"] = []string{
					"single_screen_multiplayer",
				}
				manifest["entries"] = map[string]any{
					"game":       "index.html",
					"controller": "controller.css",
				}
				manifest["authority"] = map[string]any{
					"entry": "authority.js",
				}
			},
			want: "main.json.entries.controller 必须指向 HTML 文件",
		},
		{
			name: "Authority 入口必须是 JavaScript",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
				manifest["authority"] = map[string]any{
					"entry": "authority.html",
				}
			},
			want: "main.json.authority.entry 必须指向 JavaScript 文件",
		},
		{
			name: "单屏多人缺少控制器入口",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
				manifest["displayModes"] = []string{
					"single_screen_multiplayer",
				}
				manifest["authority"] = map[string]any{
					"entry": "authority.js",
				}
			},
			want: "single_screen_multiplayer 缺少 main.json.entries.controller",
		},
		{
			name: "多人游戏缺少 Authority 入口",
			configure: func(manifest map[string]any) {
				manifest["modes"] = []string{"multiplayer"}
			},
			want: "多人游戏缺少 main.json.authority.entry",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			root := t.TempDir()
			manifest := map[string]any{
				"id":            "com.example.contract",
				"sdkVersion":    requiredGameSDKVersion,
				"appSdkVersion": requiredAppSDKVersion,
				"modes":         []string{"solo"},
				"displayModes":  []string{"multi_screen"},
				"entries": map[string]any{
					"game": "index.html",
				},
			}
			testCase.configure(manifest)
			encoded, err := json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			writeTestFile(
				t,
				filepath.Join(root, "main.json"),
				string(encoded),
			)
			_, _, err = loadPackageManifestLayout(root, false)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("严格运行时契约未被拒绝，得到 %v", err)
			}
		})
	}
}

func TestBuildPackageExcludesPlaymeshSDK(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"},"permissions":["keyboard"],"icon":"app/legacy.png","redundant":true}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-main.js"), "private")
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	paths := map[string]bool{}
	var packedManifest map[string]any
	for _, entry := range reader.File {
		paths[entry.Name] = true
		if entry.Name == "main.json" {
			stream, err := entry.Open()
			if err != nil {
				t.Fatal(err)
			}
			if err := json.NewDecoder(stream).Decode(&packedManifest); err != nil {
				stream.Close()
				t.Fatal(err)
			}
			stream.Close()
		}
	}
	if !paths["main.json"] || !paths["capabilities.json"] ||
		!paths[rootIconName] || !paths["app/index.html"] {
		t.Fatalf("package is incomplete: %#v", paths)
	}
	if paths["playmesh/sdk/playmesh-main.js"] {
		t.Fatal("local SDK must never enter the package")
	}
	if _, exists := packedManifest["permissions"]; exists {
		t.Fatalf("removed permissions field entered package: %#v", packedManifest)
	}
	if _, exists := packedManifest["icon"]; exists {
		t.Fatalf("unknown field entered package: %#v", packedManifest)
	}
	if _, exists := packedManifest["redundant"]; exists {
		t.Fatalf("ordinary unknown field entered package: %#v", packedManifest)
	}
}

func TestBuildPackageAllowsMissingCapabilities(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.optional","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`,
	)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")

	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	paths := make(map[string]bool, len(reader.File))
	for _, entry := range reader.File {
		paths[entry.Name] = true
	}
	if !paths["main.json"] || !paths["app/index.html"] {
		t.Fatalf("package is incomplete: %#v", paths)
	}
	if paths["capabilities.json"] {
		t.Fatal("missing optional capabilities.json must not be synthesized")
	}
}

func TestDevelopmentBasePackageAllowsMissingCapabilities(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.dev-optional","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`,
	)

	data, gameID, err := buildDevelopmentBasePackage(root, "")
	if err != nil {
		t.Fatal(err)
	}
	if gameID != "com.example.dev-optional" {
		t.Fatalf("unexpected game ID %q", gameID)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	paths := make(map[string]bool, len(reader.File))
	for _, entry := range reader.File {
		paths[entry.Name] = true
	}
	if !paths["main.json"] || !paths["app/index.html"] {
		t.Fatalf("development base package is incomplete: %#v", paths)
	}
	if paths["capabilities.json"] {
		t.Fatal("development base must not synthesize capabilities.json")
	}
}

func TestPackageBuildersIgnoreEntriesThatDoNotApplyToSoloGames(t *testing.T) {
	builders := []struct {
		name string
		run  func(string) ([]byte, error)
	}{
		{
			name: "formal",
			run:  Build,
		},
		{
			name: "development",
			run: func(root string) ([]byte, error) {
				data, _, err := BuildDevelopmentBase(root, "")
				return data, err
			},
		},
	}
	for _, builder := range builders {
		t.Run(builder.name, func(t *testing.T) {
			root := t.TempDir()
			writeTestFile(
				t,
				filepath.Join(root, "main.json"),
				`{
  "id":"com.example.solo-stale-entries",
  "sdkVersion":"4.0.0",
  "appSdkVersion":"3.2.0",
  "modes":["solo"],
  "displayModes":["multi_screen"],
  "controllerOrientation":"portrait",
  "entries":{
    "game":"index.html",
    "controller":"controller/index.html"
  },
  "authority":{"entry":"authority.js"}
}`,
			)
			writeTestFile(
				t,
				filepath.Join(root, "app", "index.html"),
				"<!doctype html>",
			)

			data, err := builder.run(root)
			if err != nil {
				t.Fatal(err)
			}
			reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
			if err != nil {
				t.Fatal(err)
			}
			var archivedManifest map[string]any
			for _, entry := range reader.File {
				if entry.Name != "main.json" {
					continue
				}
				file, openErr := entry.Open()
				if openErr != nil {
					t.Fatal(openErr)
				}
				decodeErr := json.NewDecoder(file).Decode(&archivedManifest)
				_ = file.Close()
				if decodeErr != nil {
					t.Fatal(decodeErr)
				}
			}
			entries, _ := archivedManifest["entries"].(map[string]any)
			if _, exists := entries["controller"]; exists {
				t.Fatalf("solo package kept controller entry: %#v", entries)
			}
			if _, exists := archivedManifest["controllerOrientation"]; exists {
				t.Fatalf("solo package kept controller orientation: %#v", archivedManifest)
			}
			if _, exists := archivedManifest["authority"]; exists {
				t.Fatalf("solo package kept authority entry: %#v", archivedManifest)
			}
		})
	}
}

func TestPackageBuildersValidatePresentCapabilities(t *testing.T) {
	for _, build := range []struct {
		name string
		run  func(string) error
	}{
		{
			name: "formal",
			run: func(root string) error {
				_, err := buildPackage(root)
				return err
			},
		},
		{
			name: "development",
			run: func(root string) error {
				_, _, err := buildDevelopmentBasePackage(root, "")
				return err
			},
		},
	} {
		t.Run(build.name, func(t *testing.T) {
			root := t.TempDir()
			writeTestFile(
				t,
				filepath.Join(root, "main.json"),
				`{"id":"com.example.invalid-capabilities","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`,
			)
			writeTestFile(
				t,
				filepath.Join(root, "app", "index.html"),
				"<!doctype html>",
			)
			writeTestFile(
				t,
				filepath.Join(root, "capabilities.json"),
				"[]",
			)
			if err := build.run(root); err == nil {
				t.Fatal("present invalid capabilities.json must be rejected")
			}
		})
	}
}

func TestBuildPackageIgnoresUnsafeRootIcon(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	writeTestFile(t, filepath.Join(root, rootIconName), "not a png")

	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range reader.File {
		if entry.Name == rootIconName {
			t.Fatal("unsafe icon.png must be ignored instead of entering the package")
		}
	}
}

func TestBuildPackageRejectsRootIconDirectory(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`)
	writeTestFile(t, filepath.Join(root, "capabilities.json"), `{"required":[]}`)
	writeTestFile(t, filepath.Join(root, "app", "index.html"), "<!doctype html>")
	if err := os.Mkdir(filepath.Join(root, rootIconName), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := buildPackage(root); err == nil {
		t.Fatal("icon.png directory must be rejected")
	}
}

func TestBuildPackageRejectsReservedWebRootDirectories(t *testing.T) {
	for _, directory := range []string{
		"playmesh",
		"PLAYMESH",
		"bucket",
		"BuCkEt",
		"%70laymesh",
		"playmesh%2Fassets",
		"assets%2F..%2Fbucket",
	} {
		t.Run(directory, func(t *testing.T) {
			root := t.TempDir()
			writeTestFile(
				t,
				filepath.Join(root, "main.json"),
				`{"id":"com.example.reserved","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`,
			)
			writeTestFile(
				t,
				filepath.Join(root, "capabilities.json"),
				`{"required":[]}`,
			)
			writeTestFile(
				t,
				filepath.Join(root, "app", "index.html"),
				"<!doctype html>",
			)
			writeTestFile(
				t,
				filepath.Join(root, "app", directory, "asset.js"),
				"reserved",
			)
			if _, err := buildPackage(root); err == nil {
				t.Fatalf("reserved directory %q must be rejected", directory)
			}
		})
	}
}

func TestBuildPackageAllowsUserAppDirectoryEntry(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.user-app","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"app/index.html?scene=release%20menu"}}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "capabilities.json"),
		`{"required":[]}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "app", "app", "index.html"),
		"<!doctype html>",
	)

	data, err := buildPackage(root)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	names := make(map[string]struct{}, len(reader.File))
	for _, entry := range reader.File {
		names[entry.Name] = struct{}{}
	}
	if _, exists := names["app/app/index.html"]; !exists {
		t.Fatalf("用户 app/ 目录未进入发布包: %#v", names)
	}
	layout, _, err := loadPackageManifestLayout(root, true)
	if err != nil {
		t.Fatal(err)
	}
	if layout.GameEntry != "app/index.html?scene=release%20menu" {
		t.Fatalf("清单入口被错误改写: %q", layout.GameEntry)
	}
}

func TestBuildDevelopmentBaseKeepsUserAppDirectoryEntry(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.user-app-dev","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"app/index.html?scene=development"}}`,
	)

	data, _, err := BuildDevelopmentBase(root, "")
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range reader.File {
		if entry.Name == "app/app/index.html" {
			return
		}
	}
	t.Fatal("开发基础包缺少 app/app/index.html")
}

func TestBuildDevelopmentBaseOverridesOnlyArchivedGameEntry(t *testing.T) {
	root := t.TempDir()
	mainPath := filepath.Join(root, "main.json")
	original := `{"id":"com.example.cocos-preview","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`
	writeTestFile(t, mainPath, original)

	data, _, err := BuildDevelopmentBase(
		root,
		"preview/session/index.html?scene=current%20scene&debug=1",
	)
	if err != nil {
		t.Fatal(err)
	}
	onDisk, err := os.ReadFile(mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(onDisk) != original {
		t.Fatal("临时开发入口不应修改项目磁盘上的 main.json")
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	var archivedManifest map[string]any
	foundPlaceholder := false
	for _, entry := range reader.File {
		if strings.Contains(entry.Name, "?") {
			t.Fatalf(
				"开发基础包不应把查询参数写入物理 ZIP 路径: %q",
				entry.Name,
			)
		}
		switch entry.Name {
		case "main.json":
			file, openErr := entry.Open()
			if openErr != nil {
				t.Fatal(openErr)
			}
			decodeErr := json.NewDecoder(file).Decode(&archivedManifest)
			_ = file.Close()
			if decodeErr != nil {
				t.Fatal(decodeErr)
			}
		case "app/preview/session/index.html":
			foundPlaceholder = true
		}
	}
	entries, _ := archivedManifest["entries"].(map[string]any)
	if entries["game"] !=
		"preview/session/index.html?scene=current%20scene&debug=1" {
		t.Fatalf("临时入口未写入归档 main.json: %#v", entries)
	}
	if !foundPlaceholder {
		t.Fatal("开发基础包缺少临时入口占位文件")
	}
}

func TestBuildPackageAllowsNestedReservedNames(t *testing.T) {
	root := t.TempDir()
	writeTestFile(
		t,
		filepath.Join(root, "main.json"),
		`{"id":"com.example.nested","sdkVersion":"4.0.0","appSdkVersion":"3.2.0","entries":{"game":"index.html"}}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "capabilities.json"),
		`{"required":[]}`,
	)
	writeTestFile(
		t,
		filepath.Join(root, "app", "index.html"),
		"<!doctype html>",
	)
	writeTestFile(
		t,
		filepath.Join(root, "app", "assets", "playmesh", "asset.js"),
		"allowed",
	)
	if _, err := buildPackage(root); err != nil {
		t.Fatalf("nested reserved name should remain valid: %v", err)
	}
}

func TestExtractProjectPackageKeepsAppDirectory(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, value := range map[string]string{
		"main.json":             `{"id":"com.example.get"}`,
		"app/index.html":        "<!doctype html>",
		"app/app/user-route.js": "window.userRoute = true;",
	} {
		entry, err := writer.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	iconEntry, err := writer.Create(rootIconName)
	if err != nil {
		t.Fatal(err)
	}
	icon := validRootIcon(t)
	if _, err := iconEntry.Write(icon); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "app", "index.html")); err != nil {
		t.Fatalf("package app/ was not extracted to local app/: %v", err)
	}
	if _, err := os.Stat(
		filepath.Join(root, "app", "app", "user-route.js"),
	); err != nil {
		t.Fatalf("用户 app/ 目录未按原路径恢复: %v", err)
	}
	extractedIcon, err := os.ReadFile(filepath.Join(root, rootIconName))
	if err != nil || !bytes.Equal(extractedIcon, icon) {
		t.Fatalf("root icon.png was not preserved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "game")); !os.IsNotExist(err) {
		t.Fatal("local project must not create a game/ compatibility mirror")
	}
	if _, err := os.Stat(filepath.Join(root, "capabilities.json")); !os.IsNotExist(err) {
		t.Fatal("missing optional capabilities.json must not be synthesized")
	}
}

func TestExtractProjectPackageRemovesStaleIconWhenRemoteHasNone(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entry, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(`{"id":"com.example.get"}`)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	writeTestFile(
		t,
		filepath.Join(root, "capabilities.json"),
		`{"required":["stale"]}`,
	)
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, rootIconName)); !os.IsNotExist(err) {
		t.Fatal("get without icon.png must remove the stale local icon")
	}
	if _, err := os.Stat(filepath.Join(root, "capabilities.json")); !os.IsNotExist(err) {
		t.Fatal("get without capabilities.json must remove stale local capabilities")
	}
}

func TestExtractProjectPackageIgnoresUnsafeIcon(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for path, value := range map[string]string{
		"main.json":  `{"id":"com.example.get"}`,
		rootIconName: "not a png",
	} {
		entry, err := writer.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write([]byte(value)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	writeTestBytes(t, filepath.Join(root, rootIconName), validRootIcon(t))
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, rootIconName)); !os.IsNotExist(err) {
		t.Fatal("unsafe downloaded icon.png must be ignored and stale content removed")
	}
}

func TestExtractProjectPackageRejectsIconSymlink(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	manifest, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manifest.Write([]byte(`{"id":"com.example.get"}`)); err != nil {
		t.Fatal(err)
	}
	header := &zip.FileHeader{Name: rootIconName, Method: zip.Store}
	header.SetMode(os.ModeSymlink | 0o777)
	link, err := writer.CreateHeader(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := link.Write([]byte("outside.png")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := extractProjectPackage(buffer.Bytes(), t.TempDir()); err == nil {
		t.Fatal("icon.png symlink must be rejected")
	}
}

func TestExtractProjectPackageAllowsBrokenProjectWithoutApp(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entry, err := writer.Create("main.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte(`{"id":"com.example.broken"}`)); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}

	root := t.TempDir()
	if err := extractProjectPackage(buffer.Bytes(), root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "main.json")); err != nil {
		t.Fatalf("broken manifest must remain recoverable: %v", err)
	}
}

func writeTestFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeTestBytes(t *testing.T, path string, value []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, value, 0o644); err != nil {
		t.Fatal(err)
	}
}

func validRootIcon(t *testing.T) []byte {
	t.Helper()
	var buffer bytes.Buffer
	icon := image.NewRGBA(image.Rect(0, 0, 2, 2))
	icon.Set(0, 0, color.RGBA{R: 0x25, G: 0xb8, B: 0x7a, A: 0xff})
	if err := png.Encode(&buffer, icon); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}
