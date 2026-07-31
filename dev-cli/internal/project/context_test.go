package project

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/contract"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/testutil"
)

func writeTestFile(t *testing.T, path, value string) {
	t.Helper()
	testutil.WriteFile(t, path, value)
}

func TestResolveProjectContextRejectsLegacyLayoutWithoutConfig(t *testing.T) {
	root := t.TempDir()
	_, err := Resolve(root)
	if err == nil || !strings.Contains(err.Error(), "playmesh-cli init") {
		t.Fatalf("legacy config-free layout must be rejected, got %v", err)
	}
}

func TestResolveProjectContextUsesConfiguredRoots(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, ConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "cocos",
	    "projectRoot": ".",
	    "platform": "web-mobile",
	    "outputDirectory": ".",
	    "entry": "index.html",
	    "autoRunAfterBuild": true
	  }
	}`)
	project, err := Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if project.PackageRoot != filepath.Join(root, "playmesh", "package") ||
		project.SDKRoot != filepath.Join(root, "playmesh", "sdk") {
		t.Fatalf("configured roots were not resolved: %#v", project)
	}
	if project.Config == nil || project.Config.Integration == nil ||
		project.Config.Integration.Type != "cocos" {
		t.Fatalf("integration config missing: %#v", project.Config)
	}
}

func TestResolveProjectContextRejectsEveryAlternativeRoot(t *testing.T) {
	cases := []struct {
		name        string
		packageRoot string
		sdkRoot     string
		field       string
	}{
		{"escaping package", "../outside", contract.SDKRoot, "packageRoot"},
		{"legacy root package", ".", contract.SDKRoot, "packageRoot"},
		{"equivalent package", "playmesh/./package", contract.SDKRoot, "packageRoot"},
		{"package trailing slash", "playmesh/package/", contract.SDKRoot, "packageRoot"},
		{"package wrong case", "Playmesh/package", contract.SDKRoot, "packageRoot"},
		{"alternative sdk", contract.PackageRoot, "sdk", "sdkRoot"},
		{"equivalent sdk", contract.PackageRoot, "playmesh/./sdk", "sdkRoot"},
		{"sdk trailing slash", contract.PackageRoot, "playmesh/sdk/", "sdkRoot"},
		{"sdk wrong case", contract.PackageRoot, "playmesh/SDK", "sdkRoot"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			root := t.TempDir()
			config := Config{
				SchemaVersion: 1,
				PackageRoot:   testCase.packageRoot,
				SDKRoot:       testCase.sdkRoot,
			}
			if err := WriteConfig(root, config); err != nil {
				t.Fatal(err)
			}
			_, err := Resolve(root)
			if err == nil ||
				!strings.Contains(err.Error(), testCase.field+" 必须精确为") {
				t.Fatalf("alternative root must be rejected, got %v", err)
			}
		})
	}
}

func TestResolveProjectContextRejectsUnsafeIntegrationPaths(t *testing.T) {
	cases := map[string]struct {
		output string
		entry  string
	}{
		"escaping output": {"../outside", "index.html"},
		"absolute entry":  {".", "/index.html"},
		"reserved entry":  {".", "PLAYMESH/index.html"},
		"encoded entry":   {".", "%70laymesh/index.html"},
		"empty segment":   {".", "assets//index.html"},
		"query entry":     {".", "index.html?debug=1"},
		"reserved output": {"bucket/build", "index.html"},
	}
	for name, testCase := range cases {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			config := Config{
				SchemaVersion: 1,
				PackageRoot:   "playmesh/package",
				SDKRoot:       "playmesh/sdk",
				Integration: &IntegrationConfig{
					Type:            "javascript",
					ProjectRoot:     ".",
					SourceRoot:      "src",
					OutputDirectory: testCase.output,
					Entry:           testCase.entry,
				},
			}
			if err := WriteConfig(root, config); err != nil {
				t.Fatal(err)
			}
			if _, err := Resolve(root); err == nil {
				t.Fatalf(
					"unsafe output=%q entry=%q must be rejected",
					testCase.output,
					testCase.entry,
				)
			}
		})
	}
}

func TestResolveProjectContextAllowsUserAppDirectory(t *testing.T) {
	root := t.TempDir()
	config := Config{
		SchemaVersion: 1,
		PackageRoot:   contract.PackageRoot,
		SDKRoot:       contract.SDKRoot,
		Integration: &IntegrationConfig{
			Type:            "cocos",
			ProjectRoot:     ".",
			Platform:        "web-mobile",
			OutputDirectory: "app",
			Entry:           "app/index.html",
		},
	}
	if err := WriteConfig(root, config); err != nil {
		t.Fatal(err)
	}

	project, err := Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if project.Config.Integration.OutputDirectory != "app" ||
		project.Config.Integration.Entry != "app/index.html" {
		t.Fatalf("用户 app/ 目录配置未被保留: %#v", project.Config.Integration)
	}
}

func TestResolveProjectContextAppliesNewWebRootDefaults(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, ConfigName), `{
	  "schemaVersion": 1,
	  "packageRoot": "playmesh/package",
	  "sdkRoot": "playmesh/sdk",
	  "integration": {
	    "type": "javascript",
	    "sourceRoot": "src"
	  }
	}`)
	project, err := Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if project.Config.Integration.OutputDirectory != "." ||
		project.Config.Integration.Entry != "index.html" ||
		project.Config.Integration.ProjectRoot != "." {
		t.Fatalf("new path defaults were not applied: %#v", project.Config)
	}
	if project.AppRoot != filepath.Join(
		root,
		"playmesh",
		"package",
		"app",
	) {
		t.Fatalf("unexpected app root: %s", project.AppRoot)
	}
}

func TestEnsureProjectNotInitializedRejectsConfigAndPlaymeshManifest(t *testing.T) {
	t.Run("config", func(t *testing.T) {
		root := t.TempDir()
		writeTestFile(t, filepath.Join(root, ConfigName), "{}")
		if err := EnsureNotInitialized(root); err == nil ||
			!strings.Contains(err.Error(), "已经执行过") {
			t.Fatalf("expected initialized error, got %v", err)
		}
	})
	t.Run("native manifest", func(t *testing.T) {
		root := t.TempDir()
		writeTestFile(t, filepath.Join(root, "main.json"), `{"id":"com.example.game"}`)
		if err := EnsureNotInitialized(root); err == nil ||
			!strings.Contains(err.Error(), "已经是 Playmesh") {
			t.Fatalf("expected Playmesh project error, got %v", err)
		}
	})
	t.Run("manifest directory", func(t *testing.T) {
		root := t.TempDir()
		if err := os.Mkdir(filepath.Join(root, "main.json"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := EnsureNotInitialized(root); err == nil ||
			!strings.Contains(err.Error(), "已经是 Playmesh") {
			t.Fatalf("manifest path of any type must be rejected, got %v", err)
		}
	})
	t.Run("isolated manifest", func(t *testing.T) {
		root := t.TempDir()
		writeTestFile(
			t,
			filepath.Join(root, "playmesh", "package", "main.json"),
			`{"id":"com.example.game"}`,
		)
		if err := EnsureNotInitialized(root); err == nil {
			t.Fatal("isolated Playmesh package must be rejected")
		}
	})
	t.Run("new project", func(t *testing.T) {
		root := t.TempDir()
		if err := os.MkdirAll(filepath.Join(root, "assets"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := EnsureNotInitialized(root); err != nil {
			t.Fatalf("new project was rejected: %v", err)
		}
	})
}
