package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/yanXiaoi/playmesh/dev-cli/internal/buildinfo"
)

func Run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		printUsage()
		return nil
	}
	switch args[0] {
	case "version", "--version", "-v":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli --version")
		}
		fmt.Printf("playmesh-cli %s\n", buildinfo.Version)
		return nil
	case "to":
		return commandTo(ctx, args[1:])
	case "get":
		return commandGet(ctx, args[1:])
	case "init":
		return commandInit(ctx, args[1:])
	case "run":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli run")
		}
		return commandRun(ctx)
	case "logs":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli logs")
		}
		return commandLogs(ctx)
	case "dev":
		return commandDev(ctx, args[1:])
	case "capabilities":
		if len(args) != 2 || args[1] != "--json" {
			return errors.New("用法：playmesh-cli capabilities --json")
		}
		return commandCapabilities(ctx, os.Stdout)
	case "configure":
		return commandConfigure(ctx, args[1:])
	case "update":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli update")
		}
		return commandUpdate(ctx)
	case "help", "--help", "-h":
		printUsage()
		return nil
	default:
		return fmt.Errorf("未知命令 %q；使用 playmesh-cli help 查看帮助", args[0])
	}
}

func printUsage() {
	fmt.Print(`Playmesh developer CLI

用法：
  playmesh-cli to <workspace-url>  连接并切换目标 App
  playmesh-cli get <project-id>    将 App 发布包恢复为 JavaScript 工程
  playmesh-cli init                初始化原生项目并选择 JavaScript/TypeScript
  playmesh-cli init cocos          初始化当前 Cocos Creator 3.x 项目
  playmesh-cli update              更新 SDK，并由项目适配器升级集成
  playmesh-cli run                 上传、校验并运行，不附加日志
  playmesh-cli logs                实时输出当前项目运行日志
  playmesh-cli dev [adapter-args]  使用适配器准备本地开发资源并在真实 App 中运行
  playmesh-cli capabilities --json 输出目标 App 当前注册的能力目录
  playmesh-cli configure            交互式配置当前项目
  playmesh-cli configure --json     从 stdin 接收 JSON 并全量配置当前项目
  playmesh-cli configure --out      以 JSON 输出当前项目所有可配置项
  playmesh-cli --version           输出 CLI 版本
`)
}

func commandCapabilities(ctx context.Context, output io.Writer) error {
	targetConfig, err := targetStore.Load()
	if err != nil {
		return err
	}
	registry, err := fetchCapabilityRegistry(
		ctx,
		newTargetClient(targetConfig),
	)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(registry)
}
