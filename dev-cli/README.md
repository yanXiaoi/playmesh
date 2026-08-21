# Playmesh Developer CLI

The Playmesh Developer CLI is licensed under the [MIT License](LICENSE). Pull requests are welcome; see the repository [contribution guide](../CONTRIBUTING.md).

`playmesh-cli` 是使用 Go 标准库实现的全局开发工具。它把 IDEA、WebStorm、VS Code
等外部 IDE 中的工程连接到已开启开发者模式的 Playmesh App；校验、安装和实际运行
仍由目标 App 完成。

## 构建与安装

```powershell
cd dev-cli
go test ./...
node internal/adapter/cocos/test_extension.mjs
go build -o playmesh-cli.exe .
```

把可执行文件加入 `PATH`。当前开发版本为 `2.0.0`；可用
`playmesh-cli --version`、`playmesh-cli -v` 或 `playmesh-cli version` 查看。正式
二进制名称固定为 Windows 的 `playmesh-cli.exe` 和 macOS/Linux 的
`playmesh-cli`。原生 JavaScript/TypeScript 工程还需要可用的 Node.js 与 npm，
以便 IDE 执行根 `package.json` 脚本。

桌面 App 会随平台构建自动编译 CLI：Windows 放在 `playmesh-core.exe` 同级，Linux
放在 bundle 根目录，macOS 放在 `.app/Contents/MacOS/`；Android/iOS 不携带 CLI。

## 源码结构

模块根目录的 Go 源码只保留 `main.go`，它只调用 `internal/cli.Run`、统一输出错误并
设置退出码。其余实现按职责隔离：

```text
internal/
  cli/                 # 命令路由与 to/get/convert/init/configure/update/dev/run/logs 编排
  adapter/
    adapter.go         # Adapter 接口与 Registry
    registry/          # JavaScript、TypeScript、Cocos 的唯一组合根
    script/            # JavaScript/TypeScript 实现
    cocos/             # Cocos 实现、嵌入扩展及扩展契约测试
  project/             # playmesh-cli.json 与工程上下文
  packaging/           # 发布包校验、打包、解包和开发基础包
  sdk/                 # SDK 拉取、安装、版本读取与清单版本回写
  development/         # Source/Mapping 接口、本地资源源与公共代理
  target/              # Developer API、目标配置与系统凭据保护
  contract/            # 固定目录和协议版本
  manifest/            # main.json 契约投影
  webpath/             # Web 路径与符号链接安全策略
  fsutil/              # 原子文件/目录替换
  scaffold/            # 初始化默认值模型
```

适配器基包不依赖具体实现；唯一 `adapter.Registry` 在 CLI 组合根注册实现。新增 Godot
只新增适配器实现并在该组合根注册，不修改公共命令、开发代理或 App。

## CLI 2.0 项目模型

CLI 2.0 是破坏性更新。所有 CLI 工程都必须在根目录包含 `playmesh-cli.json`，不再
识别把 `main.json`、`app/` 和 `playmesh/sdk/` 直接放在项目根的 1.x 结构。原生
JavaScript、TypeScript 与 Cocos Creator 3.x 统一使用隔离发布包：

```text
playmesh-cli.json
package.json                    # 原生项目的 IDEA/npm 运行入口
.gitignore                      # 排除依赖、SDK 和构建输出
jsconfig.json | tsconfig.json   # 原生项目
src/                            # 原生项目源码
playmesh/
  build.mjs                     # CLI 管理的原生项目构建适配器
  package/                      # 唯一上传目录
    main.json
    capabilities.json           # 可选能力声明
    icon.png                    # 可选游戏图标
    app/
  sdk/
    playmesh-main.js
    playmesh-app.js
    playmesh-main.d.ts
    playmesh-app.d.ts
```

旧工程可在空目录使用 `playmesh-cli get <project-id>` 从 App 恢复，或把 Developer API
取得的标准 `main.json + app/` 项目包放在当前目录后执行 `playmesh-cli convert`，两种
方式都会生成 JavaScript 2.0 工程。App 只保存编译后的 JavaScript 发布包，不能还原
TypeScript 或 Cocos 源码；这些工程必须从 Git 或其他源码备份恢复。CLI 不执行隐式
迁移，必须显式调用上述命令。

## 连接目标 App

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
```

目标地址保存在当前用户配置目录的 `Playmesh/cli-target.json`，但 token 不再明文写入：
Windows 使用绑定当前用户的 DPAPI 密文，macOS 使用 Keychain，Linux 使用 Secret
Service（需要 `secret-tool`/`libsecret-tools`）。JSON 只保存密文或系统凭据引用，
并继续使用用户级目录权限。CLI 2.0 不迁移旧版明文配置；发现旧配置或保护信息不完整
时会拒绝读取，必须重新执行 `playmesh-cli to`。安装目录不用于保存凭据，因为它可能
只读、多人共享或在升级时被替换。

## 初始化原生 JavaScript/TypeScript 项目

```powershell
mkdir my-game
cd my-game
playmesh-cli init
```

`init` 不带平台参数时初始化原生项目。第一项使用数字选择 JavaScript 或 TypeScript，
随后继续使用数字选项填写游戏模式、方向、显示模式、玩家人数和能力，并通过现有
Developer API 创建项目。新项目 ID 必须直接满足 Android applicationId 规则：至少
两个点分段，每段以 ASCII 字母开头，其余只能使用 ASCII 字母、数字或下划线，最长
64 个字符。所有默认值都会显示，直接回车采用当前默认。游戏配置字段、交互收集和
校验与 `configure` 共用同一套实现，不在 `init` 中维护第二份定义；`get` 获取旧项目
时不追溯套用这项新建规则。

## 配置当前项目

```powershell
playmesh-cli configure
playmesh-cli configure --out
Get-Content settings.json -Raw | playmesh-cli configure --json
```

不带参数时进入交互配置。`--out` 是唯一的配置输出形式，固定向标准输出写 JSON，
不接受额外的 `json` 参数；`--json` 从标准输入读取一个 JSON 对象并保存。各适配器
只负责返回本项目 `main.json` 的位置，CLI 公共层统一执行路径边界与符号链接检查、
字段校验和原子全量覆盖。

只有单屏多人模式保存 `entries.controller`、`controllerOrientation` 和控制器能力，
控制器 HTML 地址由用户配置。单人模式以及联机多屏多人模式都会删除这些字段；切换
模式时不会继承上一种模式的控制器配置。多人模式的权威逻辑 JS 地址同样由用户配置。

JavaScript 与 TypeScript 都生成根 `package.json`，IDEA 会在 npm 工具窗口显示：

- `build`：把 `src/` 构建到 `playmesh/package/app/`；TypeScript 会先执行类型检查。
- `dev`：调用 `playmesh-cli dev`，把本地开发资源代理到真实 App 并跟随日志。
- `run`：正式构建、完整上传并在真实 App 启动，输出 `runId` 后返回。
- `logs`：调用 `playmesh-cli logs` 跟随当前运行日志。
- `update`：调用 `playmesh-cli update` 更新 SDK 和项目适配器。

JavaScript 无第三方依赖，可以直接在 IDEA 中运行 `dev`，或执行：

```powershell
npm run dev
```

TypeScript 首次使用先安装项目内编译器：

```powershell
npm install
npm run dev
```

`src/playmesh-env.d.ts` 引用 `playmesh/sdk/*.d.ts`，因此两种语言在 IDEA 中都能获得
Playmesh SDK 类型提示。JavaScript 开发态直接把 `src/` 作为 Web 根；TypeScript
启动时先构建一次，并在资源请求到来时重新构建后提供 JavaScript。两者都不因普通
HTML、脚本、样式或图片修改而上传完整游戏包。正式构建器拒绝源码符号链接，使用
临时目录原子替换发布 `app/`，并排除 `.d.ts`。Game 类型文件固定为
`playmesh/sdk/playmesh-main.d.ts`；旧 Game 类型文件不兼容、不保留。

## 拉取已有项目

```powershell
playmesh-cli get com.example.game
```

`get` 只允许在空目录执行，固定生成新的 JavaScript 2.0 工程。它是已发布 JavaScript
包的恢复入口，不会更新现有 CLI 工程，也不执行旧布局的隐式迁移。编译会丢失
TypeScript 类型与源码组织，Cocos 发布包也不包含场景和资源工程，因此这两类源码
必须从 Git 或其他备份恢复。

## 转换本地项目包

从 App 的 Developer API 手工取得并解压标准项目包后，在包根目录执行：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
playmesh-cli convert
```

当前目录必须包含根 `main.json` 和 `app/`，也可包含 `capabilities.json` 与 `icon.png`。
`convert` 先按正式上传规则完整校验本地包，从已连接 App 获取当前 SDK，在临时目录生成
完整 JavaScript CLI 工程，全部成功后才替换布局。成功后原根 `main.json`、`app/` 和
可选包文件会迁入 `playmesh/package/`，发布包的 `app/` 同时复制为可编辑的 `src/`；
其他文件保持不变。若 `playmesh-cli.json`、`playmesh/`、`src/`、`package.json`、
`jsconfig.json` 或 `.gitignore` 已存在，命令会拒绝覆盖。任何校验、SDK 下载或生成失败
都不会改动原项目包。

## 命令语义

- `playmesh-cli init`：创建原生项目并选择 JavaScript/TypeScript。
- `playmesh-cli init cocos`：在当前 Cocos Creator 3.x 工程中创建 Playmesh 项目并
  安装项目级扩展。
- `playmesh-cli get <project-id>`：把 App 发布包恢复为 JavaScript 2.0 工程；不用于
  恢复 TypeScript 或 Cocos 源码。
- `playmesh-cli convert`：把当前目录手工复制出的标准 `main.json + app/` 项目包显式
  转换为 JavaScript 2.0 工程，并从已连接 App 安装当前 SDK。
- `playmesh-cli configure`：交互设置当前项目，复用 `init` 的配置定义与收集流程。
- `playmesh-cli configure --out`：只以 JSON 输出当前可配置状态。
- `playmesh-cli configure --json`：从标准输入读取 JSON，由公共层校验并全量覆盖当前
  项目配置。
- `playmesh-cli update`：更新当前 SDK 与 `main.json` 版本，再按
  `integration.type` 刷新 JavaScript、TypeScript 或 Cocos 集成。
- `playmesh-cli run`：由适配器正式构建，完整上传、校验、原子安装并启动或重启当前
  项目；输出 `runId` 后立即返回，不附加日志。
- `playmesh-cli logs`：确认 App 当前运行的是本地项目，回放缓存并实时跟随日志。
- `playmesh-cli dev [adapter-args]`：把 `adapter-args` 原样交给当前项目适配器，
  启动或连接开发 Web 根，通过受控局域网代理在真实 App WebView 中运行，并实时输出
  日志。Cocos 适配器要求精确传入一个预览服务器 URL；每次启动都会重新生成并上传
  当前最小开发基础包，更新 `main.json`、`capabilities.json` 和安全图标，普通游戏
  资源仍通过开发代理提供，不执行完整资源上传。
- `playmesh-cli capabilities --json`：通过操作系统保护的目标凭据读取 App 当前注册的
  能力目录，供 Cocos 项目设置面板等工具生成能力选择列表。

### 开发资源公共接口

开发资源映射与具体引擎无关。`adapter.Adapter.PrepareDevelopment` 只返回
`development.Source`；资源源负责 `Start/Stop` 生命周期，`Start` 返回
`development.Mapping`，后者只描述固定 HTTP 来源、请求路径映射和附加
headers。开发控制面固定为：

```text
playmesh-cli dev [adapter-args]
  -> adapter.Registry 中的 Adapter
  -> Adapter.PrepareDevelopment(adapter-args)
  -> development.Source.Start()
  -> development.Mapping
  -> CLI 公共 development.Proxy
  -> POST /dev/api/projects/{projectId}/development
  -> App DeveloperWebGateway
  -> DeveloperRunController
  -> GamePage
  -> DevelopmentGameWebResourceSource
```

页面启动后的开发资源面固定为：

```text
WebView
  -> App GameAssetGateway
  -> DevelopmentGameWebResourceProvider
  -> CLI 公共 development.Proxy
  -> development.Mapping
  -> 本地静态根 / 重构建服务 / 引擎预览服务器

WebView
  -> /playmesh/** 或 /bucket/**
  -> App 本地处理（不进入 CLI 代理）
```

JavaScript/TypeScript 适配器可以启动本地静态或按需重构建资源源；Cocos 适配器只把
Creator 预览服务器转换成相同 mapping；未来 Godot 等适配器也必须遵守同一接口。CLI
公共代理只验证并消费 mapping，不读取 `integration.type`，没有 Cocos、语言或引擎
分支；App Gateway 只接收 `resourceBaseUrl`、一次性 credential 与 `expiresAt`，
同样不识别引擎。`adapter.Registry` 是唯一适配器实例注册表；不得新增第二份实例表，
也不得在 CLI 公共代理与 App Gateway 之外建立第三套引擎代理。新增 Godot 只需要
增加 CLI Adapter 实现并注册，App 不增加 Godot 代码、资源源类型或注册项。

App 只区分正式已安装资源和临时开发资源。正式运行从
`InstalledGameWebResourceSource` 进入相同的 `GameAssetGateway`、WebView 与
SDK/Bridge；开发运行仅把普通资源 Provider 替换为上述代理链。局域网、公共中转、
主机、加入端和浏览器是共享传输维度，不改变 CLI Adapter 或 App 资源源边界。

项目创建统一由 `init` 完成，正式发布运行统一由 `run` 完成，SDK 与适配器升级统一
由 `update` 完成。每次执行 `dev` 都会在建立开发会话前更新基础包；已经运行的
`dev` 进程期间修改 `main.json`、`capabilities.json` 或 `icon.png` 后，需要重新启动
`dev` 才会再次上传。

`dev` 与 `logs` 都回放缓存日志并跟随 SSE/轮询事件，但退出语义不同：

- `dev` 按 `Ctrl+C` 会撤销开发会话、关闭本地资源代理并分离日志，不覆盖 App 中的
  项目数据。
- 独立 `logs` 按 `Ctrl+C` 只分离日志，App 中的当前游戏继续运行。

## playmesh-cli.json

原生 JavaScript 项目示例：

```json
{
  "schemaVersion": 1,
  "packageRoot": "playmesh/package",
  "sdkRoot": "playmesh/sdk",
  "integration": {
    "type": "javascript",
    "projectRoot": ".",
    "sourceRoot": "src",
    "outputDirectory": ".",
    "entry": "index.html"
  }
}
```

TypeScript 只把 `integration.type` 改为 `typescript`。所有路径相对
`playmesh-cli.json` 所在目录解析，不能使用绝对路径或 `..` 越出项目；配置不保存
Developer token。`outputDirectory` 相对于物理 `packageRoot/app/`，`entry` 相对于
同一个 Web 根；因此默认 `.` 与 `index.html` 分别表示正式产物直接写入
`playmesh/package/app/`、运行时访问 `/index.html`。`app` 不是特殊前缀：
`outputDirectory: "app"` 与 `entry: "app/index.html"` 分别指向物理
`playmesh/package/app/app/` 与运行时 `/app/index.html`。

## Cocos Creator 3.x

在尚未初始化、也不是 Playmesh 项目的 Cocos Creator 3.x 工程根执行：

```powershell
playmesh-cli to "<完整工作区链接>"
playmesh-cli init cocos
```

`init` 是公共平台适配入口。Cocos 适配器检测 `assets/`、`settings/` 与项目描述文件，
从 `package.json` 或 `project.json` 读取项目名作为可见默认值，然后调用与原生项目
相同的创建流程。已经存在 `playmesh-cli.json`、根 `main.json` 或
`playmesh/package/main.json` 时，会在写文件和调用远端 API 前拒绝重复初始化。

Cocos 原目录和 `package.json` 保持不变，新增：

```text
playmesh-cli.json
playmesh/
  package/
    main.json
    capabilities.json          # 可选能力声明
    icon.png                   # 可选游戏图标
    app/                      # Cocos Web 构建产物
  sdk/
  playmesh-cli.schema.json
assets/playmesh-sdk.d.ts
extensions/playmesh/
preview-template/
  index.ejs
  playmesh-preview-gate.js
  playmesh-preview-runtime.json  # 扩展启动后写入当前实际监听端口
```

项目扩展会在 Web Mobile 与 Web Desktop 的构建选项底部显示 Playmesh 区块。启用
“Playmesh 发布”后，Web 构建成功会把 `result.dest` 原子同步到
`packageRoot/app/{integration.outputDirectory}`，在 Cocos 启动脚本前注入
`/playmesh/sdk/v1/playmesh-main.js`；启用“构建后上传并运行到 App”时再调用
`playmesh-cli run`。因此 Cocos 的 Web 构建按钮可直接把最新版本运行到真实 App。
“扩展 -> Playmesh”菜单还提供项目设置、打开 Web 构建发布、上传并运行最近构建、
查看运行日志和更新集成。项目设置是可停靠面板，可编辑游戏名称、备注、标签、方向、
模式、显示模式、玩家人数、权威逻辑 JS 地址、控制器 HTML 地址、主画面/控制器能力，
以及 Cocos 构建平台、构建后自动运行和预览桥端口。项目 ID、SDK 版本和运行入口只读，
不提供作者设置；版本由用户在面板中维护。面板通过 `playmesh-cli configure --out`
读取完整状态，通过 `playmesh-cli configure --json` 保存；能力目录由 CLI 公共层从
当前目标 App 动态获取，目标暂不可用时仍保留项目已有能力声明并显示警告。开发态直接代理 Cocos 预览服务器的
`/scripting/**`、`/preview-app/**`、项目资源和其他根绝对路径，不会写入正式构建
目录。每次 `dev` 构建的临时基础包会只在内存中把 `main.json.entries.game` 改为
当前 Cocos 预览页对应的完整 `HTML 路径?原始查询串`，并为 App 导入校验按 `?`
之前的物理路径加入占位文件；项目磁盘
上的 `main.json` 不会被修改。这样 App 的入口、`index.css`、`favicon.ico` 等相对
资源以及 `/settings.js`、`/scripting/**` 等根绝对资源都以与 Cocos 页面相同的路径
请求，代理按临时清单入口直接透传原始查询参数，其他请求只做同源透明转发。这里只由 Cocos
`adapter.Adapter` 提供预览来源和临时入口，CLI 代理与 App Gateway 没有 Cocos
资源路径分支。

Cocos 顶部浏览器预览按钮是开发运行的唯一入口。CLI 安装的 `preview-template`
会在普通浏览器解析 Cocos 启动内容之前暂停页面，从扩展的本机端点取得一个 15 秒
有效、一次性使用且绑定当前 Origin 的随机 token，再携带该 token 请求扩展执行：

```text
playmesh-cli dev <当前 Cocos 完整预览页 URL>
```

扩展拒绝缺少 token、token 错误、重复使用、过期、Origin 不匹配或非本机预览来源的
请求。当前完整预览页 URL（包括平台、构建任务子路径和查询参数）作为命令参数原样进入
CLI，再由 Cocos 适配器生成本次上传使用的临时游戏入口；不存在环境变量或
`playmesh-cli.json` 配置回退。CLI 会逐步输出资源源、临时入口、基础信息上传、代理、
入口 HTML 与 `GameCanvas` 预检、App 会话、日志连接和清理状态；上游非 2xx 也会
输出具体资源路径。
普通浏览器只显示交接状态，
不会渲染游戏；同一页面由 Playmesh App WebView 加载时才继续执行 Cocos 启动逻辑。

CLI 在项目没有自定义预览模板时安装包含 `GameCanvas`、工具栏、加载进度和错误面板的
完整 Cocos 3.x 模板；早期 CLI 生成的精简模板会在 `playmesh-cli update` 或下一次
`playmesh-cli dev` 准备资源时自动迁移，不要求先手工修改项目 `main.json`。

扩展默认以端口 `0` 监听 `127.0.0.1`，由操作系统选择当前可用端口，再把实际端口原子
写入 `preview-template/playmesh-preview-runtime.json`。预览页每次使用禁用缓存的随机
URL 读取该文件，因此不会依赖固定端口，也不会复用上次编辑器进程的旧端口。CLI 会把
这个运行时文件的精确路径加入 `.gitignore`，门禁模板仍正常纳入版本控制。如需固定
端口，可在 Cocos 项目的 `playmesh-cli.json` 中显式配置：

```json
{
  "integration": {
    "previewBridgePort": 17321
  }
}
```

`previewBridgePort` 省略或设为 `0` 都表示系统自动分配；设为 `1-65535` 时严格使用该
端口。显式端口已被占用会使扩展加载失败并报告端口冲突，不会静默切换到其他端口。

Cocos Creator 3.8 的公开扩展接口不能向“发布平台”或顶部“预览设备”下拉框注册新项，
所以 Playmesh 不会作为独立平台出现在这两个列表里；它作为 Web Mobile/Web Desktop
构建扩展显示并参与构建。首次使用请在 Cocos 扩展管理器中刷新并在已安装扩展中启用
Playmesh 扩展。Creator 3.8 的公开扩展 API 没有稳定且有文档支持的预览点击钩子，
因此自动启动由项目预览模板与带 token 的本机扩展端点协作完成。

`playmesh-cli update` 会先更新 SDK，再刷新 Cocos JSON Schema、TypeScript 声明引用
和 `extensions/playmesh/`。Cocos 2.x 不在适配范围。

## 发布边界

只有 `playmesh/package/` 进入上传包，内容固定为必需 `main.json`、可选
`capabilities.json`、可选安全根 `icon.png` 与必需 `app/`；`playmesh/sdk/` 永不
上传。目标 App 继续复用正式导入器完成 ZIP 路径、大小、Manifest、能力、图标和入口
校验。相同 `main.json.id` 表示更新，只替换发布内容；目标中的 `data/`、`cache/`
保持不变。失败时恢复原发布文件。

CLI 在上传前要求 `main.json.entries.game` 显式存在；单屏多人还要求显式
`entries.controller`，多人要求显式 `authority.entry`。三者必须指向
`playmesh/package/app/` 中实际文件，不能依赖模板路径回退。`sdkVersion` 与
`appSdkVersion` 同样必须显式写入；Game SDK 只支持 `4.0.0`，App SDK 支持
`3.2.0` 与 `3.3.0`，新建、更新和发布默认写入当前 `3.3.0`。

包根 `playmesh/package/icon.png` 是可选项；文件存在且通过 PNG、大小和尺寸校验时
才随完整包或每次开发基础包上传，缺少图标不会阻止发布。

物理 `playmesh/package/app/` 在 App 中直接映射为运行时 `/`；`/playmesh/**` 与
`/bucket/**` 是平台保留命名空间。发布包不得包含一级 `app/playmesh/` 或
`app/bucket/`（大小写不敏感），入口必须是相对于外层物理 `app/` 的正斜杠路径。
用户首段 `app` 合法，例如清单入口 `app/index.html` 解析到物理
`playmesh/package/app/app/index.html`，运行时 URL 为 `/app/index.html`；它不是
外层 `app/` 的兼容别名。编码、反斜杠和越界路径仍不提供兼容。
