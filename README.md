# Playmesh

Playmesh 1.0 是一个局域网优先的 HTML 游戏平台。Flutter App 负责游戏库、用户资料、会话与 WebView 容器，Go Core 负责本机联机会话，Game SDK 为单机与多人游戏提供统一能力。

## 产品能力

- 导入、导出和管理根目录包含 `main.json` 的 Playmesh 游戏包。
- 创建或加入局域网对局，支持邀请二维码与浏览器控制器。
- 游戏与控制器 HTML 立即加载；应用会尝试进入全屏，也允许玩家保持窗口模式，全屏失败只提示而不阻断游戏。
- Android 可从系统“打开方式/分享至”接收 Playmesh 压缩包或单个 HTML；压缩包进入安装流程，HTML 在不注入 SDK 的独立 WebView 中运行。
- 为 HTML/CSS/JavaScript 游戏提供存储、生命周期、状态同步与性能接口。
- 提供适配桌面与移动端的网页开发者工作台，包含文件管理、代码编辑、Diff、日志、校验、运行、AI 接口文档和可选择局域网地址的项目 Agent 提示词。
- 提供 Go 编写的 `playmesh-cli`，可交互式创建项目，或在 IDEA 中拉取项目与同源 SDK 类型，整包发布到目标 App，并在 App WebView 中运行和跟随日志；Windows、Linux、macOS 桌面构建会自动携带对应平台二进制。
- 用户资料、开发者工作区配置和游戏数据均保存在本机。

## 开始使用

```powershell
flutter pub get
flutter run
```

游戏作者从 [游戏开发文档](docs/game/README.md) 开始。开发环境与工程约束见 [开发环境记录](docs/04-dev-env.md) 和 [工程规范](docs/06-engineering-standards.md)。

统一发布脚本支持 `harmony`、`android`、`windows` 和 `all` 目标；鸿蒙构建会把 OpenHarmony arm64 Go Core 与 N-API 桥一并写入 HAP。运行时目录、签名方式和验证项见 [HarmonyOS 构建与适配](docs/harmony-release.md)。

外部 IDE 开发从 [Developer CLI](dev-cli/README.md) 开始。先在 App 开启开发者模式并复制完整工作区链接，再执行 `playmesh-cli to <workspace-url>`；CLI 会自行解析地址与 token。进入空目录后可执行 `playmesh-cli create` 交互式创建并下载项目。
