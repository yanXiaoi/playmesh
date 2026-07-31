package script

// JavaScript 与 TypeScript 共用源码、构建和发布包模型。

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/development"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/scaffold"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

const javaScriptPackageJSON = `{
  "name": "playmesh-game",
  "private": true,
  "scripts": {
    "build": "node ./playmesh/build.mjs",
    "dev": "playmesh-cli dev",
    "run": "playmesh-cli run",
    "logs": "playmesh-cli logs",
    "update": "playmesh-cli update"
  }
}
`

const typeScriptPackageJSON = `{
  "name": "playmesh-game",
  "private": true,
  "scripts": {
    "build": "tsc -p tsconfig.json && node ./playmesh/build.mjs",
    "dev": "playmesh-cli dev",
    "run": "playmesh-cli run",
    "logs": "playmesh-cli logs",
    "update": "playmesh-cli update"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
`

const javaScriptConfigJSON = `{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "allowJs": true,
    "checkJs": false
  },
  "include": [
    "src/**/*.js",
    "src/**/*.d.ts",
    "playmesh/sdk/*.d.ts"
  ]
}
`

const typeScriptConfigJSON = `{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM"],
    "strict": false,
    "skipLibCheck": true,
    "noEmit": true
  },
  "include": [
    "src/**/*.ts",
    "src/**/*.d.ts",
    "playmesh/sdk/*.d.ts"
  ]
}
`

const scriptProjectGitIgnore = `node_modules/
playmesh/sdk/
playmesh/package/app/
`

const scriptProjectBuildModule = `import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(fs.readFileSync(path.join(root, "playmesh-cli.json"), "utf8"));
if (config.packageRoot !== "playmesh/package") {
  throw new Error('playmesh-cli.json.packageRoot 必须精确为 "playmesh/package"');
}
if (config.sdkRoot !== "playmesh/sdk") {
  throw new Error('playmesh-cli.json.sdkRoot 必须精确为 "playmesh/sdk"');
}
const integration = config.integration || {};
const language = integration.type;
if (language !== "javascript" && language !== "typescript") {
  throw new Error("playmesh-cli.json.integration.type 必须是 javascript 或 typescript");
}

const source = resolveInside(root, integration.sourceRoot, "integration.sourceRoot");
const packageRoot = resolveInside(root, config.packageRoot, "packageRoot");
const appRoot = path.join(packageRoot, "app");
const destination = resolveInside(
  appRoot,
  integration.outputDirectory,
  "integration.outputDirectory",
);
const staging = destination + ".playmesh-build";
const backup = destination + ".playmesh-backup";
const require = createRequire(import.meta.url);
const ts = language === "typescript" ? require("typescript") : null;

removeTree(staging);
copySource(source, staging);
const entry = resolveWebEntry(integration.entry || "index.html");
const stagedEntry = path.join(staging, entry.replaceAll("/", path.sep));
if (!fs.existsSync(stagedEntry)) {
  throw new Error("src/ 构建结果缺少入口 " + entry);
}
removeTree(backup);
if (fs.existsSync(destination)) fs.renameSync(destination, backup);
try {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.renameSync(staging, destination);
  removeTree(backup);
} catch (error) {
  removeTree(destination);
  if (fs.existsSync(backup)) fs.renameSync(backup, destination);
  throw error;
}
console.log("[Playmesh] 已构建 " + language + " 项目到 " + destination);

function resolveInside(base, relative, field) {
  if (!relative || path.isAbsolute(relative)) {
    throw new Error("playmesh-cli.json." + field + " 必须是相对路径");
  }
  const resolved = path.resolve(base, relative);
  const relation = path.relative(base, resolved);
  if (relation === ".." || relation.startsWith(".." + path.sep)) {
    throw new Error("playmesh-cli.json." + field + " 不能越出项目目录");
  }
  return resolved;
}

function resolveWebEntry(value) {
  if (
    !value ||
    value.startsWith("/") ||
    value.includes("\\") ||
    value.includes("?") ||
    value.includes("#") ||
    value.includes("%")
  ) {
    throw new Error("playmesh-cli.json.integration.entry 无效");
  }
  const segments = value.split("/");
  if (
    segments.some((segment) => !segment || segment === "." || segment === "..") ||
    ["playmesh", "bucket"].includes(segments[0].toLowerCase())
  ) {
    throw new Error("playmesh-cli.json.integration.entry 无效");
  }
  return value;
}

function copySource(from, to) {
  const info = fs.lstatSync(from);
  if (info.isSymbolicLink()) throw new Error("源码目录不允许符号链接: " + from);
  if (!info.isDirectory()) throw new Error("源码路径不是目录: " + from);
  fs.mkdirSync(to, { recursive: true });
  for (const name of fs.readdirSync(from)) {
    const sourcePath = path.join(from, name);
    const destinationPath = path.join(to, name);
    const entry = fs.lstatSync(sourcePath);
    if (entry.isSymbolicLink()) throw new Error("源码目录不允许符号链接: " + sourcePath);
    if (entry.isDirectory()) {
      copySource(sourcePath, destinationPath);
      continue;
    }
    if (!entry.isFile() || name.endsWith(".d.ts")) continue;
    if (language === "typescript" && name.endsWith(".ts")) {
      const result = ts.transpileModule(fs.readFileSync(sourcePath, "utf8"), {
        fileName: sourcePath,
        reportDiagnostics: true,
        compilerOptions: {
          target: ts.ScriptTarget.ES2022,
          module: ts.ModuleKind.ES2022,
          sourceMap: true,
        },
      });
      const errors = (result.diagnostics || []).filter(
        (diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error,
      );
      if (errors.length) {
        throw new Error(
          errors.map((diagnostic) => ts.flattenDiagnosticMessageText(
            diagnostic.messageText,
            "\n",
          )).join("\n"),
        );
      }
      const outputPath = destinationPath.slice(0, -3) + ".js";
      fs.writeFileSync(outputPath, result.outputText, "utf8");
      if (result.sourceMapText) {
        fs.writeFileSync(outputPath + ".map", result.sourceMapText, "utf8");
      }
      continue;
    }
    fs.copyFileSync(sourcePath, destinationPath);
  }
}

function removeTree(target) {
  fs.rmSync(target, { recursive: true, force: true });
}
`

type JavaScript struct{}
type TypeScript struct{}

func (JavaScript) ID() string { return "javascript" }
func (TypeScript) ID() string { return "typescript" }

func (JavaScript) Detect(root string) error {
	return validateNativeProjectRoot(root)
}

func (TypeScript) Detect(root string) error {
	return validateNativeProjectRoot(root)
}

func (JavaScript) Defaults(root string) (scaffold.Defaults, error) {
	return scaffold.Defaults{Name: filepath.Base(filepath.Clean(root))}, nil
}

func (TypeScript) Defaults(root string) (scaffold.Defaults, error) {
	return scaffold.Defaults{Name: filepath.Base(filepath.Clean(root))}, nil
}

func (JavaScript) Configuration(root string) (project.Config, error) {
	return scriptProjectConfiguration(root, "javascript")
}

func (TypeScript) Configuration(root string) (project.Config, error) {
	return scriptProjectConfiguration(root, "typescript")
}

func (JavaScript) ProjectManifestPath(
	value project.Context,
) (string, error) {
	return filepath.Join(value.PackageRoot, "main.json"), nil
}

func (TypeScript) ProjectManifestPath(
	value project.Context,
) (string, error) {
	return filepath.Join(value.PackageRoot, "main.json"), nil
}

func scriptProjectConfiguration(root, language string) (project.Config, error) {
	config := project.Config{
		SchemaVersion: 1,
		PackageRoot:   "playmesh/package",
		SDKRoot:       "playmesh/sdk",
		Integration: &project.IntegrationConfig{
			Type:            language,
			ProjectRoot:     ".",
			SourceRoot:      "src",
			OutputDirectory: ".",
			Entry:           "index.html",
		},
	}
	_, err := project.FromConfig(
		filepath.Clean(root),
		filepath.Join(root, project.ConfigName),
		&config,
	)
	if err != nil {
		return project.Config{}, err
	}
	return config, nil
}

func (JavaScript) Finalize(value project.Context) error {
	return finalizeScriptProject(value, "javascript")
}

func (TypeScript) Finalize(value project.Context) error {
	return finalizeScriptProject(value, "typescript")
}

func (JavaScript) Update(value project.Context) error {
	return updateScriptProject(value, "javascript")
}

func (TypeScript) Update(value project.Context) error {
	return updateScriptProject(value, "typescript")
}

func (JavaScript) PrepareDevelopment(
	ctx context.Context,
	value project.Context,
	args []string,
) (development.Source, error) {
	if len(args) != 0 {
		return nil, errors.New(
			"JavaScript 项目的 playmesh-cli dev 不接受额外参数",
		)
	}
	if err := validateScriptIntegration(value, "javascript"); err != nil {
		return nil, err
	}
	sourceRoot := filepath.Join(value.ProjectRoot, "src")
	entryPath := filepath.Join(
		sourceRoot,
		filepath.FromSlash(value.Config.Integration.Entry),
	)
	if info, err := os.Stat(entryPath); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf(
			"JavaScript 开发源码缺少入口 %s",
			value.Config.Integration.Entry,
		)
	}
	return development.NewStaticSource(sourceRoot, nil)
}

func (TypeScript) PrepareDevelopment(
	ctx context.Context,
	value project.Context,
	args []string,
) (development.Source, error) {
	if len(args) != 0 {
		return nil, errors.New(
			"TypeScript 项目的 playmesh-cli dev 不接受额外参数",
		)
	}
	if err := validateScriptIntegration(value, "typescript"); err != nil {
		return nil, err
	}
	if err := runScriptProjectBuild(ctx, value); err != nil {
		return nil, err
	}
	sourceRoot := filepath.Join(value.ProjectRoot, "src")
	handler, err := development.NewRebuildingHandler(
		sourceRoot,
		value.AppRoot,
		func(buildContext context.Context) error {
			return runScriptProjectBuild(buildContext, value)
		},
	)
	if err != nil {
		return nil, err
	}
	return development.NewStaticSource(value.AppRoot, handler)
}

func (JavaScript) PrepareRelease(
	ctx context.Context,
	value project.Context,
) error {
	if err := validateScriptIntegration(value, "javascript"); err != nil {
		return err
	}
	return runScriptProjectBuild(ctx, value)
}

func (TypeScript) PrepareRelease(
	ctx context.Context,
	value project.Context,
) error {
	if err := validateScriptIntegration(value, "typescript"); err != nil {
		return err
	}
	return runScriptProjectBuild(ctx, value)
}

func finalizeScriptProject(project project.Context, language string) error {
	if err := validateScriptIntegration(project, language); err != nil {
		return err
	}
	for _, name := range []string{".gitignore", "package.json", "jsconfig.json", "tsconfig.json", "src"} {
		if _, err := os.Stat(filepath.Join(project.WorkspaceRoot, name)); err == nil {
			return fmt.Errorf("%s 已存在，拒绝覆盖", name)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := copyPackageAppToSource(project, language); err != nil {
		return err
	}
	var packageJSON, languageConfig string
	var configName string
	if language == "typescript" {
		packageJSON = typeScriptPackageJSON
		languageConfig = typeScriptConfigJSON
		configName = "tsconfig.json"
	} else {
		packageJSON = javaScriptPackageJSON
		languageConfig = javaScriptConfigJSON
		configName = "jsconfig.json"
	}
	if err := fsutil.WriteAtomicFile(
		filepath.Join(project.WorkspaceRoot, "package.json"),
		[]byte(packageJSON),
		0o644,
	); err != nil {
		return err
	}
	if err := fsutil.WriteAtomicFile(
		filepath.Join(project.WorkspaceRoot, configName),
		[]byte(languageConfig),
		0o644,
	); err != nil {
		return err
	}
	if err := fsutil.WriteAtomicFile(
		filepath.Join(project.WorkspaceRoot, ".gitignore"),
		[]byte(scriptProjectGitIgnore),
		0o644,
	); err != nil {
		return err
	}
	if err := updateScriptProject(project, language); err != nil {
		return err
	}
	fmt.Printf("已生成 src/、package.json 和 %s。\n", configName)
	if language == "typescript" {
		fmt.Println("首次使用先执行 npm install；在 IDEA 中运行 npm run dev 即可构建并启动到 App。")
	} else {
		fmt.Println("在 IDEA 中运行 npm run dev 即可构建并启动到 App。")
	}
	return nil
}

func updateScriptProject(project project.Context, language string) error {
	if err := validateScriptIntegration(project, language); err != nil {
		return err
	}
	if err := mergeScriptPackageJSON(project.WorkspaceRoot, language); err != nil {
		return err
	}
	if err := installScriptDeclarations(project); err != nil {
		return err
	}
	if err := fsutil.WriteAtomicFile(
		filepath.Join(project.WorkspaceRoot, "playmesh", "build.mjs"),
		[]byte(scriptProjectBuildModule),
		0o644,
	); err != nil {
		return err
	}
	fmt.Printf("%s 项目构建适配器与 SDK 类型入口已更新。\n", language)
	return nil
}

func mergeScriptPackageJSON(root, language string) error {
	path := filepath.Join(root, "package.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return errors.New("当前原生项目缺少 package.json")
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		return fmt.Errorf("package.json 无效: %w", err)
	}
	scripts, _ := manifest["scripts"].(map[string]any)
	if scripts == nil {
		scripts = map[string]any{}
	}
	build := "node ./playmesh/build.mjs"
	if language == "typescript" {
		build = "tsc -p tsconfig.json && node ./playmesh/build.mjs"
	}
	scripts["build"] = build
	scripts["dev"] = "playmesh-cli dev"
	scripts["run"] = "playmesh-cli run"
	scripts["logs"] = "playmesh-cli logs"
	scripts["update"] = "playmesh-cli update"
	manifest["scripts"] = scripts
	if language == "typescript" {
		dependencies, _ := manifest["devDependencies"].(map[string]any)
		if dependencies == nil {
			dependencies = map[string]any{}
		}
		if _, exists := dependencies["typescript"]; !exists {
			dependencies["typescript"] = "^5.0.0"
		}
		manifest["devDependencies"] = dependencies
	}
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(manifest); err != nil {
		return err
	}
	return fsutil.WriteAtomicFile(path, encoded.Bytes(), 0o644)
}

func validateScriptIntegration(value project.Context, language string) error {
	if value.Config == nil || value.Config.Integration == nil ||
		value.Config.Integration.Type != language {
		return fmt.Errorf("当前配置不是 %s 项目", language)
	}
	if !project.SamePath(value.ProjectRoot, value.WorkspaceRoot) {
		return errors.New("原生项目的 integration.projectRoot 必须是 .")
	}
	if value.Config.Integration.SourceRoot != "src" {
		return errors.New("原生项目的 integration.sourceRoot 必须是 src")
	}
	if value.Config.Integration.OutputDirectory != "." {
		return errors.New("原生项目的 integration.outputDirectory 必须是 .")
	}
	if err := webpath.ValidateWebEntry(
		value.Config.Integration.Entry,
		"playmesh-cli.json.integration.entry",
	); err != nil {
		return err
	}
	return nil
}

func validateNativeProjectRoot(root string) error {
	info, err := os.Stat(root)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("当前路径不是项目目录")
	}
	return nil
}

func runScriptProjectBuild(
	ctx context.Context,
	project project.Context,
) error {
	command := exec.CommandContext(
		ctx,
		"node",
		filepath.Join(project.WorkspaceRoot, "playmesh", "build.mjs"),
	)
	command.Dir = project.WorkspaceRoot
	output, err := command.CombinedOutput()
	if err != nil {
		message := strings.TrimSpace(string(output))
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("原生项目正式构建失败: %s", message)
	}
	return nil
}

func copyPackageAppToSource(project project.Context, language string) error {
	sourceRoot := filepath.Join(project.PackageRoot, "app")
	targetRoot := filepath.Join(project.WorkspaceRoot, "src")
	return copyPackageAppToDirectory(sourceRoot, targetRoot, language)
}

func copyPackageAppToDirectory(sourceRoot, targetRoot, language string) error {
	info, err := os.Stat(sourceRoot)
	if err != nil {
		return fmt.Errorf("Playmesh 模板缺少 app/: %w", err)
	}
	if !info.IsDir() {
		return errors.New("Playmesh 模板的 app 不是目录")
	}
	return filepath.WalkDir(sourceRoot, func(source string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(sourceRoot, source)
		if err != nil {
			return err
		}
		if relative == "." {
			return os.MkdirAll(targetRoot, 0o755)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("项目模板不允许符号链接: %s", relative)
		}
		destination := filepath.Join(targetRoot, relative)
		if entry.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		if language == "typescript" && strings.EqualFold(filepath.Ext(destination), ".js") {
			destination = strings.TrimSuffix(destination, filepath.Ext(destination)) + ".ts"
		}
		data, err := os.ReadFile(source)
		if err != nil {
			return err
		}
		return fsutil.WriteAtomicFile(destination, data, 0o644)
	})
}

func installScriptDeclarations(value project.Context) error {
	sourceRoot, err := project.ResolveRelativePath(
		value.WorkspaceRoot,
		value.Config.Integration.SourceRoot,
		"integration.sourceRoot",
	)
	if err != nil {
		return err
	}
	game, err := filepath.Rel(
		sourceRoot,
		filepath.Join(value.SDKRoot, "playmesh-main.d.ts"),
	)
	if err != nil {
		return err
	}
	app, err := filepath.Rel(sourceRoot, filepath.Join(value.SDKRoot, "playmesh-app.d.ts"))
	if err != nil {
		return err
	}
	content := fmt.Sprintf(
		"/// <reference path=%q />\n/// <reference path=%q />\n",
		filepath.ToSlash(game),
		filepath.ToSlash(app),
	)
	return fsutil.WriteAtomicFile(
		filepath.Join(sourceRoot, "playmesh-env.d.ts"),
		[]byte(content),
		0o644,
	)
}
