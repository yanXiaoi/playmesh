# Playmesh

> **App 即服务器：创作完成，打开即玩，分享即可加入。**

Playmesh 是一个局域网优先、支持公共中转的跨平台 HTML 游戏平台。创建者启动游戏时，
Playmesh App 同时承担游戏宿主、联机会话与 Authority，不需要为局域网对局另外部署
专用游戏服务器。朋友扫描二维码或打开分享链接，就能使用普通浏览器立即加入，无需先
安装 App。

普通浏览器加入面向低门槛体验，不提供 Playmesh App 的原生硬件能力；标准 Web API
是否可用仍取决于浏览器、系统和用户授权。希望获得完整能力，或与不在同一局域网的朋友
联机时，双方都使用 Playmesh App。公网联机需要可访问的公共中转服务器，中转只负责
配对和转发端到端加密字节，游戏规则与 Authority 仍运行在创建者的 App 中。

| 游玩场景 | 加入方式 | 能力边界 |
| --- | --- | --- |
| 同一局域网，只有创建者安装 App | 朋友通过二维码或链接在浏览器中加入 | 无需安装 App；不具备 Playmesh 原生硬件能力 |
| 双方都安装 App | 局域网可直接加入；异地通过公共中转加入 | 可按游戏声明使用 App 平台能力；公网模式依赖公共中转服务器 |

游戏只面向稳定的 Game SDK 编程。同一份游戏代码不需要区分局域网浏览器、局域网 App
或公共中转 App；页面加载、连接路径、身份与传输安全都由平台处理。

Playmesh 还把 AI 接入游戏开发全流程：平台会根据当前项目、运行模式、能力声明与 SDK
自动生成完整的 ChatAI 和 AgentAI 项目提示词。普通对话 AI 可以通过结构化指令协助
开发；具备本地工具调用能力的 Agent 则可直接完成文件读取、修改、校验、运行和日志
诊断。

项目说明：本项目目前采用 AI 驱动的集中式开发模式。为保持架构和代码生成流程的一致性，
暂不接受 Pull Request，欢迎通过 Issue 报告 Bug 或提出功能建议。
## 本项目能做什么？
年会小游戏、所有类型的网页单机/联机游戏、各种小工具等所有网页相关的都能运行

## 核心能力

- 导入、导出和管理根目录包含 `main.json` 的 Playmesh 游戏包。
- **App 即服务器**：创建者的 App 直接托管游戏、会话与 Authority，局域网无需额外
  游戏服务器。
- **浏览器免安装加入**：朋友通过二维码或链接立即参与局域网游戏，适合快速分享和
  临时组局。
- **双 App 跨网络联机**：不在同一局域网时，通过可独立部署的 Go Server 公共中转
  建立端到端加密连接。
- 为 HTML/CSS/JavaScript 游戏提供 Authority、状态同步、生命周期、存储、性能和
  设备能力插件。
- **内置 AI 开发闭环**：为 ChatAI 与 AgentAI 生成完整项目提示词，并提供代码编辑、
  Diff、本地历史、校验、真实运行、日志、对话控制台和 Agent API。
- 提供 Go 编写的 [`playmesh-cli`](dev-cli/README.md)，支持在 IDEA 等外部 IDE
  中初始化或恢复工程、代理本地开发资源、正式构建运行和独立跟随日志，并通过统一
  项目适配器接入 JavaScript、TypeScript 与 Cocos Creator 3.x。
- 支持 Android，AndroidTV 与 Windows 发布构建；桌面包自动携带 Go Core 与 Developer CLI。

## 架构概览

```text
Flutter App
  ├─ 游戏库、安装与开发者工作区
  ├─ GamePage / GameLauncher / WebView
  ├─ GameWebResourceSource
  │    ├─ Installed：已安装包 app/
  │    └─ Development：CLI 临时开发代理
  ├─ Game SDK / App Bridge SDK
  ├─ Go Core：会话、玩家、Authority、凭证和消息路由
  └─ 原生宿主：WebView 与平台能力插件

External Developer CLI
  └─ adapter.Adapter -> Developer Gateway -> Development 资源源

可选 Go Server
  ├─ Catalog / 游戏包分享、上传与分发
  └─ 公共 Relay / 端到端加密字节中转
```

普通游戏运行链为“首页/游戏库 -> `GamePage` -> `InstalledGameWebResourceSource` ->
本地资源网关 -> WebView -> SDK/Bridge”；外部开发链则先由 CLI Adapter 建立临时资源
映射和开发会话，再从 `DevelopmentGameWebResourceSource` 汇入同一 WebView 与
SDK/Bridge。App 只区分正式已安装资源和临时开发资源。未来新增 Godot 等引擎只增加
CLI `adapter.Adapter` 实现和注册项，不修改 App。
局域网、公共中转、主机、加入端和浏览器描述共享传输方式，与这两种资源状态正交。

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
| 当前需求的本地工程落点 | [本地实现说明](docs/implementation/README.md) |
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
| ChatAI | [ChatAI 使用方法](docs/game/chat-ai-development.md) | 使用普通对话 AI，通过工作区对话控制台读取和修改项目 |
| AgentAI | [AgentAI 使用方法](docs/game/agent-ai-development.md) | 让具备本地 HTTP 工具能力的 Agent 直接开发、校验、运行和诊断 |
| AI 开发总览 | [AI 游戏开发](docs/game/ai-development.md) | 比较两种工作流并了解共同安全边界 |
| IDEA / CLI | [IDEA 与 CLI 游戏开发](docs/game/idea-cli-development.md) | 在外部 IDE 中编辑本地副本，并发布到目标 App |
| 网页工作区 | [网页开发者通道](docs/game/web-dev-channel.md) | 在 App 或局域网浏览器中编辑、校验、运行和查看日志 |
| 通用契约 | [游戏开发指南](docs/game/development-guide.md) | 理解运行模式、Player/Authority 分层、生命周期和存储 |
| 包格式 | [游戏包与 main.json](docs/game/package-format.md) | 定义目录、清单、能力声明和发布边界 |
| SDK API | [Game SDK / App Bridge SDK](docs/game/sdk-v1.md) | 查询当前公开 API、类型、角色限制和错误语义 |
| 游戏使用设备能力 | [游戏能力使用指南](docs/game/capability-plugins.md) | 使用标准 Web API，并按需声明敏感权限或多平台适配能力 |

### AI 开发

Playmesh 不是只提供一段通用系统提示词，而是为当前游戏动态组装项目类型、页面角色、
项目树、公开 SDK 类型声明、能力上下文与 Developer Operation 契约。AI 因此能够沿用
与人工开发相同的项目、校验器、运行时、日志和本地历史完成闭环。

- **ChatAI（普通对话 AI）**不需要本地工具权限。把生成的对话提示词交给 AI，再将
  AI 返回的 JSON 指令粘贴到工作区“对话控制台”执行；结构化结果可继续发回 AI，
  逐轮完成读取、修改和验证。详见 [ChatAI 使用方法](docs/game/chat-ai-development.md)。
- **AgentAI（本地可操作工具 AI）**使用生成的 Agent 提示词和 Developer Gateway，
  可直接读取项目、原子修改文件、校验、启动或重启游戏并查看日志。详见
  [AgentAI 使用方法](docs/game/agent-ai-development.md)。

两种方式都通过同一套 Developer Operation API 工作；删除、WebView JavaScript 等
危险操作会暂停并在工作区请求开发者审批。

Playmesh 只翻译 App 自己的界面。面向游戏开发者的唯一全局对象是
`window.playmesh`，其根级公开成员严格只有 `ready`、`main` 与 `app`；
`window.playmeshApp` 不存在，`playmesh.main` 与 `playmesh.app` 也不暴露任何
`__*` 内部桥接成员。游戏先等待根 `playmesh.ready`；它复用
`playmesh.main.ready` 初始化链，而 `main.ready` 内部先等待
`playmesh.app.ready`，最终获得 `{main, app}`。Game/App 类型文件固定为
`playmesh-main.d.ts` 与 `playmesh-app.d.ts`，旧 Game 类型文件不兼容、不保留。
游戏通过
`playmesh.app.runtime.getLocale()` 读取当前显示端 locale，但不会获得 App 词典；
游戏业务文案仍由游戏包自行提供和切换。

### IDEA / CLI 开发

先复制 App 显示的完整工作区链接：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli init
npm run dev
```

`init` 会用数字选择 JavaScript 或 TypeScript，并生成 IDEA 可直接运行的 npm
`build/dev/run/logs/update` 脚本；`dev` 通过本地资源代理在真实 App 中调试，
`run` 执行正式构建与完整上传。`playmesh-cli get <project-id>` 可把 App 中的编译发布
包恢复为 JavaScript 2.0 工程；TypeScript 与 Cocos 源码仍须由源码版本库保存。完整
命令、Cocos Creator 3.x 集成、破坏性目录变更和发布边界见
[Developer CLI](dev-cli/README.md)。

CLI 2.0 项目把发布包固定隔离在 `playmesh/package/`，SDK 与类型固定在
`playmesh/sdk/`。上传只包含必需 `main.json`、可选 `capabilities.json`、可选安全根
`icon.png` 与必需 `app/`；SDK 目录永不上传。清单必须显式声明 `entries.game`，
单屏多人另须 `entries.controller`，多人另须 `authority.entry`，缺失时不回退模板
路径。

## 平台开发

平台维护者从[平台开发文档目录](docs/platform/README.md)开始：

| 主题 | 文档 | 核心约束 |
| --- | --- | --- |
| 能力插件 | [能力开发约定](docs/platform/capability-development.md) | 描述符、实例生命周期、平台适配、自检和注册只有一份定义 |
| SDK | [SDK 开发约定](docs/platform/sdk-development.md) | TypeScript、类型声明、宿主执行器、精确版本发行定义和版本执行器同源 |
| 开发者工作区 | [开发者工作区开发约定](docs/platform/developer-workspace-development.md) | Operation Definition 同时驱动路由、文档、权限、审批和 AI 操作目录 |
| Go Server | [Go Server 开发约定](docs/platform/go-server-development.md) | 游戏包源与公共中转共用轻量部署载体，但接口、存储、鉴权和协议版本保持独立 |

App 内置 Developer Workspace 和平台注入游戏 WebView 的 UI 都属于 App 表面。
Flutter、工作区和平台 Web UI 的显示文案统一来自当前 locale 的 `app.json`，由宿主
桥接只读 `locale + messages` 投影并随 App 语言实时更新；网页端不维护独立词典。

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
docs/implementation/         当前需求的本地实现落点
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

测试用公共中转：http://8.137.106.103:16668
## 构建与发布

统一发布入口支持 `android`、`windows` 和 `all`：

```powershell
.\tool\build_release.ps1 -Target all
```

脚本会在构建前生成 SDK，重新构建目标平台 Go Core，校验包内入口并输出 SHA-256。

提交当前 `master` 的所有变更后，可使用当前 `pubspec.yaml` 的
`MAJOR.MINOR.PATCH+BUILD` 一键构建，并同时发布 GitHub 与 Gitee Release：

```powershell
# 首次使用先安装并登录 GitHub CLI
winget install --id GitHub.cli
gh auth login

# 临时使用：Gitee 私人令牌只注入当前进程，不写入仓库
$env:GITEE_ACCESS_TOKEN = '<具有 project 权限的私人令牌>'

# 构建 Android 与 Windows，并发布 v{VERSION}-build{BUILD}
.\tool\publish_github_release.ps1

# 只发布某个平台
.\tool\publish_github_release.ps1 -Target android
.\tool\publish_github_release.ps1 -Target windows

# GitHub 已成功而 Gitee 中途失败时，只重试 Gitee，不重新构建
.\tool\publish_gitee_release.ps1 -Target all
```

脚本要求工作树干净且当前分支为 `master`，会推送 `origin/master`、调用统一发布构建、
生成 `SHA256SUMS.txt`，在 Release 正文链接到对应标签下的
`docs/version/<版本号>.md`，再创建两个平台的同名 Release 并上传同一批产物。Gitee
仓库固定为 `yanxao/playmesh`；发布前会等待镜像包含本次提交，重复执行时会复用发行版
并跳过同名附件。令牌也可以一次性保存在 Git 已忽略的
`release/tools/gitee-token.txt`，以后无需每次设置环境变量。已有产物可使用
`-SkipBuild`；GitHub 已成功时可单独执行
`publish_gitee_release.ps1`。只想创建 GitHub 草稿可加 `-Draft`，草稿不会同步到
Gitee；确需仅发布 GitHub 时可加 `-SkipGitee`。Android 默认要求正式签名，显式允许
Debug 签名时还必须同时使用 `-Draft` 或 `-Prerelease`，避免误发成正式版本。

签名、产物目录、工具链隔离和 Windows Ninja 构建说明见：

- [开发环境与统一发布](docs/04-dev-env.md)
- [版本日志](docs/version/README.md)
- [验证记录](docs/verification/)

构建成功不替代 Android 真机、多设备联机、Windows WebView2 或生产签名验收。
发布结论必须同时记录自动验证、产物检查和仍需人工完成的项目。
