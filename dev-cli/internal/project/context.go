package project

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/contract"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/fsutil"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/webpath"
)

const ConfigName = contract.ProjectConfigName

type Config struct {
	Schema        string             `json:"$schema,omitempty"`
	SchemaVersion int                `json:"schemaVersion"`
	PackageRoot   string             `json:"packageRoot"`
	SDKRoot       string             `json:"sdkRoot"`
	Integration   *IntegrationConfig `json:"integration,omitempty"`
}

type IntegrationConfig struct {
	Type              string `json:"type"`
	ProjectRoot       string `json:"projectRoot,omitempty"`
	SourceRoot        string `json:"sourceRoot,omitempty"`
	Platform          string `json:"platform,omitempty"`
	OutputDirectory   string `json:"outputDirectory,omitempty"`
	Entry             string `json:"entry,omitempty"`
	AutoRunAfterBuild bool   `json:"autoRunAfterBuild,omitempty"`
	PreviewBridgePort int    `json:"previewBridgePort,omitempty"`
}

type Context struct {
	WorkspaceRoot string
	ProjectRoot   string
	PackageRoot   string
	AppRoot       string
	SDKRoot       string
	ConfigPath    string
	Config        *Config
}

func Current() (Context, error) {
	root, err := os.Getwd()
	if err != nil {
		return Context{}, err
	}
	return Resolve(root)
}

func Resolve(root string) (Context, error) {
	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return Context{}, err
	}
	absoluteRoot = filepath.Clean(absoluteRoot)
	configPath := filepath.Join(absoluteRoot, ConfigName)
	data, err := os.ReadFile(configPath)
	if errors.Is(err, os.ErrNotExist) {
		return Context{}, errors.New(
			"当前目录缺少 playmesh-cli.json；新项目请执行 playmesh-cli init，旧 JavaScript 项目请在空目录执行 playmesh-cli get",
		)
	}
	if err != nil {
		return Context{}, err
	}
	var config Config
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return Context{}, fmt.Errorf("%s 无效: %w", ConfigName, err)
	}
	ApplyDefaults(&config)
	return FromConfig(absoluteRoot, configPath, &config)
}

func ApplyDefaults(config *Config) {
	if config == nil || config.Integration == nil {
		return
	}
	if strings.TrimSpace(config.Integration.ProjectRoot) == "" {
		config.Integration.ProjectRoot = "."
	}
	if strings.TrimSpace(config.Integration.OutputDirectory) == "" {
		config.Integration.OutputDirectory = "."
	}
	if strings.TrimSpace(config.Integration.Entry) == "" {
		config.Integration.Entry = "index.html"
	}
}

func FromConfig(
	root, configPath string,
	config *Config,
) (Context, error) {
	ApplyDefaults(config)
	if config.SchemaVersion != 1 {
		return Context{}, fmt.Errorf(
			"%s.schemaVersion 必须是 1",
			ConfigName,
		)
	}
	if config.PackageRoot != contract.PackageRoot {
		return Context{}, fmt.Errorf(
			"%s.packageRoot 必须精确为 %q",
			ConfigName,
			contract.PackageRoot,
		)
	}
	if config.SDKRoot != contract.SDKRoot {
		return Context{}, fmt.Errorf(
			"%s.sdkRoot 必须精确为 %q",
			ConfigName,
			contract.SDKRoot,
		)
	}
	packageRoot, err := ResolveRelativePath(root, config.PackageRoot, "packageRoot")
	if err != nil {
		return Context{}, err
	}
	sdkRoot, err := ResolveRelativePath(root, config.SDKRoot, "sdkRoot")
	if err != nil {
		return Context{}, err
	}
	if err := webpath.RejectSymlinkPath(root, packageRoot); err != nil {
		return Context{}, err
	}
	if err := webpath.RejectSymlinkPath(root, sdkRoot); err != nil {
		return Context{}, err
	}
	if SamePath(packageRoot, root) {
		return Context{}, errors.New(
			"CLI 2.0 的 playmesh-cli.json.packageRoot 必须与项目根隔离",
		)
	}
	if SamePath(sdkRoot, root) {
		return Context{}, errors.New(
			"CLI 2.0 的 playmesh-cli.json.sdkRoot 必须与项目根隔离",
		)
	}
	if SamePath(packageRoot, sdkRoot) {
		return Context{}, errors.New("playmesh-cli.json 的 packageRoot 与 sdkRoot 不能相同")
	}
	if pathContains(packageRoot, sdkRoot) || pathContains(sdkRoot, packageRoot) {
		return Context{}, errors.New(
			"playmesh-cli.json 的 packageRoot 与 sdkRoot 不能互相包含",
		)
	}
	projectRoot := root
	if config.Integration != nil {
		if strings.TrimSpace(config.Integration.Type) == "" {
			return Context{}, errors.New(
				"playmesh-cli.json.integration.type 不能为空",
			)
		}
		projectRoot, err = ResolveRelativePath(
			root,
			config.Integration.ProjectRoot,
			"integration.projectRoot",
		)
		if err != nil {
			return Context{}, err
		}
		if err := webpath.RejectSymlinkPath(root, projectRoot); err != nil {
			return Context{}, err
		}
		if _, err := webpath.ResolveAppOutputDirectory(
			filepath.Join(packageRoot, "app"),
			config.Integration.OutputDirectory,
		); err != nil {
			return Context{}, err
		}
		if err := webpath.ValidateWebEntry(
			config.Integration.Entry,
			"playmesh-cli.json.integration.entry",
		); err != nil {
			return Context{}, err
		}
	}
	return Context{
		WorkspaceRoot: root,
		ProjectRoot:   projectRoot,
		PackageRoot:   packageRoot,
		AppRoot:       filepath.Join(packageRoot, "app"),
		SDKRoot:       sdkRoot,
		ConfigPath:    configPath,
		Config:        config,
	}, nil
}

func ResolveRelativePath(root, value, field string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("playmesh-cli.json.%s 不能为空", field)
	}
	if filepath.IsAbs(value) {
		return "", fmt.Errorf("playmesh-cli.json.%s 必须是项目内相对路径", field)
	}
	resolved := filepath.Clean(filepath.Join(root, filepath.FromSlash(value)))
	relative, err := filepath.Rel(root, resolved)
	if err != nil {
		return "", err
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("playmesh-cli.json.%s 不能越出项目目录", field)
	}
	return resolved, nil
}

func SamePath(first, second string) bool {
	return strings.EqualFold(filepath.Clean(first), filepath.Clean(second))
}

func pathContains(parent, child string) bool {
	relative, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(child))
	if err != nil || relative == "." {
		return false
	}
	return relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(os.PathSeparator))
}

func WriteConfig(root string, config Config) error {
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	path := filepath.Join(root, ConfigName)
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o644); err != nil {
		return err
	}
	return fsutil.ReplaceFile(temporary, path)
}
