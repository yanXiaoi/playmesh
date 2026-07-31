package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/adapter"
	adapterregistry "github.com/yanXiaoi/playmesh/dev-cli/internal/adapter/registry"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
)

func adapterForProject(value project.Context) (adapter.Adapter, error) {
	return adapterRegistry.ForProject(value)
}

var adapterRegistry = adapterregistry.Default()

func commandInit(ctx context.Context, args []string) error {
	return commandInitFrom(ctx, args, os.Stdin)
}

func commandInitFrom(ctx context.Context, args []string, input io.Reader) error {
	if len(args) == 0 {
		return commandInitNativeFrom(ctx, input)
	}
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
		names := adapterRegistry.PlatformIDs()
		return fmt.Errorf(
			"用法：playmesh-cli init [平台]；不指定平台时初始化原生项目；可用平台：%s",
			strings.Join(names, ", "),
		)
	}
	adapterID := strings.ToLower(strings.TrimSpace(args[0]))
	if !adapterRegistry.IsPlatform(adapterID) {
		return fmt.Errorf("未知项目平台 %q", adapterID)
	}
	adapter, _ := adapterRegistry.Lookup(adapterID)
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	if err := project.EnsureNotInitialized(root); err != nil {
		return err
	}
	if err := adapter.Detect(root); err != nil {
		return err
	}
	defaults, err := adapter.Defaults(root)
	if err != nil {
		return err
	}
	fmt.Printf("初始化 %s 适配器；直接按回车使用方括号中的默认值。\n", adapter.ID())
	if defaults.Name != "" {
		fmt.Printf("已识别项目名称：%s\n", defaults.Name)
	}
	config, err := adapter.Configuration(root)
	if err != nil {
		return err
	}
	projectContext, err := project.FromConfig(
		filepath.Clean(root),
		filepath.Join(root, project.ConfigName),
		&config,
	)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(projectContext.PackageRoot, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(projectContext.SDKRoot), 0o755); err != nil {
		return err
	}
	if err := ensureCreateDestination(projectContext.PackageRoot); err != nil {
		return err
	}
	if err := createProjectAtWithDefaults(ctx, input, projectContext, defaults); err != nil {
		return err
	}
	if err := project.WriteConfig(root, config); err != nil {
		return err
	}
	if err := adapter.Finalize(projectContext); err != nil {
		return err
	}
	fmt.Printf("%s 项目已接入 Playmesh。\n", adapter.ID())
	return nil
}

func commandInitNativeFrom(ctx context.Context, input io.Reader) error {
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	if err := project.EnsureNotInitialized(root); err != nil {
		return err
	}
	if err := ensureCreateDestination(root); err != nil {
		return err
	}

	reader := bufio.NewReader(input)
	fmt.Println("初始化原生 Playmesh 项目；直接按回车使用方括号中的默认值。")
	adapter, err := promptNativeLanguageAdapter(reader)
	if err != nil {
		return err
	}
	if err := adapter.Detect(root); err != nil {
		return err
	}
	defaults, err := adapter.Defaults(root)
	if err != nil {
		return err
	}
	config, err := adapter.Configuration(root)
	if err != nil {
		return err
	}
	projectContext, err := project.FromConfig(
		filepath.Clean(root),
		filepath.Join(root, project.ConfigName),
		&config,
	)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(projectContext.PackageRoot, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(projectContext.SDKRoot), 0o755); err != nil {
		return err
	}
	if err := createProjectAtWithDefaults(
		ctx,
		reader,
		projectContext,
		defaults,
	); err != nil {
		return err
	}
	if err := project.WriteConfig(root, config); err != nil {
		return err
	}
	if err := adapter.Finalize(projectContext); err != nil {
		return err
	}
	fmt.Printf("%s 原生项目已初始化。\n", adapter.ID())
	return nil
}

func promptNativeLanguageAdapter(reader *bufio.Reader) (adapter.Adapter, error) {
	language, err := promptChoice(
		reader,
		"开发语言",
		[]promptOption{
			{value: "javascript", label: "JavaScript"},
			{value: "typescript", label: "TypeScript"},
		},
		0,
	)
	if err != nil {
		return nil, err
	}
	value, _ := adapterRegistry.Lookup(language)
	return value, nil
}
