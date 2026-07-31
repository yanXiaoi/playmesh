package script

// 原生脚本项目测试覆盖 JavaScript 与 TypeScript 共用的目录模型。

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/testutil"
)

func writeTestFile(t *testing.T, path, value string) {
	t.Helper()
	testutil.WriteFile(t, path, value)
}

func TestJavaScriptPackageBuildScriptStagesSource(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not available")
	}
	root := t.TempDir()
	packageRoot := filepath.Join(root, "playmesh", "package")
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{"id":"com.example.javascript"}`)
	writeTestFile(t, filepath.Join(packageRoot, "app", "index.html"), "<title>old</title>")
	writeTestFile(t, filepath.Join(packageRoot, "app", "stale.js"), "stale")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-main.d.ts"), "declare const playmesh: unknown;")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.d.ts"), "declare const playmeshApp: unknown;")

	adapter := JavaScript{}
	config, err := adapter.Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := project.WriteConfig(root, config); err != nil {
		t.Fatal(err)
	}
	projectContext, err := project.Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := adapter.Finalize(projectContext); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "src", "index.html"), "<title>new</title>")
	writeTestFile(t, filepath.Join(root, "src", "main.js"), "console.log('new');")
	if err := os.Remove(filepath.Join(root, "src", "stale.js")); err != nil {
		t.Fatal(err)
	}

	command := exec.Command(node, filepath.Join(root, "playmesh", "build.mjs"))
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("JavaScript build script failed: %v\n%s", err, output)
	}
	index, err := os.ReadFile(filepath.Join(packageRoot, "app", "index.html"))
	if err != nil || string(index) != "<title>new</title>" {
		t.Fatalf("build did not stage new source: %q, %v", index, err)
	}
	if _, err := os.Stat(filepath.Join(packageRoot, "app", "main.js")); err != nil {
		t.Fatalf("build did not copy JavaScript source: %v", err)
	}
	if _, err := os.Stat(filepath.Join(packageRoot, "app", "stale.js")); !os.IsNotExist(err) {
		t.Fatalf("atomic build kept stale output: %v", err)
	}
	if _, err := os.Stat(filepath.Join(packageRoot, "app", "playmesh-env.d.ts")); !os.IsNotExist(err) {
		t.Fatalf("type declarations must not enter the upload package: %v", err)
	}
}

func TestTypeScriptAdapterCreatesSourcesAndBuildConfiguration(t *testing.T) {
	root := t.TempDir()
	packageRoot := filepath.Join(root, "playmesh", "package")
	writeTestFile(t, filepath.Join(packageRoot, "main.json"), `{"id":"com.example.typescript"}`)
	writeTestFile(
		t,
		filepath.Join(packageRoot, "app", "static", "js", "player", "index.js"),
		`import { value } from "../shared/value.js"; console.log(value);`,
	)
	writeTestFile(
		t,
		filepath.Join(packageRoot, "app", "static", "js", "shared", "value.js"),
		`export const value = 1;`,
	)
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-main.d.ts"), "declare const playmesh: unknown;")
	writeTestFile(t, filepath.Join(root, "playmesh", "sdk", "playmesh-app.d.ts"), "declare const playmeshApp: unknown;")

	adapter := TypeScript{}
	config, err := adapter.Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := project.WriteConfig(root, config); err != nil {
		t.Fatal(err)
	}
	projectContext, err := project.Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := adapter.Finalize(projectContext); err != nil {
		t.Fatal(err)
	}

	for _, relative := range []string{
		"package.json",
		"tsconfig.json",
		"src/static/js/player/index.ts",
		"src/static/js/shared/value.ts",
		"src/playmesh-env.d.ts",
		"playmesh/package/app/static/js/player/index.js",
		"playmesh/build.mjs",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(relative))); err != nil {
			t.Fatalf("TypeScript init did not create or preserve %s: %v", relative, err)
		}
	}
	reference, err := os.ReadFile(filepath.Join(root, "src", "playmesh-env.d.ts"))
	if err != nil ||
		!strings.Contains(string(reference), "../playmesh/sdk/playmesh-main.d.ts") {
		t.Fatalf("invalid TypeScript SDK reference: %q, %v", reference, err)
	}
	data, err := os.ReadFile(filepath.Join(root, project.ConfigName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "autoRunAfterBuild") ||
		!strings.Contains(string(data), `"type": "typescript"`) {
		t.Fatalf("unexpected TypeScript project config: %s", data)
	}
}

func TestTypeScriptUpdateRefreshesOnlyGeneratedDeclarationEntry(t *testing.T) {
	root := t.TempDir()
	config, err := (TypeScript{}).Configuration(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := project.WriteConfig(root, config); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(root, "playmesh", "package", "main.json"), `{"id":"com.example.typescript"}`)
	writeTestFile(t, filepath.Join(root, "package.json"), `{"scripts":{"custom":"keep"}}`)
	writeTestFile(t, filepath.Join(root, "tsconfig.json"), `{"compilerOptions":{"strict":true}}`)
	writeTestFile(t, filepath.Join(root, "src", "playmesh-env.d.ts"), "stale")

	projectContext, err := project.Resolve(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := (TypeScript{}).Update(projectContext); err != nil {
		t.Fatal(err)
	}
	packageJSON, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil || !strings.Contains(string(packageJSON), `"custom": "keep"`) ||
		!strings.Contains(string(packageJSON), `"dev": "playmesh-cli dev"`) ||
		!strings.Contains(string(packageJSON), `"run": "playmesh-cli run"`) {
		t.Fatalf("update did not preserve custom scripts while refreshing managed scripts: %q, %v", packageJSON, err)
	}
	tsconfig, err := os.ReadFile(filepath.Join(root, "tsconfig.json"))
	if err != nil || string(tsconfig) != `{"compilerOptions":{"strict":true}}` {
		t.Fatalf("update overwrote tsconfig.json: %q, %v", tsconfig, err)
	}
	reference, err := os.ReadFile(filepath.Join(root, "src", "playmesh-env.d.ts"))
	if err != nil || strings.Contains(string(reference), "stale") {
		t.Fatalf("update did not refresh declaration entry: %q, %v", reference, err)
	}
}
