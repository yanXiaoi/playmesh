# Playmesh Developer CLI

`dev-cli` 是 Playmesh 的全局命令行开发工具，使用 Go 标准库实现。它把 IDEA 中的本地目录与已经开启开发者模式的 Playmesh App 连接起来；项目运行仍由目标 App 的 WebView 和本地服务负责。

## 构建与安装

```powershell
cd dev-cli
go test ./...
go build -o playmesh-cli.exe .
```

把生成的可执行文件放入 `PATH` 后即可在任意项目目录调用。CLI 当前版本为 `1.1.0`，可通过 `playmesh-cli --version`、`playmesh-cli -v` 或 `playmesh-cli version` 查看；正式二进制名称固定为 Windows 的 `playmesh-cli.exe` 和 macOS/Linux 的 `playmesh-cli`。

桌面 App 会跟随平台构建自动编译 CLI：Windows 把它放在 `playmesh-core.exe` 同级；Linux 放在 bundle 根目录；macOS 放在 `.app/Contents/MacOS/`。Android/iOS 不携带 CLI。开发者不需要在每次 App 编译后再手工复制文件。

## 工作流

```powershell
playmesh-cli to "http://10.31.2.222:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli get com.example.game
playmesh-cli dev
```

- `playmesh-cli to <workspace-url>`：解析完整工作区链接，校验目标并切换全局目标 App。token 保存在当前用户配置目录的 `Playmesh/cli-target.json`；该文件只应由当前用户读取，不能提交到项目或共享。
- `playmesh-cli get <project-id>`：把项目、当前 SDK 运行文件和类型契约拉到当前目录。非空目录只允许更新相同 `main.json.id` 的项目。
- `playmesh-cli sdk`：获取目标 App 当前唯一的 SDK 版本，不支持指定历史版本，并同步 `main.json` 的两个 SDK 版本字段。
- `playmesh-cli push`：先按本地 SDK 文件重写 `main.json.sdkVersion/appSdkVersion`，再只上传 `main.json`、`capabilities.json` 和 `app/`，校验并原子提交，不启动游戏。
- `playmesh-cli dev`：先输出当前 CLI 版本，再执行 `push`；若另一项目在运行，先关闭它，再运行当前项目；若当前项目已运行则重启。CLI 先回放本次 run 已缓存的早期日志，再并行使用 SSE 与 500 ms 日志轮询持续输出并按 `eventId` 去重，因此 SSE 首字节被缓冲或连接中断也不会阻塞日志；同时轮询运行状态，在目标 WebView 退出后结束。按 `Ctrl+C` 只分离 CLI，不关闭游戏。

拉取后的目录固定为：

```text
main.json
capabilities.json
app/                        # 直接映射运行时 /app/，并按原名上传
playmesh/                   # 映射运行时 /playmesh/，不参与上传
  sdk/
    playmesh.js
    playmesh-app.js
    playmesh.d.ts
    playmesh-app.d.ts
```

CLI 目录刻意镜像运行时 URL 空间：本地和游戏包都使用 `app/`，对应 `/app/...`；本地 `playmesh/` 对应 `/playmesh/...`，其中 SDK 只用于运行文件、类型和中文文档提示，永远不进入上传包。这样 IDEA 可以解析 HTML、JavaScript 和 CSS 中的绝对 `/app/...`、`/playmesh/...` 路径。IDEA 可将 `playmesh/sdk/*.d.ts` 加入 JavaScript Library 或直接纳入项目索引；两个声明文件内置完整中文 JSDoc。

## 发布边界

目标 App 继续复用正式游戏包导入器完成 ZIP 路径安全、文件数/大小、Manifest、能力和入口校验。相同 `main.json.id` 表示更新：只替换 `main.json`、`capabilities.json` 与 `app/`，目标中的 `data/`、`cache/` 及其他运行内容保持原样；失败时恢复原发布文件。不同 ID 表示新增。
