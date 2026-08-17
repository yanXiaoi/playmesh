package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/packaging"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/project"
	"github.com/yanXiaoi/playmesh/dev-cli/internal/sdk"
)

var convertedJavaScriptEntries = []string{
	project.ConfigName,
	"package.json",
	".gitignore",
	"jsconfig.json",
	"src",
	"playmesh",
}

var localPackageEntries = []string{
	"main.json",
	"app",
	"capabilities.json",
	packaging.RootIconName,
}

func commandConvert(ctx context.Context, args []string) error {
	if len(args) != 0 {
		return errors.New("用法：playmesh-cli convert")
	}
	root, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return err
	}
	if err := validateLocalPackageConversion(root); err != nil {
		return err
	}

	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	bundle, err := sdk.Fetch(ctx, newTargetClient(targetConfig))
	if err != nil {
		return err
	}

	stagingRoot, err := os.MkdirTemp(root, ".playmesh-convert-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stagingRoot)

	adapter, _ := adapterRegistry.Lookup("javascript")
	config, err := adapter.Configuration(stagingRoot)
	if err != nil {
		return err
	}
	stagingContext, err := project.FromConfig(
		stagingRoot,
		filepath.Join(stagingRoot, project.ConfigName),
		&config,
	)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(stagingContext.PackageRoot, 0o755); err != nil {
		return err
	}
	if err := copyLocalPackage(root, stagingContext.PackageRoot); err != nil {
		return err
	}
	versions, err := sdk.InstallAt(stagingContext.SDKRoot, bundle)
	if err != nil {
		return err
	}
	projectID, err := sdk.UpdateManifestVersions(
		stagingContext.PackageRoot,
		versions,
	)
	if err != nil {
		return err
	}
	// SDK 版本升级后再复用正式打包器验证完整包，以兼容 App 中保存的旧版本项目。
	if _, err := packaging.Build(stagingContext.PackageRoot); err != nil {
		return fmt.Errorf("当前 main.json + app/ 项目无效: %w", err)
	}
	layout, _, err := packaging.LoadManifestLayout(
		stagingContext.PackageRoot,
		true,
	)
	if err != nil {
		return err
	}
	config.Integration.Entry = layout.GameEntry
	stagingContext.Config = &config
	if err := project.WriteConfig(stagingRoot, config); err != nil {
		return err
	}
	if err := adapter.Finalize(stagingContext); err != nil {
		return err
	}
	if err := commitLocalPackageConversion(root, stagingRoot); err != nil {
		return err
	}
	fmt.Printf(
		"已将 %s 转换为标准 JavaScript CLI 项目（Game SDK %s，App SDK %s）。\n",
		projectID,
		versions.Game,
		versions.App,
	)
	return nil
}

func copyLocalPackage(sourceRoot, targetRoot string) error {
	for _, name := range localPackageEntries {
		source := filepath.Join(sourceRoot, name)
		if _, err := os.Lstat(source); errors.Is(err, os.ErrNotExist) {
			if name == "main.json" || name == "app" {
				return fmt.Errorf("当前目录缺少 %s", name)
			}
			continue
		} else if err != nil {
			return err
		}
		if err := copyLocalPackageEntry(
			source,
			filepath.Join(targetRoot, name),
		); err != nil {
			return err
		}
	}
	return nil
}

func copyLocalPackageEntry(source, target string) error {
	return filepath.WalkDir(source, func(
		path string,
		entry os.DirEntry,
		walkErr error,
	) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		destination := target
		if relative != "." {
			destination = filepath.Join(target, relative)
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("游戏包不允许符号链接: %s", path)
		}
		if entry.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("游戏包只允许普通文件和目录: %s", path)
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
			return err
		}
		input, err := os.Open(path)
		if err != nil {
			return err
		}
		output, err := os.OpenFile(
			destination,
			os.O_CREATE|os.O_WRONLY|os.O_TRUNC,
			0o644,
		)
		if err != nil {
			_ = input.Close()
			return err
		}
		_, copyErr := io.Copy(output, input)
		closeOutputErr := output.Close()
		closeInputErr := input.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeOutputErr != nil {
			return closeOutputErr
		}
		return closeInputErr
	})
}

func validateLocalPackageConversion(root string) error {
	manifest, err := os.Lstat(filepath.Join(root, "main.json"))
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("当前目录缺少 main.json；请在手工复制出的项目包根目录执行转换")
	}
	if err != nil {
		return err
	}
	if manifest.Mode()&os.ModeSymlink != 0 || !manifest.Mode().IsRegular() {
		return errors.New("main.json 必须是非符号链接的普通文件")
	}
	app, err := os.Lstat(filepath.Join(root, "app"))
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("当前目录缺少 app/；请完整复制 App API 返回的项目包")
	}
	if err != nil {
		return err
	}
	if app.Mode()&os.ModeSymlink != 0 || !app.IsDir() {
		return errors.New("app 必须是非符号链接的目录")
	}
	for _, name := range convertedJavaScriptEntries {
		if _, err := os.Lstat(filepath.Join(root, name)); err == nil {
			return fmt.Errorf("目标 JavaScript 项目文件 %s 已存在，拒绝覆盖", name)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func commitLocalPackageConversion(root, stagingRoot string) error {
	backupRoot, err := os.MkdirTemp(root, ".playmesh-convert-backup-")
	if err != nil {
		return err
	}
	committed := make([]string, 0, len(convertedJavaScriptEntries))
	backedUp := make([]string, 0, len(localPackageEntries))
	rollback := func(commitErr error) error {
		var rollbackErrors []error
		for index := len(committed) - 1; index >= 0; index-- {
			name := committed[index]
			if err := os.Rename(
				filepath.Join(root, name),
				filepath.Join(stagingRoot, name),
			); err != nil {
				rollbackErrors = append(rollbackErrors, err)
			}
		}
		for index := len(backedUp) - 1; index >= 0; index-- {
			name := backedUp[index]
			if err := os.Rename(
				filepath.Join(backupRoot, name),
				filepath.Join(root, name),
			); err != nil {
				rollbackErrors = append(rollbackErrors, err)
			}
		}
		if len(rollbackErrors) != 0 {
			return fmt.Errorf(
				"%w；自动恢复失败，原项目备份保留在 %s: %v",
				commitErr,
				backupRoot,
				errors.Join(rollbackErrors...),
			)
		}
		if err := os.RemoveAll(backupRoot); err != nil {
			return fmt.Errorf("%w；原目录已恢复，但清理暂存备份失败: %v", commitErr, err)
		}
		return commitErr
	}

	for _, name := range localPackageEntries {
		source := filepath.Join(root, name)
		if _, statErr := os.Lstat(source); errors.Is(statErr, os.ErrNotExist) {
			continue
		} else if statErr != nil {
			return statErr
		}
		if err := os.Rename(source, filepath.Join(backupRoot, name)); err != nil {
			return rollback(fmt.Errorf("暂存原项目文件 %s 失败: %w", name, err))
		}
		backedUp = append(backedUp, name)
	}
	for _, name := range convertedJavaScriptEntries {
		if err := os.Rename(
			filepath.Join(stagingRoot, name),
			filepath.Join(root, name),
		); err != nil {
			return rollback(fmt.Errorf("提交 JavaScript 项目文件 %s 失败: %w", name, err))
		}
		committed = append(committed, name)
	}
	if err := os.RemoveAll(backupRoot); err != nil {
		return fmt.Errorf("转换已完成，但清理原项目备份 %s 失败: %w", backupRoot, err)
	}
	return nil
}
