# IDEA 与 CLI 游戏开发

Playmesh Developer CLI 把 IDEA、WebStorm、VS Code 等外部 IDE 工程连接到已开启
开发者模式的 Playmesh App。源码在 IDE 中修改，发布校验和实际运行仍由目标 App
完成。

## 准备工作

1. 在目标 App 中开启开发者模式并复制完整工作区链接。
2. 安装桌面 App 自带的 `playmesh-cli`，或从 `dev-cli/` 构建。
3. 把 CLI 加入 `PATH`，然后配置目标：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
```

目标配置保存在当前用户目录，但 token 由 Windows DPAPI、macOS Keychain 或 Linux
Secret Service 保护，JSON 不含明文。CLI 2.0 不迁移旧版明文配置；读取到旧格式时
会要求重新执行 `playmesh-cli to`。凭据不写入可能共享或随升级替换的程序安装目录，
也不得提交到项目。

## 初始化原生项目

```powershell
mkdir my-game
cd my-game
playmesh-cli init
```

不带平台参数的 `init` 会先用数字选择 JavaScript 或 TypeScript，再填写项目 ID、名称、
模式、方向、玩家和能力选项，通过现有 Developer API 创建项目。新项目 ID 必须直接
满足 Android applicationId 规则：至少两个点分段，每段以 ASCII 字母开头，其余只能
使用 ASCII 字母、数字或下划线，最长 64 个字符。所有默认选项都会显示，直接回车采用
默认值；该规则不追溯修改 CLI `get` 获取的旧项目 ID。

CLI 2.0 统一生成：

```text
playmesh-cli.json
package.json
jsconfig.json | tsconfig.json
src/                              # 在这里编辑游戏
playmesh/
  build.mjs
  package/
    main.json
    capabilities.json
    icon.png                        # 可选游戏图标
    app/                          # 构建结果与唯一上传目录
  sdk/
    playmesh-main.js
    playmesh-app.js
    playmesh-main.d.ts
    playmesh-app.d.ts
```

Game 类型文件固定为 `playmesh-main.d.ts`，与 `playmesh-main.js` 对称；旧 Game
类型文件不兼容、不保留。

JavaScript 可直接运行 `npm run dev`。TypeScript 首次先执行 `npm install`，再运行
`npm run dev`。IDEA 会识别根 `package.json` 的 npm 脚本，可直接点击 `dev` 左侧
运行按钮。`dev` 会把本地开发 Web 根通过受控代理交给真实 App，并跟随运行日志；
JavaScript 直接提供 `src/`，TypeScript 启动时构建一次并在源码变化后的资源请求上
重新构建。普通资源变化不上传完整游戏包。

JavaScript、TypeScript、Cocos Creator 3.x 和未来 Godot 的开发资源都走同一条公共
映射链路。当前项目的 `adapter.Adapter` 只负责准备资源源：定义 `Start/Stop` 生命周期，
并在启动后交出固定 HTTP 来源、请求路径映射和附加 headers。CLI 的公共代理只消费
这份映射并添加开发凭据；App Developer Gateway 只接收代理地址、凭据和过期时间。
两层公共实现都不会判断 Cocos 或其他引擎。适配器只注册在唯一 `adapter.Registry`
中。新增 Godot 等引擎只需要增加 CLI Adapter 实现及其注册项，App 不增加代码、
资源源类型或注册项，也不为新引擎增加第二份注册表或第三套代理。

`src/playmesh-env.d.ts` 和 `jsconfig.json/tsconfig.json` 接入统一 SDK 声明，因此
两种语言都具有类型提示。`.d.ts`、`playmesh/` 下的构建工具与 SDK 不进入上传包。

## 拉取已有项目

```powershell
mkdir existing-game
cd existing-game
playmesh-cli get com.example.game
```

`get` 只允许在空目录中执行，并固定生成 JavaScript CLI 2.0 工程。App 只保存编译后
的 JavaScript，无法还原 TypeScript 类型、Cocos 场景或原始源码结构，因此现有工程
不会被原地更新，TypeScript/Cocos 必须从 Git 或其他源码备份恢复。

如果已经从 Developer API 手工取得并解压了根 `main.json + app/` 项目包，可在包根
目录执行 `playmesh-cli convert`。命令从已连接 App 获取当前 SDK，在暂存目录完整
校验和生成 JavaScript CLI 2.0 工程，全部成功后才迁移为 `playmesh/package/` 与
`src/` 布局；已有脚手架文件不会被覆盖，失败时原项目包保持不变。

## npm 与 CLI 命令

根 `package.json` 提供：

```powershell
npm run build   # 构建 src/ 到 playmesh/package/app/
npm run dev     # 本地开发资源代理到真实 App，并跟随日志
npm run run     # 正式构建、完整上传并运行，不附加日志
npm run logs    # 实时输出当前运行日志
npm run update  # 更新 SDK 和语言适配器
```

也可以直接使用底层 CLI：

```powershell
playmesh-cli run     # 正式构建、完整上传并启动，不附加日志
playmesh-cli logs    # 只跟随当前项目日志
playmesh-cli dev     # 本地开发资源代理到真实 App，并跟随日志
playmesh-cli update  # 更新 SDK 和适配器
```

`run` 总是由当前项目适配器准备正式构建并上传完整包；`dev` 仅在目标缺少项目时上传
最小基础包，之后从开发 Web 根实时供给 HTML、脚本、样式、图片和引擎资源。修改
Manifest、能力声明或图标时应执行 `run`。`dev` 中按 `Ctrl+C` 会撤销开发会话和
代理，并调用资源源的 `Stop` 回收适配器生命周期；独立 `logs` 中按 `Ctrl+C` 只分离
日志，App 游戏继续运行。

`playmesh-cli.json` 的 `integration.outputDirectory` 默认是 `.`，相对于物理
`packageRoot/app/`；`integration.entry` 默认是 `index.html`，相对于同一个 Web 根。
因此默认正式产物直接写入 `playmesh/package/app/`，运行入口是 `/index.html`。

## Cocos Creator 3.x

现有 Cocos Creator 3.x 项目使用：

```powershell
playmesh-cli init cocos
```

Cocos 适配器保留引擎目录和现有 `package.json`，在 `playmesh/` 中创建隔离发布包与
SDK，在 `assets/playmesh-sdk.d.ts` 接入类型，并安装 `extensions/playmesh/` 项目级
扩展。扩展按 Playmesh `dev` 消息显式参数、`PLAYMESH_DEV_SERVER_URL` 环境变量、
`playmesh-cli.json.integration.developmentServerUrl` 配置项的顺序选择 Creator
浏览器预览地址，再交给 `dev`。Creator 3.8 的公开扩展 API 没有稳定且有文档支持的
当前预览 URL 查询接口；没有消息参数时必须设置环境变量或配置项。自动化契约测试
已经覆盖三种来源及其优先级，但当前环境尚未在真实 Cocos Creator Editor 中验收菜单
调用和预览生命周期。

Web Mobile/Web Desktop 正式构建完成后，扩展会把整个构建结果原子同步到
`playmesh/package/app/`、注入 SDK，再按配置调用 `playmesh-cli run`。详细配置见
[`dev-cli/README.md`](../../dev-cli/README.md)。

## CLI 2.0 破坏性边界

CLI 2.0 运行命令不再直接接受根目录包含 `main.json`、`app/`、`playmesh/sdk/` 的 1.x
布局。旧 JavaScript 项目可在新的空目录中执行 `playmesh-cli get <project-id>`；标准
`main.json + app/` 发布包也可显式执行 `playmesh-cli convert` 转换。旧 TypeScript/Cocos
项目不能从 App 发布包无损迁移，必须使用原始源码重新初始化或手工迁移。CLI 不会隐式
覆盖旧源码，也不会假装反编译 TypeScript。

项目已经存在 `playmesh-cli.json`、根 `main.json` 或
`playmesh/package/main.json` 时，`init` 会在写文件和调用远端创建 API 前报错。
所有配置路径必须是项目内相对路径，不能使用绝对路径或 `..` 越界。

## 发布与数据边界

- 只有 `playmesh/package/` 参与上传；其中进入请求的内容固定为 `main.json`、可选
  `capabilities.json`、可选 `icon.png` 与 `app/`。
- 包根 `playmesh/package/icon.png` 是可选项，通过 PNG、大小和尺寸校验后才上传。
- 外层物理 `playmesh/package/app/` 直接映射为运行时 `/`；物理
  `playmesh/package/app/app/**` 正常映射为 `/app/**`，不会别名到外层目录。
- 清单入口相对于外层物理 `app/`，例如 `index.html`、`controller/index.html`；
  首段 `app` 同样合法。
- `/playmesh/**` 与 `/bucket/**` 是平台保留命名空间，包内不得创建对应一级目录。
- 相同游戏 ID 表示更新，只替换发布内容。
- App 中的 `data/`、`cache/` 保持不变。
- 发布复用正式导入器的路径、大小、Manifest、能力和入口校验。
- 上传进入项目本地历史，网页工作区可以审阅和恢复整包变化。

完整命令与 Cocos 集成见 [`dev-cli/README.md`](../../dev-cli/README.md)，运行语义见
[游戏开发指南](development-guide.md)。
