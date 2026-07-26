# Playmesh

Playmesh 是一个局域网优先、支持公共中转的跨平台 HTML 游戏平台。Flutter App
负责游戏库、用户资料、会话编排与 WebView 容器；Go Core 负责本机会话和消息路由；
Game SDK 为单机与多人游戏提供权威状态、JSON 消息、二进制 Channel、Bucket 存储
和设备能力；可独立部署的 Go Server 提供轻量游戏包分享、上传、分发与公共联机中转。

游戏只面向稳定的 Game SDK 编程。局域网 App、普通浏览器和公共中转 App 的加载来源、
连接方式与传输安全由平台处理，不进入游戏业务代码。

## 核心能力

- 导入、导出和管理根目录包含 `main.json` 的 Playmesh 游戏包。
- 创建或加入局域网对局，通过二维码、链接或 App 控制器参与游戏。
- 通过轻量 Go Server 分享、上传和下载游戏包，并让不在同一局域网的 App 通过
  公共中转联机；中转只配对并复制端到端加密字节。
- 为 HTML/CSS/JavaScript 游戏提供 Authority、状态同步、生命周期、存储、性能和
  设备能力插件。
- 提供桌面与移动端共用的网页开发者工作区，包含代码编辑、Diff、本地历史、校验、
  运行、日志、AI 对话控制台和 Agent API。
- 提供 Go 编写的 `playmesh-cli`，支持在 IDEA 等外部 IDE 中创建、拉取、发布、
  运行项目并跟随日志。
- 支持 Android、Windows 和 OpenHarmony/HarmonyOS 发布构建；桌面包自动携带
  Go Core 与 Developer CLI。

## 架构概览

```text
Flutter App
  ├─ 游戏库、用户资料、开发者工作区和 WebView 宿主
  ├─ Game SDK / App Bridge SDK
  └─ 平台能力插件
        │
        ▼
Go Core
  ├─ Session WebSocket
  ├─ Binary WebSocket / Channel
  └─ 玩家、Authority、凭证和消息路由
        │
        ▼
HTML Game Runtime
  ├─ Player 页面
  ├─ Authority 规则
  └─ 只通过公开 SDK 使用平台能力

可选 Go Server
  ├─ Catalog / 游戏包分享、上传与分发
  └─ 公共 Relay / 端到端加密字节中转
```

完整边界见[技术架构](docs/01-architecture.md)，工程约束见
[工程开发规范](docs/06-engineering-standards.md)。

## 项目文档与演进

`docs/` 保留了项目从立项、分阶段实现到版本化维护的过程。阶段文档记录当时事实，
版本日志记录阶段制结束后的增量，验证记录只说明已经实际覆盖的层级：

| 内容 | 入口 |
| --- | --- |
| 项目目标、产品边界与当前能力 | [项目上下文](docs/00-context.md) |
| 技术分层、运行时与安全边界 | [技术架构](docs/01-architecture.md) |
| 从立项到各阶段的规划 | [实施路线图](docs/02-roadmap.md) |
| 当前后续事项与人工验收项 | [下一步计划](docs/05-next-steps.md) |
| 第一至第六阶段事实归档 | [阶段状态](docs/status/) |
| 正式版本与下一版本变更 | [版本日志](docs/version/README.md) |
| 自动验证、构建产物与已知边界 | [验证记录](docs/verification/) |

## 开始运行

```powershell
flutter pub get
flutter run
```

常用环境、固定工具链和发布命令见[开发环境记录](docs/04-dev-env.md)。

## 游戏开发

从[游戏开发文档目录](docs/game/README.md)开始，并按开发方式选择入口：

| 开发方式 | 入口 | 适用场景 |
| --- | --- | --- |
| AI 对话 / Agent | [AI 游戏开发](docs/game/ai-development.md) | 使用工作区提示词、对话控制台或 Developer API 生成和迭代游戏 |
| IDEA / CLI | [IDEA 与 CLI 游戏开发](docs/game/idea-cli-development.md) | 在外部 IDE 中编辑本地副本，并发布到目标 App |
| 网页工作区 | [网页开发者通道](docs/game/web-dev-channel.md) | 在 App 或局域网浏览器中编辑、校验、运行和查看日志 |
| 通用契约 | [游戏开发指南](docs/game/development-guide.md) | 理解运行模式、Player/Authority 分层、生命周期和存储 |
| 包格式 | [游戏包与 main.json](docs/game/package-format.md) | 定义目录、清单、能力声明和发布边界 |
| SDK API | [Game SDK / App Bridge SDK](docs/game/sdk-v1.md) | 查询当前公开 API、类型、角色限制和错误语义 |
| 游戏使用设备能力 | [游戏能力使用指南](docs/game/capability-plugins.md) | 声明并调用传感器、震动等平台能力 |

### AI 开发

在 App 设置中开启开发者模式，进入工作区的“AI”页面：

1. 选择或创建游戏项目。
2. 填写公共“自定义想法”。
3. 获取纯聊天提示词，或选择 Agent 可访问的局域网 Base URL 获取 Agent 提示词。
4. 让 AI 修改项目后执行结构化校验、真实运行和日志诊断。

纯聊天 AI 输出的 JSON 指令粘贴到工作区“对话控制台”；Agent 直接调用同一套
Developer Operation API。危险操作统一经过工作区审批。

### IDEA / CLI 开发

先复制 App 显示的完整工作区链接：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli create
playmesh-cli dev
```

已有项目使用 `playmesh-cli get <project-id>`。CLI 的完整命令、目录映射和发布边界见
[Developer CLI](dev-cli/README.md)。

## 平台开发

平台维护者从[平台开发文档目录](docs/platform/README.md)开始：

| 主题 | 文档 | 核心约束 |
| --- | --- | --- |
| 能力插件 | [能力开发约定](docs/platform/capability-development.md) | 描述符、实例生命周期、平台适配、自检和注册只有一份定义 |
| SDK | [SDK 开发约定](docs/platform/sdk-development.md) | TypeScript、类型声明、宿主执行器、兼容发行版和版本执行器同源 |
| 开发者工作区 | [开发者工作区开发约定](docs/platform/developer-workspace-development.md) | Operation Definition 同时驱动路由、文档、权限、审批和 AI 操作目录 |
| Go Server | [Go Server 开发约定](docs/platform/go-server-development.md) | 游戏包源与公共中转共用轻量部署载体，但接口、存储、鉴权和协议版本保持独立 |

新增平台级领域时，在 `docs/platform/` 增加独立约定文档，并同步更新
[平台开发目录](docs/platform/README.md)和本 README。游戏作者文档只描述公开能力，
不得暴露回环代理、中转密钥、内部 Bridge 或 Core 帧格式。

## 仓库结构

```text
lib/                         Flutter App 与平台运行时
  core/                      SDK、能力、网关、存储、会话和开发者服务
  features/                  页面与产品功能
go-core/                     本机会话、JSON/Binary WebSocket 和路由
go-server/                   轻量游戏包分享、上传、Catalog 分发与公共联机中转
dev-cli/                     Go Developer CLI
assets/playmesh-library/     SDK 生成物、开发者工作区和默认游戏模板
docs/game/                   游戏作者文档
docs/platform/               平台维护与扩展约定
docs/status/                 第一至第六阶段事实归档
docs/version/                阶段结束后的版本日志
docs/verification/           自动验证、平台构建和已知边界记录
tool/                        SDK 生成、Core 构建和统一发布脚本
```

## Go Server

`go-server/` 是可选的独立服务，不是 Go Core，也不是游戏权威服务器。它适合部署为
小型公共或团队游戏源，为游戏包分享、上传与下载提供服务，并为跨网络 App 联机提供
临时隧道。只在本机或局域网运行游戏不依赖它。

敏感凭证从 `go-server/.env` 读取，非敏感运行参数由后台表单管理并原子持久化到
`go-server/server.json`。默认 App 外部端口为 `16668`，承载公开门户、上传、
Catalog、已审核下载与 Relay；`16669` 是只承载 `PLAYMESH_ADMIN_PATH` 隐藏后台的
独立管理监听。两者使用独立 Gin Engine，管理页面、脚本、登录和 API 都不会注册到
外部端口。Catalog、游戏包管理和 Relay 的职责边界、安全要求与扩展方式见：

- [Go Server 部署与接口](go-server/README.md)
- [Go Server 开发约定](docs/platform/go-server-development.md)
- [在线游戏源与 Catalog API](docs/catalog-api.md)
- [局域网与公共联机中转](docs/remote-game-relay.md)

## 构建与发布

统一发布入口支持 `harmony`、`android`、`windows` 和 `all`：

```powershell
.\tool\build_release.ps1 -Target all
```

Android/Windows 使用标准 Flutter；OpenHarmony 使用独立 Flutter fork 和
OpenHarmony Go 工具链。脚本会在构建前生成 SDK，重新构建目标平台 Go Core，
校验包内入口并输出 SHA-256。

签名、产物目录、工具链隔离和 Windows Ninja 构建说明见：

- [开发环境与统一发布](docs/04-dev-env.md)
- [HarmonyOS 构建与适配](docs/harmony-release.md)
- [版本日志](docs/version/README.md)
- [验证记录](docs/verification/)

构建成功不替代 Android/OpenHarmony 真机、多设备联机、Windows WebView2 或生产签名
验收。发布结论必须同时记录自动验证、产物检查和仍需人工完成的项目。
