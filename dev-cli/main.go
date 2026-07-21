package main

import (
	"context"
	"errors"
	"fmt"
	"os"
)

const cliVersion = "1.1.0"

func main() {
	if err := run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "playmesh-cli:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		printUsage()
		return nil
	}
	switch args[0] {
	case "version", "--version", "-v":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli --version")
		}
		fmt.Printf("playmesh-cli %s\n", cliVersion)
		return nil
	case "to":
		return commandTo(ctx, args[1:])
	case "get":
		return commandGet(ctx, args[1:])
	case "push":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli push")
		}
		_, err := pushProject(ctx)
		return err
	case "dev":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli dev")
		}
		return commandDev(ctx)
	case "sdk":
		if len(args) != 1 {
			return errors.New("用法：playmesh-cli sdk")
		}
		return commandSDK(ctx)
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
  playmesh-cli get <project-id>    拉取项目和统一 SDK
  playmesh-cli sdk                 更新当前项目 SDK
  playmesh-cli push                上传、校验并原子提交，不运行
  playmesh-cli dev                 push 后切换运行项目并附加日志
  playmesh-cli --version           输出 CLI 版本
`)
}
