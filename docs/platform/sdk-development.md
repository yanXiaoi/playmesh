# SDK 开发约定

本约定适用于 Game SDK、App Bridge SDK、网页运行片段、Dart 宿主执行器和 SDK
精确版本发行定义。游戏作者 API 见 [Game SDK / App Bridge SDK](../game/sdk-v1.md)。

> **三端同步要求：** 对 Game SDK 或 App SDK 的任何修改，都必须同步更新 Runtime 底包和 GDevelop Playmesh 扩展，确保 SDK、Runtime、GDevelop 三端的公开能力、版本与行为一致；任一端未同步不得视为完成。

当前工作树以 Playmesh `5.1.0+37`、Game SDK `4.3.0` 与 App Bridge SDK `3.5.0`
实现 Authority SQLite 数据库能力与 WebRTC 通用信令入口。自动化契约已完成；Android、Windows 与公网 TURN 的跨设备
实机验收仍待完成。现有 LAN 发现保持原入口和行为；iOS 自动发现/发布仍明确为
`unsupported`，扫码、手工邀请和分享链接不受影响。

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

## 公开 SDK 向后兼容基线

从当前兼容基线开始，Game SDK 与 App Bridge SDK 的公开契约只允许兼容演进：Game SDK
永久兼容基线集合为 `4.1.0`，App Bridge SDK 为 `3.2.0`、`3.3.0`；当前兼容集合再追加
Game SDK `4.2.0`、`4.3.0` 与 App Bridge SDK `3.4.0`、`3.5.0`。一次升级前注册表已经接受的 SDK 请求版本，
升级后必须继续接受；兼容版本集合只可扩大，不得缩小。
本规则不追溯恢复在该基线建立前已经停止支持的历史版本或旧命名空间。

主 App 的发行注册表继续精确枚举已发布请求版本，以保证 Manifest、下载与开发工具的版本
事实可审计。独立 Runtime 的包清单和宿主握手采用不同门禁：在兼容基线与 Runtime 内置
Bundle 之间按严格语义版本闭区间接受，并统一运行内置最新 Bundle；高于内置 Bundle、低于
基线或格式错误的版本拒绝。这样不会因 Runtime 的历史枚举滞后拒绝旧兼容游戏，同时仍防止
旧 Runtime 猜测执行未来 SDK。

游戏调用端可能长期固定，因此已经公开的命名空间、方法名、参数接受范围、返回结构、事件、
错误 code 与调用语义不得删除、重命名、收窄或改作其他用途。后续 SDK 不允许破坏性更新，
也不能用提升 `MAJOR` 版本规避兼容责任。版本演进只允许：

- `PATCH`：不改变公开调用契约的兼容修复、性能修复或实现调整；
- `MINOR`：增量增加新的命名空间或函数，并保证旧调用不需要修改且行为不变。

兼容不要求永久保存每个历史 Bundle 的独立文件。旧请求版本可以解析到更新的兼容 Bundle，
但前提是该 Bundle 继续提供旧版本的完整公开契约，并通过所有受支持请求版本的契约回归测试。
内部实现、Bridge 和执行器可以重构；这些重构不得改变用户调用端可观察到的既有行为。

## 注册表职责

`SdkFeatureRegistry` 是唯一注册与分发位置，负责：

- 按 target 和 order 组装 Game/App SDK；
- 生成 TypeScript、JavaScript 和 `.d.ts`；
- 建立命令到版本化执行器的索引；
- 注册 Game/App SDK 当前 Bundle 及只能追加的明确兼容请求版本集合；
- 根据游戏声明解析兼容 SDK Bundle；
- 根据消息携带的实际 Bundle 版本选择对应执行器；
- 拒绝兼容基线外版本、未知版本、格式错误版本和同版本重复执行器；
- 为网关、Developer API、AI 提示词和 SDK 下载提供同一内容。

Bridge 只负责消息解析、上下文构造、统一分发和响应，不重新维护命令 `switch`。

## Game SDK 与 App SDK 的实现边界

`playmesh-main.js` 是公共游戏运行时，`playmesh-app.js` 是当前终端运行时。新增字段或功能前必须先判断所有权：

| 数据或行为 | 唯一所有者 | 规则 |
| --- | --- | --- |
| 游戏声明、`gameId`、会话、玩家、Authority 角色、同步、生命周期、Authority 主机 Bucket | `playmesh-main.js` | 只公开 `playmesh.main.*`；Main Bucket 只能由 Authority 页面调用，宿主 HTTP 网关必须在后台拒绝远程玩家，即使其浏览器会话或分享令牌有效 |
| 平台、App 身份、locale、FPS/延迟、能力注册表、设备可用性、权限、全屏、终端输入、当前设备 Bucket | `playmesh-app.js` | 只公开 `playmesh.app.*`；由当前 Windows/Android/浏览器终端注入，允许每个玩家结果不同；App Bucket 不通过 Authority 或 Session 共享 |
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

当前 Game SDK 为 `4.3.0`，App Bridge SDK 为 `3.5.0`。下表是当前公开面；
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
| `playmesh.app.webrtc` | `getSignalingEndpoint(identifier)` |
| `playmesh.app.device` | `getPlatform()`、`setFullscreen()`、`onInput()` |
| `playmesh.app.ui` | `configure()`、`initializeBrowser()`、`showGameSidebar()`、`onSystemMenuRequest()`、`onBack()`（已废弃）、`restartGame()`、`openSharePanel()`、`openRuntimeLogs()`、`enterFullscreen()`、`exitFullscreen()`、`openGameInfo()`、`setPerformanceVisible()`、`togglePerformance()`、`exitGame()` |
| `playmesh.app.runtime` | `getLocale()` |
| `playmesh.app.storage` | `getBucket()` |
| `PlaymeshAppStorageBucket` | `getData()`、`setData()`、`getDataSync()`、`setDataSync()`、`removeData()`、`clearData()` |
| `playmesh.main.session` | `getCurrent()`、`onStateChange()`、`onPlayerJoin()`、`onPlayerLeave()`、`onPlayerReconnect()`、`isAuthority()`、`start()`、`finish()` |
| `playmesh.main.player` | `getCurrent()`、`setNickname()` |
| `playmesh.main.game` | `submitAction()`、`onMessage()`、`onEvent()` |
| `playmesh.main.authority` | `onService()` |
| `playmesh.main.rpc` | `request()`、`onRequest()`、`requestStream()`、`onStreamRequest()` |
| `playmesh.main.binary` | `authorityPlayerId`、`createChannel()`、`joinChannel()` |
| `BinaryChannel` | `id`、`mode`、`send()`、`sendLatest()`、`onMessage()`、`onForward()`、`close()` |
| `playmesh.main.sync` | `startAuthority()`、`submitAction()`、`submitState()`、`requestSnapshot()`、`getSnapshot()`、`observe()` |
| `SyncAuthorityController` | `getState()`、`setState()`、`publish()`、`stop()` |
| `playmesh.main.lifecycle` | `onChange()`、`onPause()`、`onResume()`、`onExit()` |
| `playmesh.app.performance` | `reportFrame()`、`getFps()`、`onFps()`、`getLatency()`、`getLatencyDiagnostics()`、`onLatency()`、`setVisible()` |
| `playmesh.main.storage` | `getBucket()` |
| `StorageBucket` | `getData()`、`setData()`、`removeData()`、`clearData()`、`upload()` |
| `playmesh.main.db` | `open()`、`select()`、`update()`、`delete()`、`insert()`、`getDDL()`、`beginTransaction()`、`transaction()` |
| `PlaymeshDatabaseTransaction` | `select()`、`update()`、`delete()`、`insert()`、`getDDL()`、`commit()`、`rollback()` |

`playmesh.main.storage` 与 `playmesh.app.storage` 的调用形态相似，但数据所有权不同：
Main Bucket 是 Authority 主机持有、且只允许 Authority 页面读写的游戏数据；需要让
玩家使用其中结果时，Authority 必须通过正常游戏消息投影所需内容，不能让玩家直接读取
Bucket。App Bucket 只属于调用页面所在的当前设备，其他玩家和其他设备不能通过会话
读取。两者异步 Bucket 名称都匹配
`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`，普通 key 都匹配
`^[A-Za-z0-9._-]{1,128}$`。App WebView 把每个 Bucket 保存为当前设备
`playmesh-library/data/{游戏名称}/{gameId}/{bucket名称}.json`；游戏名称作为文件段时由
宿主安全转义，游戏代码不能指定或枚举路径。普通浏览器则直接以 Bucket 名称为
`localStorage` key。App Bucket 另提供与 Main Bucket 同名的 `getDataSync()` / `setDataSync()`：
同步方法允许 1～4096 UTF-8 字节逻辑 Bucket 名，原生 App 通过 App bootstrap 下发并立即从
公开结果移除的随机 loopback capability endpoint 阻塞读写当前设备文件，普通浏览器同步读写
当前源 `localStorage`。逻辑名只进入 SHA-256 文件映射和带原名校验的 envelope，不直接作为
路径。App Bucket 不提供 `upload()` 或默认跨设备恢复；同步能力也不借道 Authority、Core、
Relay 或其他设备。本次为 App Bridge SDK `3.3.0` 的兼容补充，不改变 SDK 版本。

`playmesh.app.webrtc.getSignalingEndpoint(identifier)` 是 App Bridge SDK `3.4.0` 的
通用信令入口。它返回当前会话绑定、单次使用、30 秒过期的 WebSocket URL，以及宿主提供的
ICE server 配置；`identifier` 用于标识一条由游戏定义的逻辑通道。同一用户可以为不同用途
申请多个标识符，多个加入用户也必须获得彼此隔离的票据和路由。平台只鉴权和转发受限 JSON
信令，不解释游戏 payload，不替游戏创建媒体轨、PeerConnection 或 DataChannel。

宿主启动 Go Core 时必须复用已有
`resolveBindableLanIpv4InterfaceAddresses(includeLinkLocal: false)`，把结果作为局域网
STUN/TURN 监听地址传入，禁止在 Go Core 或 App SDK 内再实现一套网卡遍历。端点返回顺序为
可用的 Authority 局域网 ICE、当前会话的 Go Server 公网 ICE；各玩家/标识符使用独立短期
凭据。若地址绑定失败，端点仍可返回公网 ICE 或空数组，不能让 SDK 调用失败，也不能把
防火墙/AP 隔离误判成媒体解码问题。

网页自行使用浏览器原生 WebRTC 交换 offer/answer 与 ICE candidate，并负责权限请求、媒体
采集、前后摄像头切换、码率控制、ICE restart 和显式关闭。当前信令拓扑固定为 Authority
星形：远端只能向 Authority 路由，不能借此枚举或直连其他加入用户。该入口与
`playmesh.app.media.open()` 相互独立；通用 WebRTC 不要求或签发 `AppMediaSource`，现有
媒体 API 也不能作为绕过信令票据、会话鉴权或路由约束的通道。

`playmesh.main.rpc` 复用已经过会话凭证认证的 Binary WebSocket，并使用 SDK 内部
RPC 帧直达固定 Authority，不经过 Session WS JSON action，也不创建公开 Binary
Channel。所有客户端的 `request(path, data, options?)` 都只返回 Promise；只有
Authority 可以调用 `onRequest(path, handler)`。handler 可直接返回值或返回 Promise。
公开 `any` 仅代表可传输值：JSON 兼容值以及 `Blob`、`File`、`ArrayBuffer`、
`Uint8Array`；函数、DOM 对象、循环引用和其他类实例必须在编码前拒绝。Core 只校验
会话、Authority 身份、path、帧大小、并发和超时，业务 payload 始终作为不透明字节转发。

Game SDK `4.3.0` 的 `requestStream/onStreamRequest` 把大字节源拆成控制面与数据面：Binary
WebSocket 只通知固定 Authority 并返回小型编码结果；File、Blob、ArrayBuffer、Uint8Array
或 `ReadableStream<Uint8Array>` 通过 SDK 私有、同会话鉴权的 HTTP body 流向 Core，再由
一次性 Authority GET 以 `io.Pipe`、32 KiB 有界缓冲和背压转发。结束条件是 HTTP EOF，不能
增加业务结束字节。流不进入 Binary 帧、JSON/Base64、临时文件或完整内存缓冲；“无完整文件
缓存”不能写成“零内存占用”。只有固定 Authority 可以注册和消费，游戏不能构造私有端点。

发送和接收 options 都可注册 `(transferredBytes, totalBytes)` 进度回调。发送进度表示 Fetch
已从 source 拉取字节，接收进度表示 handler 已拉取字节；都不等同于网络确认或磁盘落盘。
未知 ReadableStream 的总量为 `null`，回调异常只记录、不得改变传输结果。单流上限 512 MiB，
SDK 每页面与 Core 每玩家最多并发 4 个，Core 每局最多 16 个；默认总超时 5 分钟，可配置
1 秒至 30 分钟。handler 结果仍走普通 RPC 编码并保持 `4 MiB - 64 KiB` 上限。Authority 可把
收到的 ReadableStream 直接传给 `StorageBucket.upload(source, {name, type})`，全链路保持背压。

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
game.rpc
game.sync
game.storage-lifecycle
app.capability
app.performance
app.ui
app.device
app.webrtc
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
检查当前前台 WebView、Authority、原生用户激活票据和 UI 可用性。票据只能由宿主观察
到 pointer/key 事件后签发，2 秒内至多消费一次，导航或文档重置时清除；Bridge payload
中的 `userActivation: true` 只是网页侧提示，不能自行通过宿主校验。错误使用稳定机器 code，
该 UI 命令本身不返回分享 Token、URL 或二维码内容。需要房主程序化读取分享数据时，
只能使用下述 `playmesh.app.lan.getShareLinks()`，不得从 UI 命令、DOM 或日志建立旁路。
打开前由 SDK 同步保存游戏
DOM 焦点，关闭后宿主只发送注册表内部的 `platform.ui.restoreGameFocus` 消息；
它不进入 TypeScript、Schema、补全或公开返回值。已打开请求只重聚焦现有关闭按钮，
关闭后 800 ms 内的 SDK 重开以 `rate_limited` 节流。

SDK 兜底菜单发起分享命令时只禁用“分享/邀请”按钮并在其图标位显示加载环，不能锁定整个
菜单。主 App 与 Runtime 宿主收到命令后都先提交分享层首帧，再建立分享通道；分享层继续
复用局域网内容区域的进度状态，避免二维码生成或网关启动推迟弹窗反馈。

App Bridge SDK `3.3.0` 的 `playmesh.app.lan` 是同一 Dart feature 中的网页声明、命令和
宿主执行器，公开：

```text
discoverGames()                  当前 gameId 的无 token 发现投影
PlaymeshLanGame.join()           用户操作下加入发现项
joinByLink(invitationUrl)        用户操作下预检并加入链接
scanQrAndJoin()                  用户操作下扫码、预检并加入
setPublished()                   无参数、单向、当前房间幂等公开
getShareLinks()                  无副作用读取统一分享快照
```

SDK feature 只能调用注入的 `AppLanHost` 薄接口，不得引用网卡 resolver、
`GameWebGateway`、Relay session、token 解析器或二维码编码器。`discoverGames()` 只返回
当前游戏的 `instanceId/gameId/name/host`，不含邀请 token；所有加入入口由宿主复用
`GameJoinCoordinator` 与邀请预检，并通过 `afterResponse` 在 Bridge 回包后导航。App
附近列表内部新增的主机昵称、人数、单机标记不扩展公开 SDK，也不增加图标字段或端点。

`joinByLink()` 与 `scanQrAndJoin()` 在主 App 和 Runtime 后端都进入同一个
`GameJoinCoordinator.prepareLink()`，不执行只属于发布/读取分享信息的 Authority 鉴权。
邀请准备仍必须校验受控 `entry`、`gameId/gameName`、当前 `expectedGameId`、自邀请和取消；
Relay 成功准备产生的 client session 与受控 `entry` 校验结果只能单次移交给
`afterResponse` 导航，不能在准备末尾关闭后由游戏页重建。Dart 预检与 WebView 的 Cookie
仓库彼此隔离，因此 WebView 必须在已移交的同一 tunnel 中从原邀请入口再次 POST token，
取得自己的 HttpOnly Cookie 后再进入受控 `entry`；不得直接导航到预检结果。Bridge 回包前
失效、导航失败、页面替换和 Runtime 关闭均要回收尚未移交或已接管的会话，连接对象不得进入
公开 SDK 返回值或游戏 JavaScript。

发现 wire 对 SDK 完全不透明。唯一宿主实现使用 `239.255.80.77:53584` 的 IPv4 UDP
multicast wire v1（1 秒公告、4 秒 TTL、单包最多 1200 字节），不提供旧服务发现、第二
发现栈或已知节点单播适配器；`host` 来自数据报 source IP，而不是 JavaScript 或 payload。
Android、Windows、macOS、Linux 支持该宿主能力，iOS/Web 返回明确不可用。

统一加入弹窗调用 `discoverGames()` 时只将局域网房间列表标记为 busy，并在该区域显示简短
的“扫描中”动效；扫码和邀请链接输入不得随发现请求锁定。发现完成、失败或弹窗关闭都必须
清除列表扫描状态，减少动态效果偏好下不得持续旋转。

`getShareLinks()` 是新的明确安全授权：只允许 Playmesh App WebView 中宿主确认的当前
本机 Authority/standalone host，返回冻结的 `{url,type,img}` 数组；`url` 是完整 LAN
或当前有效 Relay bearer 邀请，`img` 是同一 URL 的 PNG Data URL。它不创建分享通道、
不公开 UDP multicast、不连接 Relay，也不要求 capability、确认弹窗或 user activation。普通
浏览器、远程加入页、非房主或失效 context 必须拒绝。平台不得记录、持久化、分析或在
错误中回显 URL、token、PNG；但已经被授权的房主游戏代码能够自行复制和外传它们，
旧的绝对禁读结论不再适用。

App UI feature 另提供同步无返回值的
`playmesh.app.ui.disableSystemMenuTriggers()`。方法严格无参数，仅在 `app.ready` 完成后
单向、幂等禁用当前文档的 Escape/Menu/Back 自动菜单触发；不影响显式
`showGameSidebar()`、信息/日志覆盖层或已打开层的关闭。平台 UI 配置刷新不能重新绑定，
WebView 文档刷新恢复默认绑定；旧 boolean setter 和多余参数必须拒绝。它不会取消
`onSystemMenuRequest()` 回调；回调返回 `NEXT` 时仍需遵守该触发器状态。

App Bridge SDK `3.5.0` 新增 `playmesh.app.ui.onSystemMenuRequest()`，统一接收 Android
系统返回、桌面 exe 的返回键和普通浏览器
悬浮菜单按钮。原始入口事件先到达 SDK，随后在产生菜单显示、覆盖层关闭或退出等默认效果前
执行所有回调。回调严格返回 `EXIT`、`NEXT` 或 `STOP`：`EXIT` 直接退出，
`NEXT` 继续该入口原有默认流程，`STOP` 不再执行任何后续流程。宿主原生返回继续只调用
`appInternalRuntime.handleNativeBack()`，不得感知游戏自定义确认 UI。`NEXT` 必须在回调完成后
重新执行具体入口的默认动作：返回键重新检查统一 `fallbackUi`、系统菜单触发器和当前覆盖层，
浏览器悬浮按钮继续显示菜单；`fallbackUi: false` 时返回键不能无条件创建或显示菜单。
多回调优先级为 `STOP > EXIT > NEXT`；异常、超时或非法返回值按 `NEXT` 继续默认流程。
原 `onBack()` 继续作为行为完全相同的兼容别名，但在 `.d.ts`、Manifest、文档和 GDevelop
中标记废弃；不得删除、改变返回类型或建立第二套监听器。

统一菜单只保留一个全屏状态按钮，并在分享/邀请后提供 App-only 加入入口。该入口必须复用
分享/邀请的 Authority 主机可见性结果，不得单独按 `lanHost` 存在与否放开；加入端 WebView
和普通浏览器都不显示。加入层只渲染当前 `gameId` 的 `discoverGames()` 结果、扫码按钮和邀请
链接输入，不放解释文案；三个入口全部调用现有 `playmesh.app.lan`，不得新增发现或加入旁路。

Game SDK 的 `receive()` 必须把浏览器顶层 `transport.closed/error` 和 WebView/移动端内部
`transport.status` 统一投影为 `playmesh.main.lifecycle.onChange()` 的 `closed/error`。
底层可用内部 `lifecycleState` 区分正常关闭与异常，但该字段不得进入公开 SDK。平台
PeerConnection 关闭必须先关闭关联 DataChannel 和本机 socket，以保证该事件可达；不得在
SDK、Dart 页面或 Go Core 控制面借此自动换路、导航、ICE restart 或新建平台连接。现有
Session/Binary WebSocket 可以继续尝试原本的本机端点，但该重试不得选择新路线，也不能
复活已经关闭的 Pion PeerConnection。

App SDK 的菜单、信息和日志覆盖层必须在自身 Shadow DOM 中显式使用默认系统光标，
不能继承游戏用于第一人称或第三人称控制的隐藏光标样式。该行为只作用于 SDK 自有覆盖层，
不得读取或修改游戏 DOM/CSS；覆盖层关闭后直接隐藏，不保存或恢复游戏光标状态，也不在
Runtime host、Game SDK 或 GDevelop 扩展中增加平行处理。

SDK 自有覆盖层和悬浮菜单按钮产生的鼠标、Pointer、触摸、点击、右键菜单及滚轮事件，
必须在 closed Shadow DOM 的冒泡边界调用 `stopPropagation()`，不得调用统一的
`preventDefault()`，以免破坏按钮、滚动和触摸的默认交互。该隔离负责阻止普通冒泡监听把
菜单输入传给游戏，但不退出或恢复 Pointer Lock，也不能替代游戏对捕获阶段输入监听的暂停；
需要这些输入模式的游戏仍应通过 `onGameMenuOpen()` / `onGameMenuClose()` 管理自身输入状态。

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
6. 如果增量增加公开函数，更新 Feature 内声明模板并按 `MINOR` 升级版本；不得删除、
   重命名或收窄既有签名，也不得改变既有消息、返回、事件、错误 code 或调用语义。
   同步向 `supportedRequestedVersions` 末尾追加新版本，使升级前已接受的每个清单版本
   继续解析到兼容 Bundle；不能用首尾区间隐式接受未发布版本。
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

release.supportedRequestedVersions 为空、重复、未严格递增或首项不是永久基线
  => 失败：兼容请求版本集合无效

release.bundleVersion 不是 supportedRequestedVersions 最后一项
  => 失败：版本化兼容元数据不一致

公开 command 没有以 SdkVersionRange.last 结尾的执行器
  => 失败：后续 Bundle 可能静默丢失既有命令
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

#### Windows 宿主的导航回包队列

Windows WebView2 允许页面在 `<head>` 解析阶段就通过 App/Game Bridge 发送 bootstrap，但在
`LoadingState.navigationCompleted` 前执行宿主回包脚本并不可靠。这个问题属于共享 Windows
宿主的 document 生命周期，不属于 App/Game SDK 业务。

`WindowsLocalGameWebView` 必须把 App Bridge 与 Game Bridge 的宿主到网页回包统一交给同一个
`WebViewMessageQueue`：导航开始时暂停并清除上一 document 的待发消息；当前导航完成后才按
FIFO 恢复。
因此早发 `app.bootstrap` 可以立即由宿主处理，但其回包只在当前 document 可执行时送达一次，
随后 `main.ready` 也只完成一次。队列不得重写 `requestId`、改变 result/error、延长 SDK 超时、
自动重试请求或把上一 document 的消息送进新页面。

该宿主修复同时保护 GDevelop 与非 GDevelop 的 head 早加载页面，不修改 SDK 源、公开 API、
Bundle 版本或命令执行器。Android/普通浏览器继续使用各自既有的 document-ready/transport
边界，不能为了 Windows 时序再增加 SDK 内部 bootstrap 分支。

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

版本选择不是“找最接近版本”，也不是接受最小值与最大值之间的任意数字，而是按
`supportedRequestedVersions` 中已经发布的明确版本精确命中。SDK 升级时必须向该集合
追加新版本，不能让原已命中的请求版本失效：

```text
requestedVersion == null
  => 仅供宿主内部读取当前 SDK 文件时使用当前 release.bundleVersion；
     main.json 不允许省略版本

requestedVersion 不匹配 MAJOR.MINOR.PATCH
  => 失败

requestedVersion 出现在 release.supportedRequestedVersions
  => 命中该 release，并返回其 bundleVersion 对应文件

requestedVersion 位于 min/max 之间但未在集合中列出
  => 失败；例如当前 App 3.2.1 不会被视为 3.2.0、3.3.0、3.4.0 或 3.5.0

其他值
  => UnsupportedError；兼容基线外或从未支持的版本不做猜测性回退
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


## 版本与兼容发行

游戏通过 `main.json.sdkVersion/appSdkVersion` 请求 SDK。稳定资源分别为
`/playmesh/sdk/v1/playmesh-main.js` 与 `/playmesh/sdk/v1/playmesh-app.js`；
`/playmesh/sdk/v1/` 中的 `v1` 不是语义版本，旧 `playmesh.js` 不回退。

解析链：

```text
requestedVersion
  -> SdkRelease.supportedRequestedVersions 精确版本
  -> bundleVersion + 对应 SDK 文件
  -> SDK 消息携带实际 bundleVersion
  -> 版本化命令索引
  -> 对应 Dart 执行器
```

规则：

- 当前 Game SDK 接受明确版本 `4.1.0`、`4.2.0`、`4.3.0`，均解析到 `4.3.0` bundle；App Bridge
  SDK 接受明确版本 `3.2.0`、`3.3.0`、`3.4.0`、`3.5.0`，均解析到 `3.5.0` bundle；`3.2.1`
  等未发布版本不在集合中。
- 上述版本构成当前兼容基线；后续升级必须继续接受这些版本以及升级前已经新增支持的版本。
- 兼容基线外、未知或格式错误的版本直接失败；不要求恢复基线建立前已停止支持的历史版本。
- 每个 target 维护一份只追加的明确请求版本集合；`minimumRequestedVersion` 与
  `maximumRequestedVersion` 只是集合摘要，不决定是否接受版本。`bundleVersion` 是实际返回和
  随消息发送的 SDK 版本，当前 App `3.2.0` 请求因此使用 `3.5.0` bundle。
- 上一条描述主 App 的 `SdkFeatureRegistry`。独立 Runtime 使用兼容基线到内置 Bundle 的
  闭区间门禁，不要求请求版本出现在主 App 的历史发行枚举中；Runtime 的上限仍由实际随包
  SDK Bundle 决定。
- 执行器的 `supportedVersions` 只约束当前实际 Bundle 的命令分发，不能扩大 Manifest
  可接受版本。
- SDK 公开契约禁止破坏性更新；不能删除或重命名既有函数，不能收窄参数或返回值，不能
  改变既有消息、事件、错误 code 和调用语义，也不能通过升级 `MAJOR` 版本绕过该限制。
- 增量增加新函数属于功能增加而非破坏性更新，使用 `MINOR` 版本；旧调用端无需修改，
  升级前已接受的请求版本仍须解析并正常运行。
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

安装包导出可在 Runtime 私有配置中启用自动能力确认。Runtime host 仅在
`app.bootstrap` 回包中注入 `_playmeshAutoApproveCapabilities`，App SDK 把它转存到私有
`Symbol` runtime 后立即从 bootstrap 对象删除；Game SDK 在正常能力声明完成后调用既有
`app.capabilities.confirm`，不复制宿主能力状态，也不增加公开 API、`.d.ts` 字段或网页可见
配置。未配置时必须保持现有确认界面。

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
- 明确兼容请求版本集合是否保留升级前所有已接受版本；
- `.d.ts` 与中文 JSDoc；
- SDK Manifest、Schema 和开发文档；
- 默认项目模板；
- AI 提示词和编辑器补全；
- App、Developer API 或 Core 协议是否真正受影响。

不要因为 App 版本变化而机械升级 SDK，也不要在公开签名未变化时制造无意义新执行器。
任何公开变化都必须先证明旧调用契约保持不变；无法兼容的设计不得进入公开 SDK。

## 验证清单

- Source Fragment ID 和顺序唯一。
- 网页发送命令与执行器集合一致。
- 同版本同命令只能命中一个执行器。
- 未注册版本和非法版本被拒绝。
- Game `4.1.0`/`4.2.0`/`4.3.0` 与 App `3.2.0`/`3.3.0`/`3.4.0`/`3.5.0` 能选择当前执行器；App
  `3.1.0` 和未发布的 `3.2.1` 被拒绝。
- `webrtc.getSignalingEndpoint()` 只在有效会话中签发一次性短 TTL 票据；identifier、
  信令消息大小/速率、Authority 星形路由和多加入用户隔离均有契约测试。
- 每次 SDK 升级前已接受的全部请求版本在升级后仍能解析并执行原有调用；明确版本集合没有缩小。
- 新增函数的契约测试不得替代旧函数回归测试；所有基线命名空间、签名、返回、事件、
  错误 code 与既有调用语义继续通过。
- Windows head 早加载时，App/Game bootstrap 回包在 navigation completed 后按序且恰好一次
  送达；传统 body 末尾加载行为不变，新导航和 dispose 不泄漏旧 document 消息。
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
