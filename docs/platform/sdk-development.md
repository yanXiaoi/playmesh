# SDK 开发约定

本约定适用于 Game SDK、App Bridge SDK、网页运行片段、Dart 宿主执行器和 SDK
精确版本发行定义。游戏作者 API 见 [Game SDK / App Bridge SDK](../game/sdk-v1.md)。

## 核心原则：逻辑即定义

SDK 唯一手写源位于：

```text
lib/core/game_sdk/
  sdk_feature_registry.dart
  features/
    game/
    app/
```

一个 Feature 在同一个 Dart 文件中维护：

- 网页 TypeScript 和类型声明片段；
- 网页实际发送的命令；
- Dart 宿主命令执行器；
- 执行器支持的 SDK Bundle 版本范围。

不能直接修改以下生成产物作为功能实现：

```text
assets/playmesh-library/sdk-src/
assets/playmesh-library/public/sdk/v1/
```

生成物用于发布、审阅、外部 IDE 和包内资源检查，不是运行时事实源。

## 注册表职责

`SdkFeatureRegistry` 是唯一注册与分发位置，负责：

- 按 target 和 order 组装 Game/App SDK；
- 生成 TypeScript、JavaScript 和 `.d.ts`；
- 建立命令到版本化执行器的索引；
- 注册 Game/App SDK 当前精确发行；
- 根据游戏声明精确解析 SDK Bundle；
- 根据消息携带的实际 Bundle 版本选择对应执行器；
- 拒绝旧版本、未知版本、格式错误版本和同版本重复执行器；
- 为网关、Developer API、AI 提示词和 SDK 下载提供同一内容。

Bridge 只负责消息解析、上下文构造、统一分发和响应，不重新维护命令 `switch`。

## Game SDK 与 App SDK 的实现边界

`playmesh-main.js` 是公共游戏运行时，`playmesh-app.js` 是当前终端运行时。新增字段或功能前必须先判断所有权：

| 数据或行为 | 唯一所有者 | 规则 |
| --- | --- | --- |
| 游戏声明、`gameId`、会话、玩家、Authority 角色、同步、生命周期、Bucket | `playmesh-main.js` | 只公开 `playmesh.main.*`；所有平台使用相同 API，共享结果由 Authority 主机或受控 Game SDK Bridge 提供 |
| 平台、App 身份、locale、FPS/延迟、能力注册表、设备可用性、权限、全屏、终端输入 | `playmesh-app.js` | 只公开 `playmesh.app.*`；由当前 Windows/Android/浏览器终端注入，允许每个玩家结果不同 |
| Console 日志拦截、日志缓存和日志覆盖层 | `playmesh-app.js` | 只保留当前页面、当前终端日志，不进入 Game SDK、Session 或 Authority |
| 菜单、信息、日志和性能覆盖层的 DOM | `playmesh-app.js` | 可读取 Game SDK 数据，但只负责展示和终端交互 |

禁止在 App bootstrap、App Bridge、URL 配置或页面全局变量中复制 `gameInfo`、
Session、Player 或 Authority 数据。App 覆盖层需要这些公共游戏数据时，只能由
`playmesh-main.js` 通过私有运行时适配器单向提供；FPS 与延迟本身属于当前客户端，
由 `playmesh.app.performance.*` 直接拥有。远程 App 的能力声明也由 Game SDK 读取
权威页面声明后，通过内部 `app.game.configure` 同步给当前终端能力宿主；App SDK
不自行解析第二条游戏声明链路。反方向同样禁止：Game SDK 不生成设备能力、权限、
当前终端身份、本机性能或本机日志的兼容值。

App WebView 与普通浏览器都必须成对加载 `playmesh-main.js` 和
`playmesh-app.js`；前者从 Authority 游戏资源来源加载，后者由当前终端的本机回环
入口或 Authority 分享网关提供。默认浏览器 App SDK 必须包含居中菜单、游戏信息、
运行日志、继续、刷新、退出游戏，以及仅普通浏览器显示的可拖动悬浮入口。菜单 DOM
可以因终端布局自适应，但其游戏信息和性能数据仍只能读取 `playmesh-main.js`。
旧 `playmesh.js` 文件不兼容、不保留。

## 当前公开 SDK 方法

当前 Game SDK 为 `4.0.0`，App Bridge SDK 为 `3.2.0`。下表是当前公开面；
精确参数、泛型、返回类型和中文 JSDoc 仍以注册表生成的 `playmesh-main.d.ts` 与
`playmesh-app.d.ts` 为准。旧 Game 类型文件不兼容、不保留。

| 命名空间或句柄 | 当前公开成员 |
| --- | --- |
| `playmesh` | `main`、`app`、`ready`；根 `ready` 复用 `main.ready` 初始化链并返回 `{main, app}`，`main.ready` 内部先等待 `app.ready`，没有其他根级兼容成员 |
| `playmesh.main` | `version`、`ready` |
| `playmesh.main.gameInfo` | `getCurrent()` |
| `playmesh.app` | `version`、`ready`、`isAvailable()` |
| `playmesh.app.identity` | `getCurrent()` |
| `playmesh.app.capabilities` | `getRegistry()`、`getAvailable()`、`getDeclared()`、`create()` |
| `CapabilityHandle` | `id`、`code`、`apiVersion`、`invoke()`、`on()`、`addEventListener()`、`removeEventListener()`、`onError()`、`dispose()` |
| `playmesh.app.media` | `open()` |
| `AppMediaSession` | `id`、`source`、`stream`、`state`、`close()` |
| `playmesh.app.device` | `getPlatform()`、`setFullscreen()`、`onInput()` |
| `playmesh.app.ui` | `configure()`、`initializeBrowser()`、`showGameSidebar()`、`restartGame()`、`openSharePanel()`、`openRuntimeLogs()`、`enterFullscreen()`、`exitFullscreen()`、`openGameInfo()`、`setPerformanceVisible()`、`togglePerformance()`、`exitGame()` |
| `playmesh.app.runtime` | `getLocale()` |
| `playmesh.main.session` | `getCurrent()`、`onStateChange()`、`onPlayerJoin()`、`onPlayerLeave()`、`onPlayerReconnect()`、`isAuthority()`、`start()`、`finish()` |
| `playmesh.main.player` | `getCurrent()`、`setNickname()` |
| `playmesh.main.game` | `submitAction()`、`onMessage()`、`onEvent()` |
| `playmesh.main.authority` | `onService()` |
| `playmesh.main.binary` | `authorityPlayerId`、`createChannel()`、`joinChannel()` |
| `BinaryChannel` | `id`、`mode`、`send()`、`sendLatest()`、`onMessage()`、`onForward()`、`close()` |
| `playmesh.main.sync` | `startAuthority()`、`submitAction()`、`submitState()`、`requestSnapshot()`、`getSnapshot()`、`observe()` |
| `SyncAuthorityController` | `getState()`、`setState()`、`publish()`、`stop()` |
| `playmesh.main.lifecycle` | `onChange()`、`onPause()`、`onResume()`、`onExit()` |
| `playmesh.app.performance` | `reportFrame()`、`getFps()`、`onFps()`、`getLatency()`、`getLatencyDiagnostics()`、`onLatency()`、`setVisible()` |
| `playmesh.main.storage` | `getBucket()` |
| `StorageBucket` | `getData()`、`setData()`、`removeData()`、`clearData()`、`upload()` |

面向游戏开发者的唯一全局对象是 `window.playmesh`，其根级公开成员严格只有
`ready`、`main` 与 `app`。`window.playmeshApp` 不存在，公开的 `main`/`app`
不得挂载任何 `__*` 内部桥接成员。两 SDK 的内部协作统一通过不可枚举的私有
`Symbol` runtime 完成；该 runtime 不得进入 `.d.ts`、SDK Manifest、提示词、补全
或游戏可调用 API。

公开方法不等于宿主命令。`version`、bootstrap getter、缓存 getter、监听器注册和部分
网页状态方法只操作 SDK 内存；只有最终调用 `post(command, ...)` 或
`request(command, ...)` 的路径才进入 Dart Bridge。普通浏览器中的
`game.submitAction` 走浏览器 WebSocket。性能探针由 App SDK 每 3 秒调度并生成唯一
probe ID；Game SDK 只把 `performance.ping` 送入既有 Session transport，再把收到的
`performance.pong` 原样转交 App SDK。FPS 统计、RTT 平滑、缓存、监听器和覆盖层都留在
App SDK 内存中；Dart 不接收、保存或上报 FPS/延迟指标。性能浮层唯一由 App SDK
创建和维护，Game SDK 不创建或保留旧浏览器性能 panel。

## Feature 约定

每个 Feature 应围绕一个稳定功能域，例如：

```text
game.session
game.binary
game.sync
game.storage-lifecycle
app.capability
app.performance
app.ui
app.device
```

一个 Feature 不应仅为缩短文件而创建，也不能同时拥有多个无关业务域。

终端媒体分为公共入口和具体协议适配器。`playmesh.app.media.open()`、公共 Dart
运行时、源签发和生命周期属于 `app.media`；SDP、ICE、PeerConnection 等 WebRTC
细节只属于 WebRTC 适配器。公共 `AppMediaSourceRequest` 固定拆分为：

```text
producer / kind
  => 公共选择条件

sourceOptions
  => 分辨率、帧率等协议无关源需求

adapterOptions
  => 公共层不读取的不透明对象，仅由被选中的适配器定义和校验
```

新增媒体协议时必须实现并注册 `AppMediaAdapter`，并在 App SDK 中注册同协议名的网页
消费适配片段。公共运行时不得按 WebRTC、RTSP 等协议增加 `switch`，能力插件也不得
直接创建 PeerConnection 或公开适配器私有 ID。公共源描述符只用于同一页面运行时内
的受控转交，不是 URL，也不能跨页面或跨终端复用。

平台 UI 命令必须作为独立 App Feature 注册，并由 App SDK 与宿主分别校验权限。
例如 `app.ui.openSharePanel` 在网页侧检查用户激活，宿主侧再次
检查当前前台 WebView、Authority、用户激活和 UI 可用性；错误使用稳定机器 code，
且不得把分享 Token、URL 或二维码内容返回给游戏。打开前由 SDK 同步保存游戏
DOM 焦点，关闭后宿主只发送注册表内部的 `platform.ui.restoreGameFocus` 消息；
它不进入 TypeScript、Schema、补全或公开返回值。已打开请求只重聚焦现有关闭按钮，
关闭后 800 ms 内的 SDK 重开以 `rate_limited` 节流。

新增功能时：

1. 在 `features/game/` 或 `features/app/` 新建 Feature，并使用
   `part of '../../sdk_feature_registry.dart';` 接入同一 Dart library。
2. 定义 `SdkSourceFragment`。`id` 在全部片段中唯一；`target` 必须等于
   `SdkSourceTarget.game` 或 `SdkSourceTarget.app`；同一 target 下 `order` 唯一。
3. 在 `typeScript` 内实现公开方法、参数前置校验、`request/post` 命令和声明模板。
   需要宿主执行时，网页发送的命令字符串必须与执行器 `commands` 中的字符串完全相等。
4. 在同一文件实现 `_GameSdkCommandFeature` 或 `_AppSdkCommandFeature`：
   `source` 返回该片段，`supportedVersions` 声明执行器适用 Bundle，`commands`
   声明全部宿主命令，`execute()` 只处理这些命令。
5. 在 `sdk_feature_registry.dart` 增加 `part`；把执行器实例加入
   `_gameCommandFeatures` 或 `_appCommandFeatures`；把片段加入
   `sourceFragments`。三处缺一都不算完成注册。
6. 如果公开签名变化，更新 Feature 内声明模板和版本；如果消息、返回、事件或错误语义
   不兼容，替换当前精确发行定义并同步更新执行器，不保留旧清单解析或旧命名空间 shim。
7. 执行 `node tool/generate_sdk.mjs`，同步静态 SDK、Manifest、Schema、默认模板和
   提示词；再运行 SDK 注册表、浏览器、声明和单一源契约测试。
8. 不在 Bridge、网关或生成器中增加功能专用旁路。

注册表初始化时按以下条件判断是否允许启动：

```text
fragment.id 已存在
  => 失败：重复 Feature ID

"${fragment.target.name}:${fragment.order}" 已存在
  => 失败：同 target 的 order 重复

fragment.typeScript.trim().isEmpty
  => 失败：没有网页源

同一 command 的任意两个 supportedVersions 区间相交
  => 失败：同版本存在多个执行器

release.minimumRequestedVersion != release.bundleVersion
或 release.maximumRequestedVersion != release.bundleVersion
  => 失败：当前发行不是精确版本

同一 target 注册多个当前 release
  => 失败：当前版本解析不唯一
```

## 完整调用链与精确分发条件

### 1. 网页封包

Game SDK `post()` 和 App SDK `request()` 都生成唯一 `requestId`，并发送：

```json
{
  "command": "稳定命令名",
  "requestId": "本次调用 ID",
  "sdkVersion": "实际 Bundle 版本",
  "payload": {}
}
```

Game SDK 等待宿主回包的默认超时为 15 秒；App SDK 为 30 秒。传输对象不存在时立即
拒绝。App WebView 选择 `PlaymeshAppBridge.postMessage` 或
`chrome.webview.postMessage`；Game WebView 选择 `PlaymeshBridge.postMessage`
或 `chrome.webview.postMessage`。

### 2. Bridge 解析

Bridge 的判断顺序固定为：

```text
jsonDecode(rawMessage) 不是 Map
  => invalid command

command 不是非空 String
  => invalid command

payload 是 Map
  => Map<String, Object?> 副本
payload 不是 Map
  => 空 Map

sdkVersion 存在但不是 String
  => 失败："sdkVersion 必须是字符串"
```

Bridge 只构造 `GameSdkCommandContext` 或 `AppSdkCommandContext`，随后调用
`SdkFeatureRegistry.dispatchGame()` 或 `dispatchApp()`。

### 3. 版本选择与命令命中

版本选择不是“找最接近版本”，而是严格当前版本判断：

```text
requestedVersion == null
  => 仅供宿主内部读取当前 SDK 文件时使用当前 release.bundleVersion；
     main.json 不允许省略版本

requestedVersion 不匹配 MAJOR.MINOR.PATCH
  => 失败

requestedVersion == 当前 target 的 release.bundleVersion
  => 命中当前 release

其他值
  => UnsupportedError，不解析旧版本，不回退
```

命中发行版后执行精确 Map 查询：

```text
Game: release._gameCommands[command.name]
App:  release._appCommands[command.name]
```

只有 key 与 `command.name` 完全相等才执行该 Feature；查不到就返回“未注册命令”。
随后 Feature 的 `switch (command.name)` 再做一次精确分支，参数和业务前置条件在该
分支或注入的宿主 callback 中校验。例如：

```text
command.name == "app.ui.openSharePanel"
且 command.payload["userActivation"] == true
  => context.openSharePanel()

command.name == "app.ui.gameSidebar.show"
  => context.setGameSidebarVisible(true)

command.name == "app.ui.gameSidebar.hide"
  => context.setGameSidebarVisible(false)
```

分享功能还会在 App 页面 callback 再判断当前 View、Authority、用户激活、UI 是否
可用及节流状态；Feature 命中不代表这些业务门禁自动通过。

### 4. 执行结果与网页 Promise

Game 执行器有三种返回：

```text
SdkCommandResult(value)
  => command.result + 相同 requestId

SdkCommandMessage(message)
  => 原样发送自定义协议消息

SdkCommandDeferred()
  => 暂不回包，由远端存储等异步链路稍后用原 requestId 完成
```

App 执行器返回值统一包装成 `app.command.result`。异常包装成
`command.error` 或 `app.command.error`；`SdkCommandException.code` 会保留为稳定
机器 code。网页接收器只有在：

```text
message.type 等于对应 result/error 类型
且 pending 中存在 message.requestId
```

时才 resolve/reject 原 Promise；未知类型或未知 `requestId` 静默忽略。能力事件、
输入事件和运行时事件使用各自明确的 `message.type` 分支，不冒充命令回包。

### 5. 生成与对外消费

`sourceFragments` 先按 `target` 分组，再按 `order` 升序拼接。声明模板提取为
`.d.ts`，剩余网页源生成 `.js`；Game/App 版本来自各自 Feature 源中的版本常量。
App/Game 资源请求、Developer API、AI 提示词、编辑器补全和 SDK 下载随后都调用
`SdkFeatureRegistry.sdkFile()` 或其公开路径封装，因此只有注册表命中的发行版会被
实际提供。


## 版本与精确发行

游戏通过 `main.json.sdkVersion/appSdkVersion` 请求 SDK。稳定资源分别为
`/playmesh/sdk/v1/playmesh-main.js` 与 `/playmesh/sdk/v1/playmesh-app.js`；
`/playmesh/sdk/v1/` 中的 `v1` 不是语义版本，旧 `playmesh.js` 不回退。

解析链：

```text
requestedVersion
  -> SdkRelease 精确版本
  -> bundleVersion + 对应 SDK 文件
  -> SDK 消息携带实际 bundleVersion
  -> 版本化命令索引
  -> 对应 Dart 执行器
```

规则：

- 当前 Game SDK 只接受 `4.0.0`，App Bridge SDK 只接受 `3.2.0`。
- 旧版本、未知版本或格式错误版本直接失败，不静默回退，也不转换旧清单。
- 每个 target 只能注册一个当前精确发行；其
  `minimumRequestedVersion == maximumRequestedVersion == bundleVersion`。
- 执行器的 `supportedVersions` 只约束当前实际 Bundle 的命令分发，不能扩大 Manifest
  可接受版本。
- 参数、消息、返回值、事件或错误语义不兼容时升级版本并整体替换当前发行定义；
  不保留历史发行、旧命名空间 shim 或 Bridge 旁路。
- 未变化的 Feature 继续复用公共实现，不复制整套 SDK。

## SDK 消费入口

以下入口必须通过 `SdkFeatureRegistry`：

- App 本地游戏资源网关；
- 普通浏览器分享网关；
- Authority 分享网关中的标准 Game/App SDK 资源；
- Developer Gateway 公共资源；
- SDK Bundle 下载；
- AI 项目提示词和 `.d.ts`；
- Manifest 精确版本校验；
- Game/App Bridge 命令分发。

新增消费入口时，必须加入单一源架构断言。禁止从 `rootBundle`、文件系统或测试参数
注入另一份 SDK。

## WebView 平台 UI 国际化

Game SDK 提供能力确认与浏览器昵称层；App SDK 提供菜单、信息、日志和唯一的性能
覆盖层，Game SDK 不创建浏览器性能 panel。
这些界面都是平台 UI，不是游戏内容。它们的唯一文案源是 App locale 对应
`app.json` 中的 `platform.game.*`；
SDK Feature、生成的 JavaScript 和浏览器配置不得包含语言表、`zh/en` 分支或另一套
可见 fallback。

App WebView 链路固定为：

```text
当前 PlaymeshLocalizations
  -> 截取并去除 platform.game. 前缀的 locale/messages
  -> 写入不可枚举的私有 Symbol runtime
  -> 对应 SDK 消费平台 UI 投影
  -> playmesh.app.ready 完成当前终端公开就绪
```

普通浏览器分享网关从同一 localization manifest 与 `app.json` 读取并注入全部启用
语言的受限投影；Game SDK 按 `navigator` 语言为覆盖层做精确/主语言匹配和 fallback，
消费后删除临时配置。页面已经打开时，App 通过私有 `platform.ui.configure` 推送新
投影和当前有效明暗主题，SDK 只更新自身 Shadow DOM 的 `lang`/`data-theme` 状态，
不重载游戏、不翻译游戏内容，也不改变根聚合入口 `playmesh.ready`、SDK 方法、事件或
API JSON。App WebView 使用当前显示 App 的有效 `light/dark`；普通浏览器配置使用
`system` 并监听 `prefers-color-scheme`。能力确认、浏览器工具/昵称/信息/日志和
App 性能浮层共用该私有主题输入，不建立第二份偏好。

该私有 `Symbol` runtime 是宿主到平台 UI 的配置通道，不进入 `.d.ts`、SDK Manifest、
游戏提示词或游戏可调用 API，也不得投影为 `playmesh.main`/`playmesh.app` 的
`__*` 成员。投影只能包含 `platform.game.*` 命名空间；游戏脚本不得读取完整
App 词典。新增平台 UI 文案时先补齐所有启用 locale 的 `app.json`，再更新所需 key
断言和渲染代码。

游戏业务只获得独立的公开只读 `playmesh.app.runtime.getLocale(): string`，并且只能在
根 `playmesh.ready` 完成后调用；`main.ready` 内部先等待 `app.ready`，根 ready
只复用这条初始化链。App WebView 的
返回值来自当前显示/加入方 App，而不是
Authority 主机；普通浏览器直接返回 `navigator.languages`、`navigator.language`
中第一个合法系统 locale，读取失败固定回退 `zh`，不受平台覆盖层可用语言限制。
该方法不返回 messages，也不能成为读取 `platform.game.*` 投影的旁路。游戏自行
打包和选择业务翻译，平台不修改游戏 DOM。浏览器平台覆盖层仍独立按其可用 locale
做精确/主语言匹配并最终回退 `zh-CN`。

## 生成与发布

日常 `flutter run` 直接使用注册表即时组装内容，不要求先生成静态文件。

正式构建前，统一发布脚本调用生成器，更新：

- `sdk-src/*.ts`；
- `public/sdk/v1/*.js`；
- `public/sdk/v1/*.d.ts`；
- SDK Manifest 与 Schema；
- 默认项目 `main.json`；
- 接口语义确实变化时需要同步的提示词内容。

AI 项目提示词只拼接开发语义、项目上下文和完整类型声明，不承担独立 SDK 版本元数据。
嵌入的 `playmesh-main.d.ts` 与 `playmesh-app.d.ts` 已包含版本和完整接口定义；
`common.txt`、`agent-common.txt` 等公共模板保持纯净。

生成器必须比较网页实际发送命令和 Dart 执行器集合，发现缺失、陈旧或重复命令时失败。
新的正式构建入口也必须执行同一生成步骤。

Game SDK 内引用 App SDK 版本时只保留 `__PLAYMESH_APP_SDK_VERSION__` 手写占位符。
注册表即时组装与 Node 正式生成都从同一批次 App SDK bundle 读取版本，并同时替换
Game SDK 的 `.ts`、`.js`、`.d.ts`；不得写死当前版本或构造 `*-empty` 版本。

## 公开契约变化

修改公开 SDK 时同步评估：

- Game SDK 或 App Bridge SDK 版本；
- 精确发行版本和执行器范围；
- `.d.ts` 与中文 JSDoc；
- SDK Manifest、Schema 和开发文档；
- 默认项目模板；
- AI 提示词和编辑器补全；
- App、Developer API 或 Core 协议是否真正受影响。

不要因为 App 版本变化而机械升级 SDK，也不要在公开签名未变化时制造无意义新执行器。

## 验证清单

- Source Fragment ID 和顺序唯一。
- 网页发送命令与执行器集合一致。
- 同版本同命令只能命中一个执行器。
- 未注册版本和非法版本被拒绝。
- Game `4.0.0` 与 App `3.2.0` 能选择当前执行器，旧清单版本被拒绝。
- `.js` 不包含声明模板，`.d.ts` 不包含版本占位符。
- Game SDK `.ts/.js/.d.ts` 中的 App SDK 版本一致且不残留跨目标占位符。
- 所有运行时和开发者入口返回注册表即时组装内容。
- 生成物、Manifest、Schema 与模板使用同一注册表版本；提示词模板只包含开发语义和
  项目上下文，版本与接口事实来自嵌入的 `.d.ts`。
- 平台 UI 只消费 `app.json` 的 `platform.game.*` 投影，bootstrap/config 消费后删除，
  语言或主题切换只更新平台 Shadow DOM，不影响游戏内容或公开 SDK 就绪语义。
- `runtime.getLocale()` 只返回显示端 locale；App/浏览器选择规则、Authority 隔离和
  公开值 `zh` 失败回退都有契约测试，且任何路径都不向游戏公开 messages；App 提供的
  浏览器覆盖层再独立回退 `zh-CN`。
- 回滚 App 时同时回滚注册表与同次生成产物，不能只替换静态 JS。
