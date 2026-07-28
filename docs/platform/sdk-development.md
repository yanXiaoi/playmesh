# SDK 开发约定

本约定适用于 Game SDK、App Bridge SDK、网页运行片段、Dart 宿主执行器和 SDK
兼容发行版。游戏作者 API 见 [Game SDK / App Bridge SDK](../game/sdk-v1.md)。

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
- 注册 Game/App SDK 兼容发行版；
- 根据游戏声明解析 SDK Bundle；
- 根据消息携带的实际 Bundle 版本选择对应执行器；
- 拒绝未知版本、重叠发行范围和同版本重复执行器；
- 为网关、Developer API、AI 提示词和 SDK 下载提供同一内容。

Bridge 只负责消息解析、上下文构造、统一分发和响应，不重新维护命令 `switch`。

## 当前公开 SDK 方法

当前 Game SDK 为 `3.0.0`，App Bridge SDK 为 `3.0.0`。下表是当前公开面；
精确参数、泛型、返回类型和中文 JSDoc 仍以注册表生成的 `playmesh.d.ts` 与
`playmesh-app.d.ts` 为准。

| 命名空间或句柄 | 当前公开成员 |
| --- | --- |
| `playmesh` | `version`、`ready` |
| `playmesh.app` | `version`、`ready`、`isAvailable()`、`openSharePanel()`、`showGameSidebar()`、`hideGameSidebar()`、`exitGame()` |
| `playmesh.app.identity` | `getCurrent()` |
| `playmesh.app.capabilities` | `getRegistry()`、`getAvailable()`、`getDeclared()`、`create()` |
| `CapabilityHandle` | `id`、`code`、`apiVersion`、`invoke()`、`on()`、`onError()`、`dispose()` |
| `playmesh.app.device` | `getPlatform()`、`setFullscreen()`、`onInput()` |
| `playmesh.runtime` | `getLocale()` |
| `playmesh.session` | `getCurrent()`、`onStateChange()`、`onPlayerJoin()`、`onPlayerLeave()`、`onPlayerReconnect()`、`isAuthority()`、`start()`、`finish()` |
| `playmesh.player` | `getCurrent()`、`setNickname()` |
| `playmesh.game` | `submitAction()`、`onMessage()`、`onEvent()`；`onEvent()` 是兼容别名 |
| `playmesh.authority` | `onService()` |
| `playmesh.binary` | `authorityPlayerId`、`createChannel()`、`joinChannel()` |
| `BinaryChannel` | `id`、`mode`、`send()`、`sendLatest()`、`onMessage()`、`onForward()`、`close()` |
| `playmesh.sync` | `startAuthority()`、`submitAction()`、`submitState()`、`requestSnapshot()`、`getSnapshot()`、`observe()` |
| `SyncAuthorityController` | `getState()`、`setState()`、`publish()`、`stop()` |
| `playmesh.lifecycle` | `onChange()`、`onPause()`、`onResume()`、`onExit()` |
| `playmesh.performance` | `reportFrame()`、`getFps()`、`onFps()`、`getLatency()`、`getLatencyDiagnostics()`、`onLatency()`、`setVisible()` |
| `playmesh.storage` | `getBucket()` |
| `StorageBucket` | `getData()`、`setData()`、`removeData()`、`clearData()`、`upload()` |

公开方法不等于宿主命令。`version`、bootstrap getter、缓存 getter、监听器注册和部分
网页状态方法只操作 SDK 内存；只有最终调用 `post(command, ...)` 或
`request(command, ...)` 的路径才进入 Dart Bridge。普通浏览器中的
`game.submitAction`、`performance.ping`、`performance.latency` 还会在
`command` 与这三个值之一完全相等时改走浏览器 WebSocket，不进入 App WebView
Bridge。

## Feature 约定

每个 Feature 应围绕一个稳定功能域，例如：

```text
game.session
game.binary
game.sync
game.performance
game.storage-lifecycle
app.capability
app.ui
app.device
```

一个 Feature 不应仅为缩短文件而创建，也不能同时拥有多个无关业务域。

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
   不兼容，封口旧 `SdkVersionRange`，再注册不重叠的新执行器。
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

release.minimumRequestedVersion > release.maximumRequestedVersion
  => 失败：发行范围无效

相邻同 target release 的新 minimum <= 旧 maximum
  => 失败：发行范围重叠
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

版本选择不是“找最接近版本”，而是严格范围判断：

```text
requestedVersion == null
  => 使用该 target 最后一个 release.bundleVersion

requestedVersion 不匹配 MAJOR.MINOR.PATCH
  => 失败

requestedVersion >= release.minimumRequestedVersion
且 requestedVersion <= release.maximumRequestedVersion
  => 命中该 release

所有 release 都不满足
  => UnsupportedError，不回退最新版
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


## 版本与兼容发行版

游戏通过 `main.json.sdkVersion/appSdkVersion` 请求 SDK。资源路径
`/playmesh/sdk/v1/` 是稳定 URL，其中的 `v1` 不是语义版本。

解析链：

```text
requestedVersion
  -> SdkRelease 兼容范围
  -> bundleVersion + 对应 SDK 文件
  -> SDK 消息携带实际 bundleVersion
  -> 版本化命令索引
  -> 对应 Dart 执行器
```

规则：

- 未注册或格式错误版本直接失败，不静默回退最新版。
- 兼容发行范围不能重叠；是否允许空洞必须由当前发布策略明确决定。
- 调用契约未变化的执行器使用 `SdkVersionRange.last` 开放上界。
- 参数、消息、返回值、事件或错误语义不兼容时，封口旧执行器范围并注册新实现。
- 相同命令名可以有多个历史执行器，但同一个 Bundle 只能命中一个。
- 未变化的 Feature 不复制到新版本目录。
- 旧发行版一旦用于已发布游戏，应保持不可变；修正应通过新的兼容发行定义完成。

未来不兼容版本只在受影响域增加例如 `features/game/v3/` 的新实现，不复制整套 SDK。

## SDK 消费入口

以下入口必须通过 `SdkFeatureRegistry`：

- App 本地游戏资源网关；
- 普通浏览器分享网关；
- 本地 App SDK 服务；
- Developer Gateway 公共资源；
- SDK Bundle 下载；
- AI 项目提示词和 `.d.ts`；
- Manifest 版本兼容校验；
- Game/App Bridge 命令分发。

新增消费入口时，必须加入单一源架构断言。禁止从 `rootBundle`、文件系统或测试参数
注入另一份 SDK。

## WebView 平台 UI 国际化

Game SDK 提供的能力确认、浏览器工具栏、昵称、信息和日志界面是平台 UI，不是游戏
内容。它们的唯一文案源是 App locale 对应 `app.json` 中的 `platform.game.*`；
SDK Feature、生成的 JavaScript 和浏览器配置不得包含语言表、`zh/en` 分支或另一套
可见 fallback。

App WebView 链路固定为：

```text
当前 PlaymeshLocalizations
  -> 截取并去除 platform.game. 前缀的 locale/messages
  -> 私有 _playmeshPlatformUi bootstrap
  -> Game SDK 消费后立即删除 bootstrap
  -> playmeshApp.ready 继续原有公开就绪语义
```

普通浏览器分享网关从同一 localization manifest 与 `app.json` 读取并注入全部启用
语言的受限投影；Game SDK 按 `navigator` 语言为覆盖层做精确/主语言匹配和 fallback，
消费后删除临时配置。页面已经打开时，App 通过私有 `platform.ui.configure` 推送新
投影和当前有效明暗主题，SDK 只更新自身 Shadow DOM 的 `lang`/`data-theme` 状态，
不重载游戏、不翻译游戏内容，也不改变公开 `playmesh.ready`、SDK 方法、事件或
API JSON。App WebView 使用当前显示 App 的有效 `light/dark`；普通浏览器配置使用
`system` 并监听 `prefers-color-scheme`。能力确认、浏览器工具/昵称/信息/日志和
App 性能浮层共用该私有主题输入，不建立第二份偏好。

该桥接是宿主到平台 UI 的私有配置通道，不进入 `.d.ts`、SDK Manifest、游戏提示词
或游戏可调用 API。投影只能包含 `platform.game.*` 命名空间；游戏脚本不得读取完整
App 词典。新增平台 UI 文案时先补齐所有启用 locale 的 `app.json`，再更新所需 key
断言和渲染代码。

游戏业务只获得独立的公开只读 `playmesh.runtime.getLocale(): string`，并且只能在
`playmesh.ready` 后调用。App WebView 的返回值来自当前显示/加入方 App，而不是
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
- 需要同步的提示词和版本摘要。

生成器必须比较网页实际发送命令和 Dart 执行器集合，发现缺失、陈旧或重复命令时失败。
新的正式构建入口也必须执行同一生成步骤。

Game SDK 内引用 App SDK 版本时只保留 `__PLAYMESH_APP_SDK_VERSION__` 手写占位符。
注册表即时组装与 Node 正式生成都从同一批次 App SDK bundle 读取版本，并同时替换
Game SDK 的 `.ts`、`.js`、`.d.ts`；不得写死当前版本或构造 `*-empty` 版本。

## 公开契约变化

修改公开 SDK 时同步评估：

- Game SDK 或 App Bridge SDK 版本；
- 兼容发行范围和执行器范围；
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
- 旧、新 Bundle 能选择各自执行器。
- `.js` 不包含声明模板，`.d.ts` 不包含版本占位符。
- Game SDK `.ts/.js/.d.ts` 中的 App SDK 版本一致且不残留跨目标占位符。
- 所有运行时和开发者入口返回注册表即时组装内容。
- 生成物、Manifest、Schema、模板和版本摘要一致。
- 平台 UI 只消费 `app.json` 的 `platform.game.*` 投影，bootstrap/config 消费后删除，
  语言或主题切换只更新平台 Shadow DOM，不影响游戏内容或公开 SDK 就绪语义。
- `runtime.getLocale()` 只返回显示端 locale；App/浏览器选择规则、Authority 隔离和
  公开值 `zh` 失败回退都有契约测试，且任何路径都不向游戏公开 messages；App 提供的
  浏览器覆盖层再独立回退 `zh-CN`。
- 回滚 App 时同时回滚注册表与同次生成产物，不能只替换静态 JS。
