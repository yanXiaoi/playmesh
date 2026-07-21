# 技术架构

## 总体架构

```text
Flutter App
  - 首页 / 游戏库 / 游戏详情 / 游戏页 / 设置 / 控制端 / WebView 游戏容器
  |
  | Platform Channel / Pigeon
  v
Native Adapters
  - Android: Kotlin
  - iOS: Swift
  - Desktop: native bridge later
  |
  v
Go Core
  - HTTP server
  - WebSocket hub
  - Session membership and relay
  - Join code and QR/link payload
  - Package store
  - Protocol routing
  |
  v
HTML Game Runtime
  - WebView
  - Game SDK
  - Sandboxed permissions
```

## 当前实现边界

当前代码已完成第一至第六阶段并归档；第六阶段之后改用版本日志维护，当前正式基线为 Playmesh `1.6.1+8`。

```text
已经完成：
Flutter 页面、游戏详情、跨平台本地 WebView、运行时刷新与屏幕方向边界
Go Core 生命周期、动态端口、HTTP/WS 会话、Authority 路由、Android AAR 和 Windows 内置进程
Game SDK、`main.json` 校验、统一游戏目录扫描和浏览器控制器分享入口
开发者模式独立固定端口、持久 token 与工作区路径、项目创建与编辑、项目级本地历史、运行入口、SSE 日志和机器可读文档
Go Developer CLI、项目整包拉取/原子发布、同源 SDK/类型同步与外部 IDEA 日志跟随

第五阶段已完成：
可配置 game/controller/authority 入口、轻量权威状态同步、联机延迟、统一游戏包导入/导出、工作区文件管理、正式版响应式 App 与全平台游戏/控制器全屏

第六阶段已完成：
可选且不阻塞运行的全屏、Android 外部文件与导出链路、无需预装游戏的 App 加入、Game SDK/App Bridge 双层边界、App/浏览器持久身份、单 ID 连接约束、离线成员与重连事件、移动工作区和界面切换性能收口
```

`go-core/` 已提供可启动、可停止的 HTTP 服务。宿主必须使用 `0.0.0.0:0` 请求系统分配空闲端口，并在启动成功后把实际端口上报给 Flutter；Flutter 本机连接时使用回环地址，分享时使用当前设备全部可用的局域网 IPv4 地址。页面不得猜测、缓存固定端口或自行拼接 Core 地址。

网页开发者通道不复用或重绑 Core 端口。Flutter App 另行启动 `DeveloperWebGateway`，按当前产品决策绑定 `0.0.0.0`，默认端口为 `16666`，用户可在设置页修改；设置页只发布当前设备解析到的局域网 IPv4 链接。Developer API status 同时返回当前请求地址、解析到的局域网 IPv4 与回环地址，Agent 提示词只能从这些本机 HTTP Base URL 中选择一个嵌入接口清单，避免把持久开发者 token 指向任意外部地址。端口被占用时返回明确错误，不得通过重启 Core 解决。关闭开发者模式或 App 退出时只关闭开发者 Gateway，不中断现有 Core 会话。

Developer CLI 是 Gateway 的客户端，不是第二个游戏运行时。CLI 从完整工作区 URL 解析 Base URL 和 token，通过标准包导出接口拉取 `main.json + capabilities.json + app/`，并通过 SDK bundle 接口建立 `playmesh/sdk/`。本地 `app/`、`playmesh/` 分别直接镜像运行时 `/app/`、`/playmesh/`，使 IDEA 能解析 JS/CSS/HTML 绝对路径。上传时只打包 `main.json + capabilities.json + app/`，`playmesh/` 永远排除，再复用应用正式游戏包导入器完成校验和提交。App 游戏安装目录不创建 CLI 辅助目录。

CLI 二进制统一命名为 `playmesh-cli`（Windows 使用 `.exe`）。桌面平台构建将它作为 App 运行包的一部分：Windows/Linux 由 CMake 追踪 Go 源并安装到 bundle 根目录，macOS 由 Xcode Build Phase 放入 `Contents/MacOS/`；位置均与桌面 Go Core 的运行目录同级。Android/iOS 不编译或携带 CLI。

## Go Core 与游戏权威边界

Go Core 是通用中转服务器，不是游戏服务器。它只负责连接、会话成员、角色凭证、消息转发，以及消息大小、连接频率、会话带宽和基础序列检查。Go Core 不生成游戏题目，不验证游戏答案，不计算分数，不推进回合，也不决定胜负。

每个联机会话都必须登记独立的 `authorityClientId`。Authority Client 运行游戏自己的权威逻辑，负责验证动作、生成题目、推进状态和结算分数；Go Core 只路由。`players` 只表示实际参与游戏的玩家，是否包含创建者由显示模式决定：

- `single_screen_multiplayer`：创建会话的 App 主机是公共显示端与 Authority Client，不属于 `players`，不占人数名额，也不能以主屏身份提交玩家动作。所有玩家只能通过 `app/controller/index.html` 加入。
- `multi_screen`：创建会话的 App 游戏运行端固定为 Authority Client，并可同时作为 Player 出现在 `players` 中、计入人数；它是否恰好位于玩家数组首位没有 Authority 语义，后续任何加入者都只是普通 Player。

游戏包可以按需在 `app/static/js/service/` 中组织 Authority 逻辑；该目录是推荐约定，不是运行时强制要求。无论采用什么目录结构，权威逻辑都必须由游戏自己实现，不能下沉到 Go Core。

MVP 不自动转移 Authority。Authority Client 断开时，游戏必须暂停或结束当前对局，并向所有客户端报告明确原因；后续迁移必须单独定义状态快照、任期号、冲突处理和恢复协议。

## 游戏权威服务入口

为了让游戏开发者能够组织联机逻辑，平台可以约定一个可选的权威服务入口，例如 `app/static/js/service.js` 或 `app/static/js/service/index.js`。该文件由 Authority Runtime 加载，不由 Go Core 解析执行。游戏 SDK 向它提供统一的上下文：

```ts
type AuthorityContext = {
  sessionId: string;
  authorityClientId: string;
  players: PlayerSession[]; // 由 SDK 注入的当前房间成员快照
  now(): number;
};

type AuthorityService = {
  onService(action: PlayerAction, context: AuthorityContext): AuthorityResult;
};

type AuthorityResult =
  | { targetPlayerIds: string[]; payload: unknown }
  | { targetPlayerIds: []; payload?: never };
```

权威处理端的启动和调用链固定如下：

```text
创建者启动游戏
  -> App 创建会话并写入 authorityClientId
  -> 根据 displayMode 决定创建者是否同时加入 players
  -> entries.game（默认 app/index.html）预先引入 service 入口
  -> 初始化脚本调用 SDK 判断当前客户端是否为 Authority Client
  -> 只有 Authority Client 初始化 service 监听
  -> Go Core 转发玩家 action
  -> SDK 调用 playmesh.authority.onService()
  -> service 返回 targetPlayerIds 和 payload
  -> Go Core 定向转发或不发送
```

权威处理端与玩家页面可以共用主机 WebView 的 JS 进程，但必须使用独立模块、独立状态和 Authority SDK。后续如需更强隔离，再替换为 Worker、独立进程或受限脚本运行时，不能改变游戏侧的 Authority SDK 契约。service 代码本身仍不能操作玩家页面全局对象。

默认模板必须在 `app/index.html` 的初始化脚本中预先完成角色判断和权威处理注册。开发者不需要手写这段接入逻辑，只修改标记为 TODO 的业务代码：

```js
import { createAuthorityService } from "./static/js/service/index.js";

async function bootstrap() {
  // TODO：初始化主屏玩家界面和本地展示状态
  playmesh.game.onMessage((message) => {
    // TODO：根据权威消息更新主屏画面、动画和排行榜
  });

  if (playmesh.session.isAuthority()) {
    const service = createAuthorityService();
    playmesh.authority.onService((action, context) => {
      // TODO：实现题目、验证、计分、回合和状态分发
      return service.handle(action, context);
    });
  }
}

bootstrap();
```

实际 SDK 应提供稳定的角色判断 API，例如 `playmesh.session.isAuthority()`，以及 `playmesh.authority.onService()`、`playmesh.game.submitAction()` 和 `playmesh.game.onMessage()`。游戏代码不应自行猜测房主、连接顺序或读取底层 WS 字段。

## 游戏生命周期 API

SDK 不需要提供单独的启动回调。WebView 执行 `main.json.entries.game` 或 `entries.controller` 指向页面的脚本本身就是游戏启动入口；两者未声明时分别默认 `app/index.html` 与 `app/controller/index.html`。默认模板负责完成 SDK 初始化和处理器注册。

SDK 必须提供由 App 主动触发的生命周期通知：

```ts
playmesh.lifecycle.onPause(handler);
playmesh.lifecycle.onResume(handler);
playmesh.lifecycle.onExit(async (context) => {
  // TODO：保存数据、清理资源并完成退出前操作
});
```

`onExit` 在 App 销毁 WebView、退出游戏或切换到游戏库前触发。SDK 应允许异步处理，但必须设置有限超时、保证最多执行一次并允许重复调用时安全返回；超时后 App 可以继续退出，不能因为游戏代码卡住而阻塞整个应用。游戏不得只依赖 `onExit` 保存关键数据，应在关键状态变化后及时写入 SDK 存储或游戏包允许的用户数据目录，因为系统强制结束、崩溃和断电可能不会触发退出回调。

`app/controller/index.html` 的默认模板也应自动注册 `playmesh.game.onMessage()`，并提供输入提交 TODO。开发者只填写控制器 UI 和动作数据，不需要理解消息来自哪条 WS 或如何寻找目标玩家。

权威服务只能通过上下文获得以下信息：当前会话 ID、Authority Client ID、发送者玩家 ID、当前玩家成员快照、动作序列号、服务时间和必要的游戏持久化状态。它不能获得原始 WebSocket、Flutter 对象、文件系统路径、任意网络访问或其他游戏包内容。

所有玩家的游戏动作先经过 SDK 和 Go Core 的会话层校验，再由 SDK 路由到权威端的 `playmesh.authority.onService`。Go Core 向 SDK 注入可信的 `senderPlayerId` 和当前房间成员快照。权威服务只需要返回目标玩家 ID 列表和消息，或返回空目标列表表示不发送，不需要理解 Go Core 的路由细节。回复一个玩家时列表只有一个 ID，回复多个玩家时列表包含多个 ID，广播时由 SDK 提供当前在线玩家 ID 列表或提供等价的 `broadcast` 辅助方法。

只有权威服务可以发布 `authoritativeState` 或 `authoritativeEvent`；Go Core 只根据目标列表转发或丢弃，不理解其业务内容。SDK 应自动注入 `sessionId`、发送者 `playerId`、连接标识、序列号和接收时间，游戏服务不能信任客户端自行填写的身份字段。底层 `conn` 只用于 Go Core 内部路由和诊断，不注入游戏代码。

因此 AI 生成联机游戏时只需要理解三个业务入口：玩家用 `playmesh.game.submitAction(action)` 发送动作，用 `playmesh.game.onMessage(handler)` 接收已路由给自己的业务消息；权威端用 `playmesh.authority.onService(handler)` 接收所有动作并返回目标玩家列表。SDK 自动处理 WS、身份注入、目标路由和消息分发。底层 `onWs` 和分发函数只能作为 SDK 内部或高级诊断接口，不进入默认模板和 AI 生成提示词。

必须区分两种“分发”：

- **协议分发**：权威处理端通过返回 `targetPlayerIds` 表达目标玩家，SDK/Go Core 根据目标列表将消息送给指定玩家或丢弃；开发者可以指定目标列表，但不能接管连接级分发。
- **业务处理**：当前页面收到消息后如何更新 UI 或本地展示，由开发者在 `playmesh.game.onMessage(handler)` 中完成。

普通玩家端只需要 `playmesh.game.onMessage(handler)`。权威端必须使用 `playmesh.authority.onService(handler)` 返回目标列表和业务载荷；SDK 后续可以提供 `playmesh.game.on(eventType, handler)` 作为普通玩家端 `onMessage` 的语义化辅助，但它只是本地业务订阅，不改变底层路由模型。

Authority Client 不需要建立两个物理 WebSocket。主机通常只维护一条与 Go Core 的 WS：

```text
single_screen_multiplayer
  - authority 通道：公共显示端接收玩家动作，调用 service.js，发布权威状态和事件
  - 没有主机 player 通道，公共显示端不在 players 中

multi_screen
  - player 通道：参与游戏的 App 主机以自己的 Player 身份发送动作，该身份与其独立的 App Authority 身份由 SDK 区分
  - authority 通道：同一客户端接收所有玩家动作并发布权威结果
```

SDK、App 中转和 Go Core 负责在同一连接内完成消息复用、角色路由和断线重连。权威服务不应自行创建第二条 WS，也不应直接连接 Go Core。只有未来需要独立进程隔离、独立资源配额或独立崩溃边界时，才考虑额外的权威服务连接。

该链路会增加一次 SDK/权威服务的函数调用，但权威服务在创建者本机的游戏运行时中执行，不会为每个动作增加一次远程网络往返。对于答题、提交、跳过等低频可靠动作，额外开销可以接受；对于传感器和动画状态，必须使用 SDK 的限频、合并和可丢弃状态通道，不能把每个原始 tick 都作为可靠权威事件广播。

推荐消息分类：

- `action`：答题、跳过、开始、准备等用户意图，可靠、有序，进入权威服务。
- `state`：玩家位置、钓鱼动画、传感器采样等当前状态，可合并、限频、丢弃旧值。
- `event`：得分、捕获、回合结束等需要被观察的结果，由权威服务产生，可靠且带版本号。

这里的“连接标识”只用于当前连接的路由和诊断，不应作为永久身份或业务主键暴露给游戏逻辑。断线重连后连接标识可以变化，但 `playerId` 和会话权限必须由 App/SDK 重新确认。

## 游戏页布局原则

游戏库只负责展示游戏并提供明确的“查看详情”操作。游戏详情页展示名称、版本、简介、人数、模式、屏幕方向和运行入口，并提供唯一的“开始游戏”操作；点击后进入独立的游戏页，不在游戏库或详情页内嵌 WebView。

进入游戏页后会并行请求当前平台全屏，移动端同时按声明的 `orientation` 请求横屏或竖屏，但游戏运行时和会话初始化不等待全屏结果。全屏是可选显示能力：请求失败时仅显示可关闭、可重试的提示，普通游戏首页和控制器首页继续加载和游玩。浏览器分享页同样使用不遮挡游戏的可选全屏浮层。离开游戏页时恢复进入前的全屏状态和系统默认方向。

Android 主 Activity 声明接收 `ACTION_VIEW` 和 `ACTION_SEND`。原生层取得系统授予的 `content://` 读取权限后，将文件复制到应用缓存并通过 `playmesh/open_file` MethodChannel 交给 Flutter：压缩包复用 Playmesh 游戏包导入校验；单个 HTML 使用独立 WebView 执行，不注入 SDK、Bridge、存储或联机能力。游戏 WebView、扫码远程 WebView 和独立 HTML WebView 的右上角悬浮工具均提供进入与退出全屏按钮。

游戏页使用全屏 WebView，让游戏内容占据整个可用区域。App 相关操作使用可拖动、可展开/收纳的窄悬浮工具坞，例如：

- 返回游戏详情
- 重新开始并刷新 WebView
- 退出到游戏库
- 打开联机信息
- 获取/复制二维码和链接
- 打开游戏设置
- 离开游戏

工具坞默认收纳，展开后显示图标命令，并允许拖到不影响游戏内容的位置；不应使用固定的大型工具栏占据游戏区域。按钮必须保持稳定尺寸，并提供无障碍语义和悬停/长按提示。FPS 默认显示在左上角，工具坞提供开关；未收到游戏帧上报时显示 `-- FPS`。

FPS 和联机延迟展示都属于 Game SDK 的网页能力，由 SDK 在当前游戏网页内部自动创建性能悬浮层并渲染，不由 Flutter App 原生层直接绘制。App 运行时的悬浮工具坞只提供显示/隐藏开关和相关设置入口，并通过 SDK 控制网页悬浮层；普通浏览器运行时没有 App 工具坞，由 SDK 自己创建可收纳、可展开的悬浮组件。浏览器组件同时提供当前玩家昵称修改入口。

FPS 由 Game SDK 统计游戏主动上报的真实渲染帧：DOM/CSS 游戏可以在自己的视觉更新循环上报，Canvas/WebGL 游戏应在实际 `draw`/present 完成后调用 `playmesh.performance.reportFrame()`。SDK 提供 `getFps()` 和 `onFps()`；平台不得额外启动独立的 `requestAnimationFrame` 并把显示器刷新回调次数冒充游戏 FPS。SDK 性能层负责网页内显示，游戏代码不负责创建 FPS 或延迟组件。

## 推荐技术栈

| 层级 | 技术 | 用途 |
|---|---|---|
| App UI | Flutter | 跨平台界面与页面流转 |
| 状态管理 | Riverpod | 房间、玩家、连接、设备状态 |
| 路由 | go_router | 首页、房间、游戏、设置导航 |
| 本地核心 | Go | HTTP、WebSocket、房间与协议 |
| Flutter/Native 桥接 | Pigeon 或 Platform Channel | 类型安全调用原生能力 |
| Android 原生 | Kotlin | 手柄、摄像头、权限、传感器 |
| iOS 原生 | Swift | GameController、摄像头、本地网络权限 |
| 游戏容器 | webview_flutter + webview_flutter_windows | 移动端/Apple 平台 WebView 与 Windows WebView2 |
| Game SDK | TypeScript | HTML 游戏访问房间、输入、生命周期 |
| 游戏包 | ZIP + `main.json` | 安装、校验、加载 |

## 模块划分

```text
lib/
  main.dart
  app.dart
  core/
    bridge/
    network/
    protocol/
    storage/
  features/
    home/
    room/
    game/
    controller/
    settings/
  widgets/
```

当前实现使用以下较小结构：

```text
lib/
  main.dart
  app.dart
  models/
    user_profile.dart
    game_summary.dart
    local_game_entry.dart
  features/
    home/
      home_page.dart
    profile/
      profile_page.dart
    games/
      game_library_page.dart
      game_detail_page.dart
    game/
      game_page.dart
      game_launcher.dart
      local_game_web_view.dart
      windows_local_game_web_view_io.dart
      game_orientation_controller.dart
    settings/
      settings_page.dart
  core/
    lifecycle/
    network/
    protocol/
    services/
```

后续只有在联机会话或原生能力形成真实复用时，再增加 `core/bridge`、Repository 或更深层次。

## Go Core 生命周期与地址上报

```text
SettingsPage
  -> GoCoreRuntime.start()
  -> GoCoreHost.start(127.0.0.1:0)
  -> Go Core 监听系统分配端口
  -> Android: gomobile Start() 返回实际地址
     Windows: core.started 结构化日志上报实际地址
  -> GoCoreClient 使用上报地址请求 GET /health
```

- Android 将 `playmesh_core.aar` 打进 App，通过 MethodChannel 调用 gomobile 导出的生命周期 API。
- Windows 将 `playmesh-core.exe` 安装到 Runner 同目录，由 Flutter 启动并读取 `core.started` 日志。
- 实际地址只在当前 Core 生命周期内有效；Core 重启后必须重新获取。
- 页面和游戏代码不得知道固定端口，HTML 游戏也不得直接访问 Core 地址。

未来仓库可以扩展为：

```text
playmesh/
  apps/
    launcher_flutter/
  core/
    lan_core_go/
  packages/
    game_sdk/
    protocol_schema/
```

## WebView 原则

WebView 只负责运行游戏页面，不直接暴露原生能力。

HTML 游戏只接触：

```ts
window.playmesh.session
window.playmesh.player
window.playmesh.game
window.playmesh.authority
window.playmesh.lifecycle
window.playmesh.storage
window.playmesh.performance
window.playmesh.app
```

`playmesh.js` 是权威主机运行时 SDK，负责会话、消息、生命周期和 Authority 主机存储。`playmesh-app.js` 是 App 本机桥接层，只由 App WebView 自动注入，负责 App 身份与本机设备能力，不属于权威主机 SDK。Console 日志由各设备的页面宿主在底层捕获，只进入本设备的运行日志流。普通浏览器不加载 App SDK，但主 SDK 会提供 `playmesh.app` 安全空实现。当前 v1 的完整接口见 `docs/game/sdk-v1.md`；App SDK 已提供加速度计和陀螺仪订阅，其他尚未实现的本机能力不能写入游戏的必需调用链。

禁止 HTML 游戏直接接触：

- 原生相机对象
- 任意文件系统
- App token
- MethodChannel
- 任意局域网端口
- 系统剪贴板和通讯录

## 游戏包结构

本节描述平台侧架构和安装实现。面向游戏作者的当前规范统一维护在 `docs/game/README.md`、`docs/game/package-format.md` 和 `docs/game/sdk-v1.md`。

游戏包暂定结构如下：

```text
game-package/
  main.json                   必须，游戏定义文件
  capabilities.json           可选，游戏需要的平台能力声明
  app/                        唯一映射到 WebView 的公开目录
    index.html                默认游戏页面入口，可由 entries.game 改为 app/ 内其他 HTML
    controller/
      index.html              默认控制器入口，可由 entries.controller 改为 app/ 内其他 HTML
    static/
      js/
        player/               可选，玩家端共享逻辑
        shared/               可选，纯数据模型和常量
        service/              权威处理端逻辑
      css/
      image/
  data/                       安装后生成，不参与静态映射
```

### 新建联机项目的默认代码框架

创建项目时，App/开发者通道必须根据项目是否支持多人生成默认代码框架。联机项目不能只生成空的 `app/index.html`，必须同时生成玩家运行层、权威处理层和共享数据层：

```text
game-package/
  main.json                         已填写 entries、authority.entry 和 displayModes
  app/index.html                    主游戏画面模板
  app/controller/index.html         控制器画面模板
  app/static/js/player/index.js     玩家端 SDK 初始化和状态订阅模板
  app/static/js/service/index.js    权威 onAction 模板
  app/static/js/shared/types.js     动作、状态和事件的共享结构模板
  data/                             SDK 持久化目录，不打入发布包
```

默认框架必须已经完成以下工作：

- 通过 SDK 建立 WS 连接，不在游戏代码中出现 WS 地址、连接创建和心跳代码。
- 自动获得当前玩家身份、`authorityClientId`、当前房间成员快照和连接状态；大屏公共显示端的 `playmesh.player.getCurrent()` 返回 `null`。
- 将玩家页面调用的 `submitAction(action)` 自动路由到权威处理端的 `onAction(action, context)`。
- 将权威处理端返回的 `targetPlayerIds` 和 `payload` 自动定向转发或广播。
- 将权威状态和事件自动分发给 `app/index.html`、`app/controller/index.html` 或其他玩家页面。
- 提供开始、暂停、恢复、玩家加入、玩家离开和权威断开等生命周期钩子。

AI 生成代码时只需要修改模板中的游戏规则区域和 UI 区域。模板必须用中文注释标识“玩家运行层可修改区域”“权威处理层可修改区域”和“禁止修改的 SDK 接入区域”，减少 AI 对底层调用链的推断。

约定：

- `entries.game` 是游戏页面入口，默认 `app/index.html`；所有游戏都必须存在最终解析出的入口文件。
- `entries.controller` 是控制器页面入口，默认 `app/controller/index.html`；游戏支持大屏模式时必须存在最终解析出的入口文件，普通模式不加载它。
- `app/static/` 存放 JS、CSS、图片等静态资源。游戏页面可以引用这些资源，但资源服务不等于能力授权。
- `app/static/js/player/` 可存放主页面和控制器页面共用的玩家端表现或输入逻辑，但不能保存权威状态。
- `app/static/js/shared/` 可存放类型、常量、序列化结构和无副作用的纯函数；不能包含 WebSocket、DOM、房间状态写入或权威结算。
- `app/static/js/service/` 存放权威处理端逻辑，例如题目生成、动作验证和状态结算；这是推荐目录，不是平台强制目录，实际 JavaScript 文件由 `authority.entry` 声明。
- 权威处理端必须由 `app/index.html` 预先引入，但不能当作普通玩家逻辑执行。初始化脚本必须通过 SDK 判断当前客户端是否为 `authorityClientId`，只有 Authority Client 才注册 service；`app/controller/index.html` 不引入或初始化权威服务。

### 玩家运行层与权威处理层

两类代码必须保持边界：

| 层 | 入口/位置 | 允许职责 | 禁止职责 |
|---|---|---|---|
| 玩家运行层 | `app/index.html`、`app/controller/index.html`、`app/static/js/player/` | 展示画面、采集输入、调用 `submitAction`、订阅权威状态 | 计算最终分数、决定胜负、伪造其他玩家身份、直接访问 WS |
| 权威处理层 | `app/static/js/service/` 或声明的 service 入口，由 `app/index.html` 条件初始化 | 接收所有玩家动作、验证规则、生成题目、更新权威状态、返回目标列表 | 操作 DOM、读取页面控件、创建 WS、依赖某个玩家页面的临时变量 |
| 共享数据层 | `app/static/js/shared/` | 类型、常量、纯计算、协议载荷定义 | 保存会话状态、发送消息、执行玩家权限判断 |

App 主机运行 `app/index.html` 与权威处理层，但二者是两个代码层。大屏模式下 `app/index.html` 只是公共显示页面，不是玩家页面；普通多屏模式下它可同时承载主机玩家 UI。两种模式都只能按 `playmesh.session.isAuthority()` 决定是否启动权威监听，不得从玩家顺序推断。
- 当前游戏的 `app/` 固定映射为 `/app/...`；平台公共资源目录 `playmesh-library/public/` 固定映射为 `/playmesh/...`。资源服务必须拒绝路径穿越，且不能暴露 `data/`、其他游戏包、用户文件或 App 私有文件。Game SDK 使用 `/playmesh/sdk/v1/playmesh.js`，未来头像等公共资源也只能放入平台公共目录后统一暴露。

## 游戏包存储和安装

推荐采用“压缩包导入，安装时解压，运行时读取解压目录”的方案。游戏库不要求开发者或用户额外注册游戏，App 通过扫描统一的游戏库目录自动发现和加载游戏：

```text
导入 .zip/.lpgame
  -> 临时目录接收
  -> 校验压缩包、路径和大小
  -> 解压到临时安装目录
  -> 校验 main.json 和必需入口
  -> 计算内容哈希并生成版本记录
  -> 原子移动为已安装只读目录
  -> 预览和 WebView 从已安装目录读取
```

存储建议：

```text
playmesh-library/
  packages/
    {gameId}/
      main.json          游戏定义文件
      app/               唯一公开目录，包含页面、控制器和静态资源
        index.html
        controller/      大屏游戏控制器入口
        static/          JS、CSS、图片等游戏公开资源
      data/              游戏自定义持久化数据，不含平台定义的用户层级
      cache/             App 可清理缓存；开发历史位于 developer/local-history/
  public/
    sdk/v1/             构建生成的 Game/App SDK 与类型声明
    avatars/            未来可选的平台公共头像资源
```

不保存原始压缩包。压缩包只作为导入过程中的临时文件，校验和解压完成后即可删除；需要分享时，直接从 `playmesh-library/packages/{gameId}/` 重新生成临时压缩包，分享完成后删除临时文件。`main.json`、入口和静态资源都直接位于该游戏目录中。

`data/` 和 `cache/` 位于 `packages/{gameId}/` 下，但不属于游戏包文件，不能被打包分享，也不能由游戏通过路径直接访问。游戏只能通过 SDK 存取自己的持久化数据；`cache/` 由平台管理。

`app/`、`data/` 和 `cache/` 必须保持同级，禁止将运行数据或缓存放入 `app/`。运行时只将当前 `packages/{gameId}/app/` 映射到 `/app/...`，并将平台 `playmesh-library/public/` 映射到 `/playmesh/...`；`data/` 和 `cache/` 不参与静态资源映射，不能通过相对路径或任意 HTTP URL 读取。

### 游戏数据存储 API

SDK 采用 Bucket 分区模型。每个 Bucket 对应 `data/` 下的一个 JSON 文件，游戏通过 Bucket 区分存档、设置、统计等数据：

```ts
const profile = playmesh.storage.getBucket("profile");

const coins = await profile.getData<number>("coins");
profile.setData("coins", (coins ?? 0) + 1);

profile.removeData("temporaryFlag");
await profile.clearData();
```

正式接口名称使用 `getBucket(bucket).getData(key)`，不使用容易产生歧义的文件路径接口。`getBucket` 返回当前游戏范围内的内存缓存对象；`getData` 首次访问时加载 `packages/{gameId}/data/{bucket}.json`，`setData`、`removeData` 和 `clearData` 默认只修改内存，不立即写磁盘。

宿主存储服务必须提供延迟批量持久化：数据发生变化后等待几秒或达到脏数据阈值再写入对应 Bucket 文件；同一时间窗口内的多次修改合并为一次写入。游戏只能调用 `getData`、`setData`、`removeData` 和 `clearData`，不能显式 flush。WebView 重启、退出或会话关闭时，App 必须等待最终落盘完成后再释放存储与连接。

持久化主机固定为开始游戏的 Authority 设备，所有客户端看到同一份主机 Bucket：

- Authority 主屏 WebView 通过 Flutter Bridge 直接访问主机 `GameStorageService`。
- 普通浏览器通过分享网关的受 token 保护存储接口访问主机；浏览器不得使用 `localStorage` 保存玩家身份或游戏 Bucket。
- 其他 App 玩家通过现有会话把保留的存储请求路由到 Authority 主机，再把结果返回调用方；加入设备不得在自己的 `packages/{gameId}/data/` 创建分叉副本。
- 分享网关和会话路由最终调用同一个主机内存缓存与延迟落盘服务，避免不同入口产生不同数据。

存储范围只自动绑定当前 `gameId` 和当前游戏库。平台不创建、推断或强制 `{userId}` 子目录；如游戏需要多用户存档，应由开发者在 Bucket 名称、key 或 JSON 内容中自行设计。Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`，即首字符为字母或数字，其余只能使用字母、数字、下划线和连字符，最长 64 个字符；SDK 与宿主存储层必须分别校验。SDK 还必须限制 key 格式、单值大小、单文件大小、总容量和 JSON 类型；写入采用临时文件加原子替换，异常时不能破坏已有数据。游戏数据与 `main.json`、游戏包文件、其他游戏数据和 App 用户资料隔离。

游戏详情页必须提供“清除游戏数据”操作，并明确提示该操作会删除当前游戏的自定义存档。用户确认后只清理 `packages/{gameId}/data/`，不影响游戏本体与开发历史。清除缓存是独立操作，会删除 `cache/` 及其中的开发历史。卸载游戏时直接删除整个 `packages/{gameId}/` 目录，同时删除游戏文件、数据和缓存。

### 游戏库自动扫描

Flutter 没有一个在 Android、iOS、Windows 等平台路径完全相同的公共外部存储目录。平台层必须抽象一个 Playmesh 专用游戏库根目录，并通过统一 API 提供给 Flutter：

- Android：使用 App 专用外部文件目录或 App 数据目录，遵守 Scoped Storage。
- iOS：使用 App 沙盒内的 Application Support/Documents 目录；需要对外分享时交给系统分享面板。
- Windows、macOS、Linux 和其他非移动端：使用当前运行可执行文件同级的 `playmesh-library/`，不得写入 AppData 或其他用户应用支持目录；需要用户查看或导出时调用文件管理器或系统分享能力。

游戏库在以下时机扫描 `playmesh-library/packages/`：

- App 启动完成后。
- App 从后台恢复时。
- 用户执行“重新扫描”时。
- 导入、删除或分享操作完成后。

游戏库页面还提供显式后台刷新。扫描期间继续展示 App 级仓库中的旧缓存，扫描成功后按 `gameId` 去重、稳定排序并原子替换，同时更新缓存 revision 和刷新时间；失败时不清空列表。仓库查询以缓存为数据源，支持后续搜索与 offset/limit 分页，不让页面直接重复扫描文件系统。

扫描器只识别合法的 `{gameId}/main.json`，并要求清单中的 `id` 与目录名一致。发现新目录后自动校验并建立索引；目录缺失、校验失败或版本冲突时记录结构化错误，不阻塞其他游戏显示。游戏库索引属于 App 级仓库或平台索引区，游戏目录和 `main.json` 是实际来源，不能要求游戏包额外注册，也不能在安装目录创建 `.playmesh/` 元数据。

### 本机游戏源与在线游戏库

Playmesh App 可以在独立固定端口启动 `GameCatalogServer`，把当前统一游戏库作为局域网游戏源分享。Catalog Gateway 与动态 Go Core、游戏会话分享网关和 Developer Gateway 分离，默认端口 `16668`，开关、端口与可选 Token 持久化到 `playmesh-library/catalog/settings.json`。Token 非空时 `/apps/*` 必须使用 Bearer 鉴权，留空时不鉴权。

`GET /apps/list` 每次重新扫描统一游戏库，按名称、标签和描述过滤并分页返回完整 `GameManifest`；`GET /apps/download` 临时导出只含 `main.json`、可选 `capabilities.json` 与 `app/` 的标准包。服务不分享 `data/`、`cache/`、其他私有文件或内置资源游戏。

在线游戏库属于现有游戏库内部能力，不在首页增加第二个游戏库入口。它并发请求全部启用的 Host/Token 源，将各源返回按 `GameManifest.id` 去重后展示；单个源失败不阻断其他源。源配置支持手动输入、二维码导入、启用、禁用、编辑、删除和二维码分享。默认每源取 `5` 个，可配置为 `1` 至 `100`。

多选下载进入顺序队列，每个任务使用独立 HTTP Client，支持进度、停止和删除。远程包下载到临时文件后必须继续走 `GamePackageTransferService.importPackage` 的完整安全校验和原子安装；成功、失败、停止或 App 退出后删除临时文件。完整契约见 `docs/catalog-api.md`。

### 统一开发者工作区中新建和编辑游戏

游戏文件管理和编辑统一由开发者工作区提供。桌面浏览器通过局域网地址进入，App 端在开启开发者模式后使用内置 WebView 打开同一个地址和同一套界面，不再实现独立 App 文件编辑器。游戏库中的每个游戏都必须能在工作区中查看、编辑、保存和运行，包括用户导入包和工作区新建的游戏；平台不内置游戏 Demo。

新建游戏时，用户只需要在开发者工作区填写必要信息：

- 游戏名称。
- 游戏图标或是否使用默认图标。
- 支持的 `displayModes`。
- 玩家人数范围。
- 游戏方向。
- `tags` 等清单属性，以及可选的 `capabilities.json` 能力声明。
- 是否启用多人权威处理端，以及权威入口路径。

确认后平台自动生成默认项目骨架，包括 `main.json`、`app/`、控制器入口、玩家运行层、权威处理层和共享数据层。生成的 SDK 接入、角色判断、消息分发和生命周期代码已经存在，用户或 AI 只修改标记的业务区域。

开发者工作区必须提供以下文件操作：

- 新建文件和文件夹。
- 删除文件和文件夹。
- 将本地文件直接上传到指定目录。
- 编辑并保存文件。
- 整文件替换。
- 在指定行插入内容。
- 替换指定行到指定行的内容。
- 查看修改前后的 Diff。
- 按文件、文件夹或整个工作区查看本地历史，并从指定时间操作恢复变更前或变更后状态。
- 未保存文本的撤销与重做由 CodeMirror 编辑器负责。

### 快速文本文件操作格式

开发者工作区必须支持用户直接粘贴 AI 生成的分段操作文本。默认以当前游戏的 `app/` 公开目录作为网页文件操作根目录，因此 `static/js/shared/types.js` 表示 `packages/{gameId}/app/static/js/shared/types.js`：

```text
----create_file:static/js/shared/types.js
export const ActionTypes = {};
----end

----replace_file:index.html
<!doctype html>
<html>...</html>
----end

----insert_lines:static/js/service/index.js:20
// TODO：处理玩家动作
----end

----replace_lines:static/js/service/index.js:20-35
// TODO：替换指定范围
----end
```

支持的操作为 `create_file`、`replace_file`、`insert_lines` 和 `replace_lines`。`create_file` 要求目标不存在；`replace_file` 为完整内容 upsert，目标不存在时自动创建文件及父目录；行操作要求目标已经存在或在同一批操作中先创建。每个操作必须有 `----end` 结束标记；工作区解析后先显示逐文件 Diff，用户确认后作为一个原子事务执行；路径越界、行号失效、编码异常或任一文件写入失败时，整批操作取消。底层可以转换成结构化操作对象，用于校验、原子提交和本地历史差异记录，但用户和 AI 默认不需要编辑 JSON。

编辑操作只能作用于当前 `packages/{gameId}/` 目录，禁止访问其他游戏、App 私有目录和系统路径。保存前必须校验路径、编码和文件大小；多文件修改应作为一个原子操作，任一文件失败时整体取消。

### 开发者本地历史

项目级本地历史固定写入当前游戏包中的 `cache/developer/local-history/`，与 `app/`、`data/` 同级。历史不单独保存每次变更前的重复副本，而是由一份初始 `baseline/` 和按时间操作保存的变更后 `snapshot/` 组成；某次操作的变更前状态由上一操作的变更后快照推导，第一项操作则以初始基线为准。

连续变更按 5 分钟滚动窗口合并为一个时间操作，最多保留 100 个操作。淘汰最旧操作时，先将其变更后快照提升为新基线，确保后续 Diff 仍可还原。保存、上传、新建、删除、快速操作和历史恢复都进入同一条项目历史链；手动恢复会创建一个独立且封口的时间操作，不与后续编辑合并。

历史快照排除 `data/` 和 `cache/`，项目树与开发者文件 API 也不允许通过普通路径访问这些内部目录。工作区可按文件、文件夹或项目根查看结构化新增、修改和删除差异，并用指定操作的变更前或变更后状态全量替换当前范围。恢复项目根时必须保留平台管理的 `main.json`。恢复完成后通过统一 SSE 通道发送 `workspace.restored`，使其他工作区刷新状态。

CodeMirror 负责当前编辑缓冲区尚未保存内容的即时撤销与重做。服务端不提供单文件 `/undo` 接口，也不维护独立的文件撤销栈。

App 游戏库至少支持以下排序和分类：

- 分类：根据 `main.json.tags` 原样展示和筛选，也可以按单机、多人、显示模式等平台字段筛选。
- 最新修改：按游戏文件或编辑记录的最后修改时间排序。
- 最近游玩：按最近一次启动游戏的时间排序。

这些排序和分类由 App 游戏库索引提供，不要求游戏包自行注册。`data/` 存放游戏运行数据，`cache/` 存放编辑历史、预览缓存和索引，其中开发历史固定为 `cache/developer/local-history/`；二者都不能映射到 WebView。

平台不随安装包提供游戏 Demo。开发者工作区新建项目直接写入 `playmesh-library/packages/{gameId}/`，与后续导入的正式项目共用扫描、运行、数据、缓存和删除流程，不增加发布到游戏库的中间步骤。

安装过程必须隔离且原子完成：

- 禁止 `../`、绝对路径、链接文件和越界解压。
- 限制压缩包大小、文件数量、单文件大小和解压后总大小，防止压缩炸弹。
- 只允许包内文件，不允许安装脚本、可执行文件或任意原生动态库。
- `main.json`、`app/index.html` 和大屏模式需要的 `app/controller/index.html` 必须在安装阶段校验。
- 校验失败时删除临时目录，不影响当前已安装内容。
- 安装完成后目录只读，游戏运行过程不能修改自身包内容。
- 新版本安装成功后直接替换为当前版本；开发期不保留旧版本目录、回滚实现或迁移适配层。

## 游戏包分享

游戏包分享是用户安装库的通用能力，支持局域网链接、二维码和文件三类入口。二维码只编码链接，接收端根据客户端类型决定进入 App 原生路由或普通浏览器兼容页。

文件分享必须提供三种系统能力：显示临时导出包文件地址、请求文件管理器打开地址，以及在 Android/iOS 上调用系统原生分享意图。分享对象是从已安装目录临时生成的导出压缩包，不直接暴露内部解压运行目录；分享完成后删除临时压缩包。任何接收方式都必须重新经过压缩包、路径、`main.json`、哈希和权限校验。

### 链接和二维码的本局 token

App 第一次打开本局分享面板时生成随机 token，并将它绑定到当前游戏会话。关闭面板只隐藏二维码和链接，网关与 token 继续有效；浏览器控制器刷新后由 SDK 复用 `localStorage` 中的玩家 ID 和昵称重新加入。再次打开面板复用本局相同链接。

分享面板必须列出全部可用局域网地址。用户点选任一地址时，二维码立即改为编码该地址；当前选中项应有明确状态，不能始终固定使用列表第一项。

以下任一条件发生时，token 必须立即失效：

- 用户离开当前游戏或当前联机会话结束。
- App 关闭、重启或 Go Core 重启。

本局 token 不设置独立的面板可见期；它随当前游戏会话一起销毁。重新开始将原 Core 会话重置为大厅并重建 WebView 和游戏业务状态，但保留会话 ID、联机码、已连接玩家、分享网关和 token；只有退出游戏并创建新会话时才生成新 token。

## `main.json` 游戏定义

```json
{
  "icon": "app/static/image/icon.png",
  "id": "com.playmesh.quiz",
  "name": "多人抢答",
  "remarks": "局域网多人抢答游戏",
  "version": "0.1.0",
  "sdkVersion": "1.4.2",
  "appSdkVersion": "1.2.1",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "players": {
    "min": 1,
    "max": 4
  },
  "authority": {
    "entry": "app/static/js/service/index.js"
  },
  "tags": ["example", "multiplayer", "single_screen_multiplayer"],
  "displayModes": ["single_screen_multiplayer"]
}
```

需要设备能力时，在与 `main.json` 同级的可选 `capabilities.json` 中声明：

```json
{
  "required": ["sensor.accelerometer", "sensor.gyroscope"]
}
```

字段规则：

- `icon` 是包内路径。上传后由 App 保存到本地，游戏库读取本地副本。
- `id` 在创建或导入时自动生成，并作为游戏稳定身份；更新版本不能随意改变它。
- `players.min` 和 `players.max` 最低为 1，且 `min` 不得大于 `max`。`max: 1` 表示游戏不需要多人会话。
- `modes` 是单元素数组，必须且只能声明 `solo` 或 `multiplayer`；值为 `multiplayer` 时必须提供 `authority.entry`。
- `orientation` 是必填字段，只允许 `landscape`（横屏）或 `portrait`（竖屏）。App 必须在创建游戏 WebView 前应用该方向，并在退出游戏后恢复系统方向。
- `sdkVersion` 和 `appSdkVersion` 用于检查游戏与两套平台 SDK 的兼容性，当前模板分别使用 `1.4.2`、`1.2.1`。版本使用 `MAJOR.MINOR.PATCH`；CLI 发布前从本地生成 SDK 自动覆盖这两个字段。
- `capabilities.json` 只负责声明游戏必需的平台能力，不混入 `main.json`。能力 ID 按功能命名，不绑定 App 或浏览器实现；平台按运行环境选择适配器。
- 平台能力元数据统一维护在 `lib/models/game_capability_registry.dart`。每个 code 在这里映射中文名、用途说明、App 适配状态和 HTML 适配状态；SDK 弹窗、开发者可视化编辑器、运行时校验和对外能力接口都从该注册表生成。新增能力时只在这里增加一项元数据，具体运行环境仍需单独实现对应适配器。
- 当前支持声明 `sensor.accelerometer` 和 `sensor.gyroscope`。文件缺失或 `required` 为空时不弹确认框；非空时主 SDK 在 App 和浏览器每次加载游戏时展示全部所需能力，并等待用户“同意并进入”或“拒绝并退出”。当前平台不支持的能力显示“本平台暂不支持”，但不会阻止同意后进入。授权结果不持久化，也不写入权威主机。
- 游戏只能通过 `playmesh.app.onDevice(type, fps, callback)` 订阅已声明且当前设备可用的能力。原生层维护最新采样，SDK 按每个订阅者请求的频率触发回调；最后一个订阅取消或页面退出时释放原生流。
- `displayModes` 是单元素数组，必须且只能声明 `multi_screen` 或 `single_screen_multiplayer`。声明 `single_screen_multiplayer` 时，游戏包必须提供 `app/controller/index.html`。
- `authority.entry` 声明权威处理端入口路径。支持多人联机的游戏必须提供该入口；单机游戏可以省略。入口必须位于游戏包内，安装时校验路径不能越界，且不能是可执行文件或外部网络地址。
- `authority.entry` 指向的代码只由创建会话的 App 主机 Authority Runtime 加载，不会被普通玩家页面加载，也不会由 Go Core 解析。
- `tags` 是可选的开发者自定义标签数组。平台必须按包内输入原样保存和展示，不翻译、不改名、不强制映射为另一种显示文本；标签只用于分类、筛选、展示和测试识别，不改变游戏权限、联机规则或运行入口。
- 展示层渲染任意自定义标签时必须使用安全文本 API，防止标签内容被当作 HTML/脚本执行，但用户看到的文字必须保持原样。

`main.json` 是机器可读定义，文件名固定为 `main.json`；旧文档中提到的 `manifest.json` 在本项目中统一以 `main.json` 为准。

## SDK 与组件版本策略

后续所有更改都必须评估受影响组件并按需升级版本号，完整规则和当前版本矩阵见 `docs/06-engineering-standards.md`。Game SDK 与 App Bridge SDK 分别以 `sdk-src/playmesh.ts`、`sdk-src/playmesh-app.ts` 为唯一手写源，构建生成运行 JS、`.d.ts`、版本常量和关联契约。App、默认项目骨架、Schema、Manifest、OpenAPI、AI 提示词和校验器始终只维护一套当前契约。`sdkVersion/appSdkVersion` 不用于选择历史兼容层。

规则：

- 契约调整后直接更新当前 SDK 版本及全部关联资源。
- 不保留旧 SDK 入口、字段别名、消息适配器、迁移器或双写逻辑。
- 与当前版本不一致的开发数据可以清理，并使用当前模板重新生成。
- 启动前必须检查受支持的 SDK 主版本、权限和协议能力；不允许静默降级或伪造能力。

## 权限边界：静态资源不等于能力授权

需要明确区分三件事：

1. **资源访问**：外部浏览器能否通过 HTTP 读取 `app/index.html`、JS、CSS、图片。
2. **网页标准能力**：浏览器自身允许网页使用的 DOM、键盘事件、触摸事件和浏览器权限。它不由 Playmesh 的能力声明控制。
3. **Playmesh 平台能力**：由 App/Go/Game SDK 提供的传感器、手柄、玩家身份、会话和输入路由。

如果 `app` 页面通过 Playmesh 分享入口暴露给外部浏览器，主 SDK 会读取当前游戏的 `capabilities.json` 并展示平台能力确认弹窗；这只管理 Playmesh SDK 能力，不替代浏览器自身权限。浏览器仍然可以触发普通的 `keydown`/`keyup` DOM 事件，摄像头、陀螺仪、WebUSB 等标准浏览器 API 也继续受浏览器自己的安全策略、来源、设备支持和用户授权控制。

因此权限必须在平台接口和服务端同时执行：

- App SDK 调用传感器等设备能力前，检查当前游戏的 `capabilities.json`、当前页面角色和设备可用性。
- 未声明的能力，SDK 不注册对应 API，或返回明确的权限错误；不能只在 UI 中隐藏按钮。
- Go 会话服务校验连接使用的游戏 ID、玩家身份、页面角色和能力范围，不能相信浏览器传来的权限字段。
- 外部浏览器即使能读取静态页面，也只能获得公开的静态资源和被授权的会话接口，不能获得 App token、任意文件、其他游戏包或原生桥接。
- 对键盘这类浏览器原生事件，如果平台要求严格禁止使用，游戏代码还需要主动忽略事件，或由控制端页面使用 CSP/输入路由约束；能力声明无法从浏览器内核层阻止它。

推荐把“外部可访问的页面”视为不可信客户端：静态文件可以公开，但所有玩家加入、输入上报、传感器数据和游戏状态接口都必须经过短期会话凭证、角色校验和会话层校验。游戏语义的最终校验由 Authority Runtime 执行，Go Core 不得代替它判断游戏结果。

## 游玩期间的普通浏览器发布

普通浏览器访问是创建或游玩联机会话时的运行时设置，不写入 `main.json`，也不能由游戏包自动开启。建议流程：

```text
房主在游玩设置中开启“允许未安装 App 的玩家通过浏览器加入/控制”
  -> App 明确提示风险
  -> 用户确认发布
  -> App 生成短期链接/二维码和浏览器角色凭证
  -> 浏览器只访问被允许的游戏页面和会话接口
```

提示至少包含：

- 普通浏览器不具备 App 内全部硬件能力，键盘、摄像头、传感器和 USB 是否可用取决于浏览器、系统、来源和用户授权。
- 外部浏览器页面属于不可信客户端，不能把 App 的原生权限、用户资料或长期 token 暴露给它。
- 游戏包中的 HTML、JavaScript 和资源会在浏览器中执行；来源不明或未经审核的游戏包可能包含恶意代码、钓鱼页面或消耗设备资源的逻辑。
- 发布后，浏览器客户端可能读取该游戏公开给它的页面内容和会话数据；房主应确认游戏包来源和网络环境可信。

MVP 建议默认关闭普通浏览器发布，由用户在每次游玩时单独确认；只允许发布当前游戏和当前会话，提供停止发布/撤销链接的操作。会话摘要可以记录：

```json
{
  "browserPublished": true,
  "browserRole": "controller",
  "expiresAt": 1760003600000
}
```

浏览器玩家的加入必须经过 App 提供的中间层：

```text
浏览器打开房主分享的局域网地址
  -> 主机网关返回当前模式的 app/controller 页面和浏览器 SDK 配置
  -> SDK 读取 localStorage 中的持久化 playerId 与昵称偏好
  -> 缺少 playerId 时生成 p_ 前缀随机 ID；昵称不存在时显示输入层
  -> SDK 调用加入接口，服务端校验该 playerId 未被在线连接占用并签发短期凭证
  -> SDK 建立会话连接并解除游戏初始化等待
```

游戏脚本必须等待 `playmesh.ready`，在身份确认和加入完成前不能发送输入。分享 URL 与宿主注入配置不携带昵称或玩家 ID；浏览器 SDK 在当前来源的 `localStorage` 中保存 `playmesh.player-id.v1` 和昵称偏好，但不保存玩家凭证或游戏 Bucket。刷新后复用同一玩家 ID；旧 WebSocket 在线时同 ID 的后续加入与连接直接拒绝，旧连接掉线后才可重新签发凭证并触发 `onPlayerReconnect`。SDK 在浏览器中统一提供悬浮改名按钮；App WebView 不显示该入口，并使用 App 自动注入的 `u_...` 用户 ID 和昵称。

## 用户、游戏声明和联机会话

用户资料由 App 管理，不依赖云端账号：

```json
{
  "userId": "u_01JABC...",
  "nickname": "小明",
  "avatarPath": "local://avatars/u_01JABC....png"
}
```

`userId` 首次创建时由本地安全随机源生成并持久化；昵称不是身份主键，头像路径只在本机有效。

每个游戏必须有声明文件 `main.json`：

```json
{
  "id": "com.playmesh.quiz-demo",
  "name": "抢答 Demo",
  "version": "0.1.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": { "min": 1, "max": 4 }
}
```

`displayModes` 是游戏声明支持的画面拓扑分类，当前只允许两个值：

| 值 | 含义 |
|---|---|
| `single_screen_multiplayer` | 大屏模式：主机使用 `app/index.html` 显示主游戏画面；其他 App 设备和普通浏览器使用 `app/controller/index.html` 作为控制端。|
| `multi_screen` | 普通模式：主机、其他 App 设备和普通浏览器都使用 `app/index.html` 作为游戏端；各设备显示内容由游戏决定。|

`modes` 和 `displayModes` 是两个维度，但当前每个维度都只能选择一个值：`modes` 决定单机或联机，`displayModes` 决定唯一画面拓扑。纯单机游戏不会创建联机会话。

`orientation` 与上述两个维度独立，只描述游戏页面需要的设备屏幕方向：

| 值 | 含义 |
|---|---|
| `landscape` | 横屏游戏；允许系统选择左右横屏方向。 |
| `portrait` | 竖屏游戏；允许系统选择上下竖屏方向。 |

缺失、使用 `auto` 或其他未知值都应在游戏包校验阶段拒绝，不能等到 WebView 启动后再猜测。

App 和普通浏览器都根据会话选择的 `displayMode` 选择入口，并向页面注入 `displayMode`、`role` 和会话上下文。大屏模式的 `role` 通常为 `controller`，普通模式的 `role` 通常为 `game`。Playmesh 不规定控制器或游戏页面的具体内容。

App 从声明文件读取展示信息和 App 原生能力开关：单机模式不创建联机会话；联机模式才显示创建/加入入口。MVP 暂不把观看列为能力，也不向游戏暴露旁观者身份。

### 大屏模式运行拓扑

```text
房主设备
  Flutter App
    -> `app/index.html`（主机显示大屏/主画面）
    -> Game SDK
    -> Go Session
          ^
          | WebSocket / session events
          v
加入者设备
  Flutter App
    -> `app/controller/index.html`（App 或浏览器控制端）
    -> Game SDK
    -> 触屏 / 摇杆 / 传感器输入
```

大屏模式下，主机设备使用 `app/index.html` 显示主游戏画面；其他 App 设备和普通浏览器都使用 `app/controller/index.html`。通过 App 加入的设备也不是游戏端，而是控制端。

### 普通模式运行拓扑

普通模式下，主机 App、其他 App 设备和普通浏览器都加载 `app/index.html`。它们都属于游戏端，页面如何根据玩家身份、设备身份或屏幕位置显示内容，由游戏 SDK 与游戏代码决定。

游戏网页和控制器网页都可以按声明申请 `input`、`sensor`、`session` 等能力，但必须经过 Game SDK 的权限和事件接口，不能直接访问原生对象。

联机会话由创建者发起，使用一次可分享的联机码。二维码和复制链接应优先使用兼容入口，使 App 扫码和普通浏览器打开使用同一份凭证：

```json
{
  "joinCode": "ABCD12",
  "joinUrl": "http://192.168.1.10:8080/join/ABCD12",
  "joinLinks": {
    "universal": "http://192.168.1.10:8080/join/ABCD12",
    "app": "playmesh://join/ABCD12",
    "browser": "http://192.168.1.10:8080/join/ABCD12?client=browser"
  },
  "gameId": "com.playmesh.quiz-demo",
  "displayMode": "single_screen_multiplayer",
  "joinRole": "controller",
  "authorityClientId": "p_authority",
  "players": { "min": 2, "max": 4, "online": 0 },
  "status": "waiting"
}
```

加入流程：创建者选择游戏并以某个 `displayMode` 启动 -> App 启动游戏和联机会话 -> 用户第一次打开分享附加层 -> Core 生成绑定当前会话的随机 token -> App 在随机端口提供 `/join/{joinCode}` -> 附加层显示二维码和全部可用局域网 IPv4 链接 -> 加入者通过 App 或浏览器打开 -> 浏览器 SDK 读取或生成本地持久化玩家 ID 并确认昵称，App SDK 自动提供 App 玩家 ID 与昵称 -> SDK 进入当前模式的 `app/controller/index.html` 或 `app/index.html` 并建立唯一 WebSocket。关闭附加层或重新开始不撤销 token，刷新可用同一 ID 重连；退出游戏、会话结束或 Core 重启后旧链接失效。

已安装 App 的玩家使用 App WebView，可使用声明并获准的 App 原生能力；未安装 App 的玩家使用普通浏览器，按照当前运行模式进入游戏端或控制端，不能获得 App 原生桥接、App 用户资料或长期凭证。浏览器入口只能绑定当前游戏和当前会话，支持房主随时停止。

统一入口兼容策略：

- App 扫描兼容二维码后，优先由 App 原生扫码流程识别 `joinCode`，直接进入 App 加入流程。
- 浏览器扫描或打开兼容链接后，先进入临时兼容页；兼容页可以尝试唤起 App，失败或检测到未安装 App 时进入浏览器加入页。
- 兼容页不能把 App 是否安装作为安全依据，最终仍由短期凭证和服务端确认控制加入权限。
- 如果系统不支持 Universal Link/App Link、无法可靠唤起 App，或房主希望明确区分两类入口，则在开启浏览器加入时同时生成：App 专用二维码/链接和浏览器专用二维码/链接。
- 双入口仍使用同一个 `joinCode`，只是客户端路由不同；两类入口都必须经过会话和身份校验。

不同入口最终仍按当前运行模式选择页面：大屏模式进入 `app/controller/index.html`，普通模式进入 `app/index.html`。二维码不直接决定游戏页面，只决定客户端路由和加入上下文。

## 房间和输入协议草案

第一版消息保持小而稳定，便于 Flutter 假数据、Go WebSocket 和 TypeScript SDK 共用概念。

```json
{
  "type": "input.action",
  "sessionId": "ABCD12",
  "playerId": "player-1",
  "deviceId": "device-phone-1",
  "timestamp": 1760000000000,
  "payload": {
    "button": "a",
    "pressed": true
  }
}
```

推荐先约定这些事件类型：

| 类型 | 用途 |
|---|---|
| `session.created` | 创建联机会话 |
| `player.joined` | 玩家加入 |
| `device.bound` | 设备绑定到玩家 |
| `player.left` | 玩家离开 |
| `input.action` | 按键类动作 |
| `input.axis` | 摇杆、方向等连续状态 |
| `session.heartbeat` | 心跳 |
| `session.error` | 可恢复错误 |

## 输入原则

输入分两类：

- 状态型：摇杆、按键按住、陀螺仪、姿态骨骼点。只保留最新一帧。
- 动作型：按钮按下/释放、加入、暂停、确认。必须按顺序处理。

建议第一版频率：

- 触屏摇杆：30Hz
- 手柄摇杆：60Hz
- 陀螺仪：30Hz
- 姿态：15-30Hz
- 心跳：3 秒一次
