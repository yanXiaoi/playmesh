# 工程开发规范

## 目标

Playmesh 的开发必须满足四个目标：

- 可复用：同一职责和运行时边界内的通用能力只有一份生产实现；页面、Go 服务、Game SDK
  和游戏包共享版本化契约，不建立平行业务规则。
- 可回溯：一次用户操作可以追踪到页面、协议、服务端、游戏和日志。
- 可验证：每个重要行为都有对应的单元测试、集成测试或手工验收步骤。
- 可演进：协议、游戏包和 SDK 具备明确版本，所有改动同步更新实现、契约、模板、测试和文档。

## 开发期变更原则

当前处于软件开发期，不是已发布产品的迭代期。除已形成公开兼容基线的 Game SDK 与 App Bridge SDK 外，新版本修改不兼容旧版本内容，不保留旧接口、旧路由、字段别名、迁移适配器、废弃入口、历史模板或不可达代码。公开 SDK 的调用端可能长期固定，必须按 `docs/platform/sdk-development.md` 保留升级前已经接受的请求版本和既有调用契约，后续不得再发生破坏性更新。技术决策变化时直接替换现实现，并同步删除失效的代码、资源、测试和当前文档；不得以“可能兼容旧版本”为理由保留双实现。SDK 可以用同一兼容 Bundle 和公共执行器承接多个请求版本，不要求复制历史实现。历史阶段文档只记录事实，不参与运行时，也不能成为保留历史代码的依据。

## 模块边界

```text
Flutter App
  UI -> Application Service -> Repository/Client -> Go API
  UI -> Game Launcher -> WebView/Game SDK

Go Core
  HTTP Handler -> Application Service -> Session Domain -> Repository/Transport

Game SDK
  Public API -> Permission Guard -> Protocol Client -> Game Page

Game Package
  entries.game（清单显式声明；默认模板写入 index.html）-> Player Runtime + 条件初始化 Authority Service -> Game SDK
  entries.controller（单屏多人显式声明；默认模板写入 controller/index.html）-> Player Runtime -> Game SDK
  Shared Data -> types/constants/pure functions only
```

各层职责：

- UI 只负责展示状态和传递用户意图，不直接拼接 HTTP、WebSocket 或本地文件路径。
- Application Service 编排一个完整用例，例如创建会话、加入会话、启动游戏。
- Repository/Client 负责外部通讯和持久化，不包含页面业务判断。
- Android Developer Gateway 在开发者模式开启期间必须由用户可感知的 Foreground Service 持有同一个 FlutterEngine；锁屏和后台时只继续执行不依赖 Activity/View 的操作，关闭开发者模式时必须释放前台服务、CPU WakeLock 和 Wi-Fi Lock。
- Developer API 是否依赖可见 View 必须声明在统一 `DeveloperOperationDefinition.requiresForegroundView` 元数据中，并同步进入 OpenAPI 和操作目录；禁止只在某个 Handler 内临时判断。后台、锁屏、熄屏或窗口失焦时统一返回 `409 app_view_unavailable` 和机器可读状态详情，不得等待超时或伪造成功。
- Domain 负责用户、游戏声明、会话、玩家和输入事件的规则。
- Go Handler 只负责解析请求、鉴权、调用服务和生成响应，不直接修改会话内部状态。
- Game SDK 是游戏访问 Playmesh 原生适配能力的唯一入口，游戏页面不直接调用 Flutter、
  Go、原生桥接或任意端口。浏览器标准 API 可以直接使用；仅在 WebView 权限回调覆盖
  的敏感权限和 Playmesh 多平台适配能力需要写入 `capabilities.json`。
- App WebView 敏感权限必须由统一能力注册表处理：统一层把资源解析为现有能力 code，
  按当前页面角色声明检查 code 与插件可用性，再按 code 调用能力注册时绑定的唯一权限
  执行器。执行器不得另设 ID，也不参与路由和声明判断，只实现自身平台授权。本地页、
  加入页、Windows WebView 与 Android Activity 不得按 camera、microphone、MIDI 或
  能力 code 建立第二套映射或 switch；普通浏览器不进入 App 原生权限执行链。
- 当前终端产生的音视频统一通过 `playmesh.app.media` 按需消费。公共媒体运行时只做
  适配器注册、选择、不透明源签发、会话映射和生命周期管理；`sourceOptions` 表达协议
  无关源需求，独立 `adapterOptions` 完全由具体适配器解析。公共请求、能力插件和
  Bridge 不得包含 WebRTC/SDP/ICE 条件分支；新增协议只注册新的 Dart 与网页适配器。
  同终端 WebView 媒体不得为接入方便暴露 HTTP 地址、端口或内置信令服务器。
- 游戏分享运行时采用严格的最小公开面：外层物理 `app/` 下的普通资源直接位于运行时 `/`，另只允许 `/bucket/**`、`/playmesh/**`，以及 SDK 在浏览器沙箱内确实无法替代的受控底层连接能力（例如当前游戏受控的 WebSocket Upgrade）。`app` 是普通用户路径首段，物理 `app/app/**` 映射为 `/app/**`，且不会把 `/app/**` 别名到外层 `app/**`；只有 `playmesh`、`bucket` 是平台保留首段。该清单是完整公开边界而非接口示例。新增平台功能时必须遵循“SDK 优先”原则，优先修改 Game SDK 或 App Bridge SDK；平台 HTTP/WS 入口只能增加在 `/playmesh/**`，必须固定绑定当前游戏和会话、在建连前鉴权、禁止任意目标地址，并同步补齐协议文档与回归测试。
- SDK 分为公共游戏运行时 `playmesh-main.js` 与当前终端运行时
  `playmesh-app.js`。前者只公开 `playmesh.main.*`，在所有平台提供一致的游戏声明、
  会话、玩家、Authority、同步、生命周期和主机存储；后者只公开
  `playmesh.app.*`，负责当前 Windows/Android/浏览器终端的平台环境、App 身份、
  locale、性能、设备能力、权限、全屏、输入、本机 Console 日志和平台覆盖层。两者必须成对
  注入。面向游戏开发者的唯一全局对象是 `window.playmesh`，其根级公开成员严格只有
  `ready`、`main` 与 `app`；`window.playmeshApp` 不存在，`main`/`app` 不暴露
  `__*` 内部桥接。SDK 内部协作必须使用不可枚举的私有 `Symbol` runtime，且不得进入
  `.d.ts`、Manifest、提示词、补全或游戏可调用 API。`main.ready` 内部先等待
  `app.ready`；根 `playmesh.ready` 只复用这条初始化链并返回 `{main, app}`。不兼容旧根级游戏 API 或旧
  `playmesh.js` 文件。稳定运行时 URL 固定为
  `/playmesh/sdk/v1/playmesh-main.js` 与 `/playmesh/sdk/v1/playmesh-app.js`。App SDK
  可以读取 Game SDK 公共数据用于展示，但禁止通过 App
  bootstrap、原生桥、URL 或全局变量复制游戏状态；Game SDK 也禁止伪造终端能力和
  本机日志。普通浏览器的原生能力 `isAvailable()` 为 false。日志只保留在当前设备，
  禁止经 Session 或游戏网关跨设备转发。
- 游戏可以自带引擎或工具库，但必须放在自己的游戏包内并通过包校验流程管理；不得因为使用第三方引擎而绕过 SDK 的身份、存储和联机边界。
- SDK 不额外设计启动回调，页面脚本执行就是启动；必须提供 `onPause`、`onResume` 和由 App 主动触发的 `onExit` 生命周期接口。
- `onExit` 只作为退出前的最佳努力通知，必须幂等、有超时，不能作为唯一的数据持久化时机；重要数据应在状态变化后及时保存。
- 游戏库采用“目录扫描优先”原则：游戏包导入后由 App 自动扫描、校验和建立索引，不增加开发者注册步骤；索引失效时可以从目录重新构建。
- 游戏自定义数据必须通过 `playmesh.main.storage.getBucket(bucket)` 持久化。JSON 值存放在 `packages/{gameId}/data/json/{bucket}.json`；`upload(file)` 写入 `packages/{gameId}/data/data/{bucket}/{timestamp-ms}.{ext}`。不能写入游戏包目录或直接操作文件系统。
- 平台只按 `gameId + bucket` 选择上述目录，不得自动增加 `{userId}` 层。游戏需要区分用户时，由开发者在 Bucket、key 或 JSON 内容中自行设计。
- 异步方法和 `upload(file)` 的 Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`；SDK 在调用前校验，Flutter 存储层在落盘前再次校验。同步方法仅为锁定运行时适配器额外接受 1 至 4096 UTF-8 字节的原始逻辑名，并映射到带原名校验的安全物理 envelope；不能借此放宽同一 Bucket 的异步方法。私有 key `$playmesh.gdevelop.root.v1` 只允许同步 GDevelop 适配路径。
- `getData`、`setData`、`removeData` 和 `clearData` 默认操作宿主内存缓存，App 按固定时间窗口或脏数据阈值批量持久化，不能每次 API 调用都写磁盘。完整 Bucket JSON root 上限为 10 MiB。游戏不提供 flush 接口；WebView 重启、退出或会话关闭前由 App 等待最终落盘。`upload(file)` 使用原始请求体流式写盘，不允许 Base64 或 JSON 包装，单文件上限为 256 MiB。
- 异步 JSON API 与 `getDataSync/setDataSync` 必须统一走同一个绑定当前游戏/会话的同源 HTTP Bucket 网关：GET 读取、PUT 写入、DELETE 删除或清空，并共同使用 SHA-256、requestId 幂等和 revision/CAS。同步方法只允许锁定运行时 seam 使用主线程同步 XHR；不预热、不设 timer、不提供手动 flush，失败立即抛错。旧 Session WebSocket 存储请求/响应、pending/settle 接收器、双读、双写和 fallback 必须从 SDK、App host、GameRuntimeBridge 与 Go Core 主链彻底删除，并以全仓来源门禁防止回归。
- 持久化数据的唯一落盘端是开始游戏的 Authority 主机；所有 JSON HTTP 请求最终调用该项目共享的主机内存协调器和延迟落盘服务。该网关是 SDK 内部传输而非游戏可构造的公开业务 API，不能恢复 `/api/storage` 或允许任意 gameId。浏览器 `localStorage` 不得保存游戏 Bucket，加入设备不得创建自己的数据副本。`upload(file)` 继续独立使用 HTTP POST 与 `data/data`，不能进入 JSON envelope 或 `data/json`。
- `packages/{gameId}/app/` 是 WebView 静态映射根。运行时只把 `data/data` 中的文件映射为不可枚举的 `/bucket/{bucket}/{timestamp-file}`；`data/json` 始终私有，任何资源服务、路径拼接和预览接口都必须拒绝访问或穿越到该目录。
- 当前游戏的物理 `app/` 直接映射为 `/`；SDK、平台头像等公共资源统一放在 `playmesh-library/public/` 并通过 `/playmesh/...` 暴露。物理 `app/` 不得包含大小写变体的一级 `playmesh/` 或 `bucket/`；游戏不得以编码、反斜杠、空段、`.`、`..` 或符号链接越出 `app/`，也不得读取其他游戏包。
- 游戏详情页清除缓存/数据和删除游戏必须调用统一的数据清理流程；数据清理必须有用户确认、日志和明确的不可恢复提示。
- 原始压缩包只存在于导入和分享的临时生命周期内，安装库不长期保存压缩包；分享包由已安装目录临时生成。
- 工作区新建项目和用户导入项目统一进入 `packages/{gameId}/`，使用同一套扫描、校验、索引、运行和删除流程。
- `tags` 是开发者自定义显示数据，平台必须原样保存和展示，不得擅自翻译、重命名或限制标签集合；仅在渲染时使用安全文本方式，不能把标签当作 HTML/脚本执行。
- Player Runtime 和 Authority Runtime 必须分层。玩家页面只负责展示和提交动作，权威运行时只负责验证和产生权威结果；二者不得通过页面全局变量共享可变状态。
- `shared` 代码只能是无副作用的纯数据层，不能借此绕过 Player/Authority 边界。
- `app/index.html` 必须预先引入 authority service，但只能在 `playmesh.main.session.isAuthority()` 为真时初始化监听；`app/controller/index.html` 不初始化 authority service。
- 权威处理端不得操作 DOM、创建 WebSocket、读取控制器输入元素或依赖某个页面是否打开。
- 联机项目必须从平台默认模板创建，模板负责 SDK 接入、身份注入、动作路由和目标分发；AI 或开发者只修改明确标记的规则区和 UI 区。
- 默认模板的 SDK 接入区不得被游戏代码复制或重写。若需要调整协议，必须同步修改 SDK、模板、契约和校验器，而不是让单个游戏自行改变路由。
- 默认模板必须在 `app/index.html` 中完成 `playmesh.main.session.isAuthority()` 判断，并在权威时注册 `playmesh.main.authority.onService()`；必须在 `app/controller/index.html` 中完成 `playmesh.main.game.onMessage()` 注册。角色判断、WS 接入和处理器注册不应留给 AI 临时编写。
- 模板中的待实现区域统一使用中文 `TODO` 注释，且必须明确标注所属层级和允许修改范围。
- 当前客户端性能接口只统计游戏主动调用 `playmesh.app.performance.reportFrame()` 上报的真实完成帧。Canvas/WebGL 游戏应在实际绘制完成处调用；禁止由平台启动独立 RAF 循环猜测游戏 FPS。FPS 和延迟必须由 App SDK 在网页内自动渲染，游戏代码不得创建性能组件；`playmesh.main.performance` 不存在。
- App 运行时由 App 工具区控制 App SDK 性能悬浮层的显示开关；普通浏览器运行时由 App SDK 创建可收纳/展开的悬浮组件，并提供昵称修改入口。性能浮层只能由 App SDK 创建和维护；Game SDK 不保留旧浏览器性能 panel，两种环境都不得重复创建第二套 FPS/延迟 UI。

## 调用链规范

每个跨模块功能都要能写出明确调用链。例如浏览器玩家加入：

```text
浏览器
  -> GET /playmesh/join#inviteToken=...
  -> POST 邀请交换 + HttpOnly Cookie
  -> GET /{declared-entry}?{manifest-query}
  -> Authority 分享网关返回当前游戏页面与权威 Game SDK 配置
  -> SDK 从 localStorage 读取或生成持久化 playerId，并读取昵称偏好
  -> SDK 直接调用受控 Core Join 能力
  -> Go JoinService
  -> 校验 playerId 没有在线连接；掉线身份可重连
  -> 签发短期浏览器凭证
  -> Game SDK 建立受控 Session WebSocket
  -> 游戏页面通过 onPlayerJoin/onPlayerLeave/onPlayerReconnect 收到连接事件
```

游戏资源链路至少必须分别写清正式已安装层与临时开发层，不能用“启动 WebView”省略
来源选择和边界：

```text
正式已安装层：
UI -> GamePage -> GameLauncher
  -> InstalledGameWebResourceSource
  -> GameAssetGateway -> InstalledGameWebResourceProvider
  -> WebView -> SDK / Bridge

临时开发层控制面：
CLI adapter.Adapter -> development.Source / Mapping
  -> CLI development.Proxy -> App DeveloperWebGateway
  -> DeveloperRunController -> GamePage
  -> DevelopmentGameWebResourceSource

临时开发层资源面：
WebView -> GameAssetGateway -> DevelopmentGameWebResourceProvider
  -> CLI development.Proxy -> Mapping -> 开发资源服务器
```

两层从 `GameWebResourceSource` 起复用后续运行链路。`/playmesh/**` 和 `/bucket/**`
始终由 App 本地处理；CLI Adapter 只存在于开发控制面的 CLI 一侧。主机/加入端、
浏览器/App、局域网/公共中转是正交的共享与传输维度，不得据此再增加资源源类型。

新增功能时必须补充：

1. 入口是谁调用的。
2. 中间经过哪些模块。
3. 数据模型如何变化。
4. 成功和失败如何返回。
5. 日志中如何定位这次调用。
6. 哪些测试覆盖这条链路。

跨层调用禁止绕过中间层，例如 UI 不直接操作 Go 会话对象，游戏页面不直接访问 Go HTTP 端口。

## 可复用代码规范

### 单一生产实现与薄适配器（强制）

下列条款是所有新功能、修改、修复和重构的阻断性准则，不是建议项：

1. 开始设计前必须先审计现有生产调用链、状态所有者、协议模型和公共组件；已有能力能够
   满足语义时必须直接复用，不得因入口、页面、SDK、CLI、平台或展示形式不同而另写一套。
2. 同一职责和运行时边界内的业务能力只能有一个生产实现和一个权威状态写入者。不同入口
   只能是薄适配器，负责参数校验、权限门禁、投影、序列化或展示，不得重新读取、重新解析、
   重新拼装、重新计算或维护可独立写入的同义状态。
3. 复用受 UI 私有状态或具体入口耦合阻挡时，必须先在不改变行为的前提下，把逻辑提取为
   共享应用服务、协调器、领域值对象、协议模型、Repository/Client 或通用组件，再让原
   入口和新入口共同调用；不得复制后再承诺长期同步。
4. 抽象必须保持现有架构边界。优先使用组合、明确接口和不可变值对象；只有存在真实的
   “可替换同类”关系时才使用继承或基类。禁止为了形式上的复用创建万能工具类、空壳父类、
   跨层 facade 或新的旁路。
5. 仅展示不同的数据必须来自同一生产快照或同一底层结果，由各展示层做最终渲染；不得让
   每个消费者再次访问网卡、文件、数据库、网络、凭据或运行时状态来重建相同结果。
6. 业务生命周期、并发、幂等、缓存、错误映射和安全门禁必须由共享权威写入者统一处理。
   薄适配器不得建立第二套锁、队列、缓存、重试、降级、业务权限判断或清理流程。
7. 确实不能复用时，设计文档必须逐项写明现有实现、语义差异、不能复用的证据、新边界和
   回归风险，并在编码前通过评审；“改起来更快”“当前入口私有”或“以后再合并”不是理由。
8. 测试必须证明旧入口与新入口经过同一生产实现，并覆盖共享结果、错误、竞态和生命周期。
   必要时增加来源门禁，阻止再次出现平行实现；仅比较两份复制代码的最终输出不算复用证明。

代码评审发现重复业务实现、同义状态所有者、绕过既有生产链路或可提取却直接复制的代码
时，必须先完成合并或共享抽象，相关功能不得以“后续重构”方式通过。

“单一生产实现”不表示取消跨进程、跨语言或跨信任边界的防御。每个边界仍必须分别执行
协议解码、Schema/类型/长度校验、认证授权和必要的防御性检查；这些检查必须引用同一
版本化契约，最终权威判定仍由职责所属服务完成，不属于平行业务实现。“一个状态所有者”
是指一个权威写入者；允许不可变、可丢弃且带 generation/revision 的只读投影或缓存，但
投影不得反向恢复、独立修改或取代权威状态。

### 游戏分享、附近发现与 App LAN SDK（强制）

- 当前房间的分享授权、网关、LAN URL、Relay session、UDP multicast 公开意图、generation、
  链接/二维码快照与清理流程只能由 `GameShareCoordinator` 写入。页面、App SDK、开发
  预览和 Relay 适配器不得持有可独立修改的同义状态。
- 平台 multicast publication lease 与发现缓存只能由 App 级
  `LanGameDiscoveryService` 持有。建立分享通道不等于公开：默认和开发预览不得自动
  发布；只有打开分享面板或无参数 `setPublished()` 才能单向公开，关闭面板不撤销，
  game/session/page/process 生命周期结束必须停止公告、best-effort 发送 goodbye 并回收
  全部资源。
- 唯一生产发现链必须是 `lan_game_multicast_protocol.dart` 定义的自定义 IPv4 UDP
  multicast：`239.255.80.77:53584`、wire v1、1 秒公告、4 秒本地 TTL、单包不超过
  1200 字节。不得恢复 DNS-SD/TXT、第二发现栈、双栈发现或已知节点单播探测。实例地址只
  能取数据报真实 source IP，payload 自报地址无效；坏包必须独立丢弃且不得记录凭据。
- 所有有效非 loopback IPv4 物理网卡和支持组播的虚拟网卡都必须独立 join/send，不得依赖
  默认路由；接口动态增删要周期重整，单接口失败不得拖垮其他接口，全部失败才报告发现
  不可用。产品不得承诺穿透 AP 隔离、VLAN、防火墙、禁用组播或 VPN/虚拟网卡策略。
- `GameWebGateway.shareLinks()` 是 LAN 邀请的唯一生产路径，只返回网关实际监听的非
  loopback、非 unspecified 唯一 IPv4；游戏分享可显式包含 `169.254/16` link-local，但
  该放宽不得进入 Developer Gateway 或其他地址暴露链。没有可用地址时返回空列表，禁止
  `127.0.0.1` fallback。Relay 内部只能使用显式 `loopbackInvitationUri`，不能从公开 LAN
  列表选取、解析或重新拼接内部入口。
- 面板、开发状态与 SDK 只能读取同一不可变 `GameShareLinkSnapshot`。LAN 在前、当前
  有效 WAN 在后，按完整 URL 去重；二维码只由共享编码器按精确 URL 生成一次并缓存，
  面板渲染同一 PNG bytes，SDK 只做 Data URL 序列化。单 URL、项目数、单 PNG 与总
  Bridge JSON 必须执行文档化上限，超限整体失败，不得截断或返回缺图项目。
- 手工输入、扫码、附近发现项与 SDK 加入必须复用 `GameJoinCoordinator`、
  `GameInvitationInspector` 和既有 `RemoteGamePage`。SDK feature 不得自行请求邀请入口、
  判断 gameId、自建 Tunnel/WebView 或先导航后校验；Bridge 回包完成后才执行页面切换。
- App 附近列表可以读取发现服务的内部展示投影，显示游戏名、主机昵称、数据报真实来源
  IP、多人当前/最大人数或“单机”，并支持自动更新和手动刷新。点击加入后必须保留发现
  lease 与短期候选，直到统一预检及候选复查结束。App SDK `discoverGames()` 继续只导出
  `instanceId/gameId/name/host`，不得新增内部展示字段或图标端点。
- `playmesh.app.lan.getShareLinks()` 是 App-only 本机 Authority/standalone host 的明确
  授权，返回完整 bearer LAN/Relay URL 与逐链接 PNG Data URL；不新增 capability、确认
  弹窗或 user activation。普通浏览器、远程加入页、非房主和失效上下文必须拒绝。旧的
  “所有游戏脚本绝不能读取分享 URL/二维码”不再是有效基线；但平台与 SDK 不得自动把
  URL、token 或 PNG 写入日志、分析、磁盘、崩溃详情、异常消息或跨会话缓存。
- `playmesh.app.ui.disableSystemMenuTriggers()` 必须严格无参数、仅在 App UI ready 后
  单向且幂等地禁用当前文档的 Escape/Menu/Back 自动菜单触发；不得影响显式菜单/信息/日志
  覆盖层 API，配置刷新不得重新绑定，文档刷新恢复默认。旧 boolean setter 不得恢复。
- `playmesh.app.ui.onBack()` 只允许在游戏显式配置 `fallbackUi: false` 后生效；`false`
  阻止退出，`true`、无监听器、异常或超时继续退出。资格判断只读取统一兜底 UI 配置，
  不得按 WebView/移动端/浏览器或 SDK 内部弹窗类型建立分支。
- 统一菜单的“加入游戏”入口必须与分享/邀请共用 Authority 主机可见性，且额外要求存在
  App 原生 Bridge；加入端 WebView 和普通浏览器都不得显示或触发该入口。
- Go Core 主 Session WebSocket 不设置每连接每秒消息条数上限；帧大小、认证、权限和
  出站队列等既有边界仍保留。SDK `startAuthority.tickRate` 与 `submitState.rateHz` 的公开
  上限统一为 60 Hz。
- Windows WebView2、移动端和浏览器的主连接断开统一通过
  `playmesh.main.lifecycle.onChange()` 输出 `closed/error`；`transport.status` 仅供 SDK 内部
  重连，不得成为游戏侧平台分支接口。
- 分享与发现涉及平台能力时，自动化测试和 Manifest/entitlement 检查不能替代跨设备
  实机验收。Android、Windows、macOS、Linux 的发布、发现、丢失、权限、多网卡切换和
  实际加入必须分别记录；未执行项必须明确标为未完成。iOS 自动发现/发布必须稳定返回
  `unsupported`，同时回归扫码、手工邀请和分享链接仍可用。

- 代码注释必须使用中文；变量名、类名、接口名和协议字段可以继续使用项目约定的英文命名。
- 注释应说明设计原因、边界条件或不直观的行为，不写逐行翻译代码的无效注释。
- 新增复杂调用链、权限判断和限流策略时，必须在关键位置添加简短中文注释。
- 相同业务规则只实现一次，优先放在 Domain 或共享协议模型中。
- Flutter 页面之间共享的数据使用明确模型，例如 `UserProfile`、`GameManifest`、`SessionSnapshot`、`PlayerSnapshot`。
- 不在多个页面复制 join code 校验、人数校验、权限判断和错误文案映射。
- 通用按钮、状态展示、二维码展示、玩家列表和输入控件使用共享 Widget。
- Go 和 TypeScript 不手写各自不同的协议字段；协议字段必须来自 `protocol_schema` 或版本化文档。
- Game SDK 提供稳定的高层 API，游戏不需要知道 WebSocket 帧格式、设备驱动和原生桥接细节。
- Go Core 必须监听系统分配端口并由宿主上报实际地址；页面、游戏和 Client 不得写死或猜测端口。
- 只有出现真实复用场景或明确的边界职责时才抽象，不为了减少文件数量创建无意义的工具层。

## 文档撰写规则

- 仓库根 `README.md` 是默认英文项目入口；完整中文版本固定为 `README.zh-CN.md`。
  两份 README 必须在顶部互相链接，并在同一个变更中同步产品定位、能力、命令、版本、
  链接和已知边界；英文版不能只是中文摘要。代码标识、API 路径、Schema 字段、命令、
  文件名、日志和错误 code 保持原文，只翻译说明文字。
- `docs/` 下的架构、开发、版本、状态和验证文档保持现有中文，不要求创建英文镜像。
  根英文 README 可以链接这些中文权威资料，但必须让读者从链接标题或上下文知道目标是
  详细资料；不要为了形式上的双语复制历史文档或建立无法同步的机器翻译副本。
- AI 提示词正文属于开发文档，遵守相同的语义同步要求。模板固定放在
  `assets/playmesh-library/public/developer/prompts/{locale}/`，每个模板由同一
  `prompts/manifest.json` 的 `files` 映射声明。可用 locale、默认 locale 和 fallback
  只读取 `assets/playmesh-localization/manifest.json`；提示词目录不得再维护语言清单、
  fallback 或 App 级翻译副本。
- 项目提示词动态标题、说明和操作目录文案统一使用全局 `app.json` 的
  `developer.prompt.runtime.*` 命名空间。Developer Workspace 只传递当前 locale；
  Dart/JavaScript 公共逻辑按全局清单解析 locale、fallback、模板和文案，不得出现
  `if (locale == ...)`、中英字符串表或按语言复制生成流程。新增语言只增加统一语言声明、
  对应 `app.json` 文案、提示词语言目录及清单文件映射，不修改提示词业务代码。
- 自动检查必须覆盖：所有已启用 locale 具有完全相同的提示词条目，提示词模板非空，
  全局 `developer.prompt.runtime.*` 键集合一致，清单路径不能逃逸语言目录，生成接口按
  BCP 47 locale 选择精确语言或统一 fallback，且一个语言的自定义模板不能覆盖另一语言。

The root `README.md` is the default English project document and must remain semantically aligned
with `README.zh-CN.md`. Documents under `docs/` remain Chinese and do not require translated mirrors.
AI prompt localization is still manifest-driven: adding a locale changes global localization assets,
the locale prompt directory, and the prompt manifest only—never a language-specific code path.

## 数据和协议规范

- JSON 字段使用明确、稳定、可读的命名；同一概念只能有一个字段名，例如统一使用 `sessionId`，不混用 `roomId`。
- 每个跨进程消息必须包含 `type`、协议版本或可推断版本、时间戳和必要的关联 ID。
- 重要请求使用 `requestId`，跨用户操作使用 `sessionId`、`userId`、`playerId` 和 `deviceId` 关联。
- `main.json` 是游戏包定义的唯一入口；字段变更必须更新示例、校验器、文档和测试。
- 页面入口只从清单解析：所有游戏必须显式声明 `main.json.entries.game`，
  `single_screen_multiplayer` 必须显式声明 `entries.controller`，`multiplayer`
  必须显式声明 `authority.entry`。默认模板会分别写入 `index.html`、
  `controller/index.html` 与 `static/js/service/index.js`，但运行时不得为缺失字段
  硬编码回退。入口统一相对于外层物理 `app/`；首段 `app` 合法并解析到物理
  `app/app/`，只有 `playmesh`、`bucket` 是保留首段。扫描器、校验器、App WebView、
  分享网关、Catalog 和 CLI 必须使用同一清单值。
- 对外提供的 SDK、开发者通道和 Go API 必须提供机器可读接口文档；AI 应通过正式 API 契约调用能力，不为单个 AI 客户端编写专用 Agent。
- HTTP 接口使用 OpenAPI，数据、事件和错误使用 JSON Schema；每个接口记录权限、风险等级、幂等性、重试规则和示例。
- `main.json.orientation` 必填且只允许 `landscape` 或 `portrait`；单屏多人还必须声明 `controllerOrientation`，其他模式禁止该字段。WebView 必须按当前页面角色在方向应用完成后创建，进入全屏时把对应方向传到原生宿主，退出游戏后恢复系统方向。
- `main.json.author` 与 `lastModifiedAt` 是平台只读发布元数据。网页、Agent 和 CLI 上传时必须分别以当前 App 昵称和 Unix 毫秒时间戳覆盖，普通 manifest 编辑不得修改；旧包缺失时不得阻断扫描。缺失 `author` 在模型中保持空动态值，App 固定外壳用统一 `app.json` 显示本地化“未知发布者”；非空发布者始终逐字显示。缺失时间由 App 外壳显示本地化“无”，有值时按设备本地时区换算。
- `sdkVersion/appSdkVersion` 均为必填字段，用于声明游戏包要求的 SDK 版本；统一 Dart
  注册表当前精确接受 Game SDK `4.1.0`，并接受 App Bridge SDK `3.2.0`、`3.3.0`，
  Game 请求使用 `4.1.0` bundle，两个 App 请求版本均使用兼容的 `3.3.0` bundle。
  当前兼容基线外、未知值和格式错误值直接拒绝。
- SDK 使用 `MAJOR.MINOR.PATCH` 标识契约版本。版本升级必须同步更新发行定义、Manifest、
  Schema、模板、生成产物、测试和文档；已经完成的 Game SDK 4.0 命名空间切换不追溯兼容
  更早清单，但从当前兼容基线起只允许 `PATCH` 修复或 `MINOR` 增量增加函数，后续不得再
  破坏既有调用契约或移除已接受的请求版本。
- Dart 执行器通过 `supportedVersions` 自行声明适用 bundle；注册表必须拒绝相同命令
  和相同 bundle 版本同时命中两个执行器。发行解析的允许版本与执行器内部范围是不同
  约束，后者不得被用来放行旧清单。
- Game SDK 与 App Bridge SDK 之外的版本化组件发生参数、消息结构、返回值、事件、
  错误语义或入口不兼容变化时，必须升级相应版本并替换当前发行定义；不得通过旧命名空间
  shim、字段双写、静态 JS、文件读取或 Bridge 分支伪造兼容。公开 SDK 若无法保持当前
  兼容基线及既有调用行为，则该设计不得发布，必须改为增量 API 或内部实现调整。
- App 内所有界面文案只有一个国际化事实源：
  `assets/playmesh-localization/locales/{locale}/app.json`。这里的“App 内”同时包括
  Flutter 页面、内置 Developer Workspace，以及由平台注入游戏 WebView 的工具栏、
  能力确认、昵称、信息和日志 UI。工作区或 SDK 网页代码不得自带中文/英文字典，
  不得用 fallback 参数或硬编码字符串形成第二份可见文案。
- Flutter `BuildContext.tr` 不接受调用点 fallback；缺少 delegate/catalog 或静态 key
  必须立即抛出 `FlutterError`，Widget 测试挂载真实本地化宿主。catalog 建立前的启动
  失败只显示机器诊断码与原始错误，不另设启动文案。
- App 宿主必须先按统一清单解析 locale、fallback 和 `app.json`，再以只读
  `{locale, messages}` 投影桥接给内置 Web UI；只投影对应命名空间，不向游戏脚本
  暴露完整 App 词典。App 语言变化时必须向已经打开的工作区和平台注入 UI 推送更新，
  Web 端更新 `lang`、现有 DOM 和后续动态渲染。Web 端不得另存一份与 App 脱节的
  locale 偏好。
- API 路径、机器错误 code、Schema、游戏内容、用户内容和日志原文不翻译；渲染层
  使用 App 文案解释机器状态。独立部署的 Go Server 不是 App 内界面，可以使用统一
  locale 清单中的 `goServer` bundle，但不得被内置工作区复用。
- App Bridge SDK 只以同步只读 `playmesh.app.runtime.getLocale(): string` 向游戏公开
  当前显示端 locale，不公开 App messages。App WebView 必须返回当前加入方/显示方 App 的
  locale，不能读取 Authority 主机语言；普通浏览器直接返回
  `navigator.languages`、`navigator.language` 中第一个合法系统 locale，读取失败
  回退 `zh`，不得把返回值限制为平台覆盖层已有的语言。游戏业务文案由游戏包自行
  翻译，平台不得把 `app.json` 当作游戏语言包或自动修改游戏 DOM。

## 版本与升级策略

后续所有更改都必须先判断影响到哪些可发布组件，并按需升级这些组件的版本号；禁止功能、接口、协议或包结构已经变化，但仍沿用旧版本号。版本号遵循当前定义的 `MAJOR.MINOR.PATCH`：

- `PATCH`：不改变公开契约的兼容性修复、性能修复或实现修正。
- `MINOR`：保持当前主版本兼容的新增能力、公开 API 或可选字段。
- `MAJOR`：删除或重命名公开能力，改变既有字段、状态、数据格式或调用语义等不兼容变更。
- Game SDK 与 App Bridge SDK 是上述 `MAJOR` 规则的例外：永久兼容基线集合包含 Game SDK `4.1.0` 以及 App Bridge SDK `3.2.0`、`3.3.0`。后续禁止破坏性更新，也不得以提升 `MAJOR` 版本规避兼容责任；只能用 `PATCH` 做兼容修复或用 `MINOR` 增量增加新函数，并继续接受升级前全部已支持的明确请求版本。
- Flutter App 每次形成新的可分发构建时，除语义版本外还必须递增 `+build`；只修改说明文字且不形成新构建时不递增 App 版本。
- 纯文档勘误、阶段归档或未改变执行约束的提示词整理，不单独推动运行时版本；一旦提示词、Schema、Manifest 或 OpenAPI 反映了新的运行时契约，必须与对应组件在同一变更中升级。

版本按组件独立维护，不升级没有受到影响的组件。当前工作树实现版本矩阵为：

| 组件 | 当前实现版本 | 版本来源 |
| --- | --- | --- |
| Playmesh App | `4.3.0+30` | `pubspec.yaml` |
| Go Core | `0.5.0` | `go-core/main.go`、`go-core/mobile/core.go` |
| Core 协议 | `1.3.0` | Flutter/Go health、会话与玩家协议定义 |
| Game SDK | `4.1.0` | Dart game feature 注册表及生成的 TS、JS、类型、Manifest 与 Schema |
| App Bridge SDK | `3.3.0` | Dart app feature 注册表及生成的 TS、JS、类型与 App 注入配置 |
| Developer API / OpenAPI | `5.0.0` | Developer Gateway、安装包导出与临时开发资源会话契约 |
| Developer CLI | `2.0.0` | `dev-cli/`、adapter.Adapter、CLI User-Agent 与桌面平台构建规则 |
| Catalog API | `3.0.0` | `/apps/info`、根相对入口、包校验、版本化下载、图标与上传声明 |
| Relay 协议 | `3.0.0` | 根相对邀请入口、App 端点加密邀请与 Go Server 中转协议 |

该矩阵描述当前代码与生成契约；发布状态和历史版本见
`docs/version/README.md`、`docs/version/4.3.0.md` 与 `docs/version/NEXT.md`，3.0.0 的工程落点见
`docs/implementation/playmesh-3.0.0-local-implementation.md`。

游戏包的 `main.json.version` 同样使用语义版本，并由游戏开发者在发布内容变化时升级；`sdkVersion` 和 `appSdkVersion` 分别声明 Game SDK 与 App Bridge SDK。CLI 在 `dev/run` 前必须以项目 `playmesh/sdk/` 中实际 SDK 文件的内置版本覆盖这两个字段并与目标 App 精确核对，禁止手工声明不一致版本。CLI 2.0 只接受根 `playmesh-cli.json`；发布内容隔离在 `playmesh/package/`，SDK/类型隔离在 `playmesh/sdk/`，上传只包含必需 `main.json`、可选 `capabilities.json`、可选安全根 `icon.png` 和必需物理 `app/`。`outputDirectory` 和入口都相对于外层 `packageRoot/app/`；首段 `app` 合法，例如入口 `app/index.html` 对应物理 `packageRoot/app/app/index.html` 和运行时 `/app/index.html`。项目平台差异只能通过唯一 `adapter.Registry` 中的 `Adapter` 实现，公共命令不得按 Cocos/语言复制分支或维护第二份适配器实例表。

CLI 开发资源必须通过引擎无关的 `development.Source` /
`development.Mapping` 边界接入。Adapter 只提供资源源的 `Start/Stop`
生命周期，以及启动后固定来源、请求路径映射和附加 headers；CLI 公共代理只消费
mapping，App Developer Gateway 只消费代理地址、credential 与过期时间。两层公共
代码都不得判断 JavaScript、TypeScript、Cocos 或未来 Godot。新增引擎只能向唯一
`adapter.Registry` 注册 CLI Adapter，不得修改 App 代码、App 资源源类型或公共代理
形成引擎分支，也不得新增第三套代理。

CLI `dev` 使用受控本地代理建立真实 App 开发资源会话并跟随日志；目标缺少项目时只上传包含必需清单、可选能力声明、可选图标和必需入口占位文件的最小基础包，普通网页资源变化不得完整上传。`run` 必须由适配器正式构建、完整上传、原子安装并启动，输出 `runId` 后返回且不附加日志；`logs` 只读当前运行；`update` 更新 SDK 后转交适配器。公开 `create/push/sdk` 不得恢复。`get` 只允许空目录并固定恢复 JavaScript 工程，不对旧目录或 TypeScript/Cocos 执行隐式迁移。目标 token 只能使用 DPAPI、Keychain 或 Secret Service 保存；旧明文配置必须拒绝并要求重新执行 `to`。

App 只允许正式已安装资源和临时开发资源，两者必须实现同一
`GameWebResourceSource` / `GameWebResourceProvider` 边界；GameAssetGateway、
浏览器分享网关和 WebView 不得各自复制来源分支。开发 Provider 只允许固定 HTTP 根
上游，校验同一 CLI 请求来源、一次性凭据和最长 24 小时有效期，保留 GET/HEAD 与
WebSocket 子协议；不得使用环境代理或转发 `/playmesh/**`、`/bucket/**`。同一时刻
的开发启动、正式启动、重启与停止必须串行，并用不可变 `runId` 绑定页面处理器；替换
会话前先完整关闭旧页面、资源网关及上下游 WebSocket。停止失败时保留可重试会话，
凭据到期或 Gateway 关闭时主动撤销会话和既有连接，异步 WebView 初始化在组件销毁后
必须关闭迟到的网关结果。

所有 Developer Gateway 整包发布必须经过开发者本地历史事务，Agent/CLI 不得绕过；整包恢复覆盖必需 `main.json`、可选 `capabilities.json`、可选 `icon.png` 与必需 `app/`。开发者工作区禁止通过普通文件接口写入 `main.json`，只允许可视化项目设置和受校验的 manifest API 更新；`id`、`author` 和 `lastModifiedAt` 始终不可修改，其他字段经完整清单校验后可保存。所有包导入、导出和下载中转使用按入口固定命名的临时 ZIP，操作前覆盖旧文件、完成后删除；并发请求必须串行，禁止按次数生成永久累积的随机中转文件。

Game SDK 与 App Bridge SDK 的唯一手写源是 `lib/core/game_sdk/features/` 下的 Dart feature。每项功能的 TypeScript/声明片段与 Dart 宿主命令执行器必须保存在同一个 feature 文件，并在 `sdk_feature_registry.dart` 统一注册；Bridge 本身只负责消息解析、上下文组装、统一分发和回包。Game SDK 引用 App SDK 版本时只允许手写 `__PLAYMESH_APP_SDK_VERSION__` 占位符，由即时注册表和正式生成器从同批 App bundle 注入 `.ts/.js/.d.ts`，禁止硬编码版本或 `*-empty` 伪版本。每个命令执行器必须声明 `supportedVersions`；命令名不要求全局唯一，但注册表必须拒绝相同命令和相同版本命中两个执行器。运行游戏时先对 `main.json` 做严格版本校验：永久兼容基线集合包含 Game SDK `4.1.0` 以及 App Bridge SDK `3.2.0`、`3.3.0`，再由注册表解析到对应兼容 bundle；未在 `supportedRequestedVersions` 列出的中间值仍须拒绝。SDK 发出的宿主命令携带实际 bundle 版本并再次经过同一注册表校验。后续 SDK 升级时兼容请求集合只可追加、不得缩小，公开命名空间、函数、参数接受范围、返回结构、事件、错误 code 与调用语义不得破坏；增量增加新函数使用 `MINOR` 版本。

开发运行时、游戏资源网关、分享网关、Developer Gateway、SDK 下载和 AI 声明都直接从 Dart 注册表组装 `.js/.d.ts` 与版本，不允许回退读取可能陈旧的打包静态 SDK，也不允许用测试注入脚本绕过注册表。正式构建先执行 `node tool/generate_sdk.mjs`，从同一注册表生成 `sdk-src/*.ts` 中间产物和 `public/sdk/v1/` 下的 `.js/.d.ts`，同步关联契约，并强制校验 TypeScript 发出的命令集合与已注册 Dart 执行器集合一致。一次版本变更必须同步更新默认模板、机器契约、编辑器补全、明确兼容请求版本集合、测试断言和开发文档，并在版本或验证记录中写明升级原因。默认骨架和开发下载暴露当前版本；机器契约与校验器必须同时保留仍受支持的清单请求版本，不依赖历史静态文件、字段双写、命名空间 shim 或网关旁路。

## 错误和日志

错误必须分为用户可理解的提示和开发可定位的诊断信息：

```text
用户提示：联机码已过期，请重新获取
诊断信息：code=session_expired sessionId=... requestId=...
```

推荐日志字段：

```json
{
  "timestamp": 1760000000000,
  "level": "info",
  "component": "session-service",
  "event": "player.joined",
  "requestId": "req-1",
  "sessionId": "ABCD12",
  "userId": "u-temp-1",
  "playerId": "player-2"
}
```

日志禁止记录长期 token、完整分享邀请 URL、邀请 fragment、二维码 PNG/Data URL、完整
头像文件、摄像头画面、传感器原始敏感数据和用户未公开的资料。输入事件可以记录摘要，
调试原始数据必须显式开启；`getShareLinks()` 的结果也不得进入异常文本或崩溃详情。

## 测试规范

测试从小到大覆盖：

- 单元测试：模型校验、联机码、人数限制、权限检查、协议编解码。
- Widget 测试：页面状态、导航、错误提示、单机/联机入口切换。
- 集成测试：创建会话、浏览器中间层加入、短期凭证、WebSocket 输入链路。
- 游戏包验收：目录结构、`main.json`、必需入口、当前 SDK 版本和资源路径。
- 回归测试：每次修改协议、权限、会话状态或 Game SDK API 时执行相关测试。
- 平台发布测试：用户明确要求构建时，必须验证签名状态、目标架构、必需运行库和产物哈希，并把真实结果与未执行的真机项目分开记录。

每个新功能至少提供一个成功用例和一个失败用例。修复 bug 时先增加能复现问题的测试，再修改实现。

## 文档和变更回溯

代码、协议和文档必须一起更新：

- 修改用户流程：更新 `00-context.md`、`02-roadmap.md` 和对应页面任务。
- 修改架构边界：更新 `01-architecture.md` 和调用链。
- 修改 Flutter 结构：更新 `01-architecture.md`、`05-next-steps.md` 和测试说明。
- 修改环境或依赖：更新 `04-dev-env.md` 和运行命令。
- 修改规范：更新本文件，并在任务记录中说明原因和影响。
- 修改任何代码、契约、模板或提示词：按“版本与升级策略”检查受影响组件，并同步升级所有需要升级的版本来源。
- 每个重要决策记录“背景、选择、替代方案、影响、回滚方式”。

推荐提交或变更单按垂直功能组织，例如：

```text
feat(session): add browser join identity step
```

每次变更应能回答：改了什么、为什么改、影响哪些调用链、如何验证、如何回滚。

## 历史阶段与后续版本更新日志

第一至第六阶段状态保留在 `docs/status/`，第六阶段是最后一个阶段归档。后续更改不再创建新的阶段、阶段中间状态或阶段路线图条目，统一按实际发布版本维护更新日志。

每个发布版本必须同时维护两层日志：

- 详细版：`docs/version/{MAJOR.MINOR.PATCH}.md`，记录版本与构建号、发布日期、升级原因、用户变化、开发者变化、接口/数据/权限影响、版本矩阵、代码入口、验证结果、已知限制和升级注意事项。
- 简略版：在 App 内显示，只保留用户能感知的主要变化，使用简短中文，不出现内部文件、测试命令、阶段名称或实现细节。当前来源为 `lib/core/release/playmesh_release_notes.dart`。

详细版是版本事实的权威记录，简略版必须从详细版提炼且不能出现详细版没有的能力。每次 App 版本升级必须在同一次变更中新增或更新对应详细日志、App 简略日志和版本常量；未形成 App 发布的独立 SDK/Core 版本，也必须建立详细日志并明确受影响组件。日志命名不带 Flutter `+build`，同一语义版本的不同构建号在同一文档中按构建记录追加。

历史阶段文档只追加更正，不随意改写历史结论，也不再作为后续归档模板。版本更新日志规则详见 `docs/version/README.md`。

平台构建默认不执行；只有用户明确要求或授权时，自动开发任务才可使用已配置工具链串行构建，并必须如实记录签名、架构、包内条目和哈希。构建成功不能替代安装、真机行为或商店签名验证，也不能把旧产物当作本轮结果。需要执行 Flutter、Dart、Go 或平台原生工具时，遵循 `04-dev-env.md` 的执行环境与权限要求。

版本日志完成后，后续任务必须引用最近版本日志作为事实基线；计划中的能力写入任务或路线说明，只有实际完成并通过相应验证的内容才能进入已发布版本日志。

## 安全和权限

- 游戏需要的平台能力只在与 `main.json` 同级的可选 `capabilities.json` 中声明；`required` 属于主画面，单屏多人的 `controllerRequired` 属于控制器，运行时只暴露当前角色集合。能力 ID 按功能命名，不绑定具体 App 或浏览器实现。
- 能力 code、中文名、用途、`apiVersion`、方法、事件、平台状态、实例工厂、自检和资源释放必须集中在 `lib/core/capabilities/{capability}/` 的插件内。SDK 弹窗、开发者工作区、Schema/运行时校验和 API 输出不得维护平行硬编码清单；新增能力只增加独立插件目录并注册插件。
- 开发者工作区的能力测试必须展示全平台注册表，不按当前项目的 `capabilities.json` 过滤；项目声明只控制项目授权和运行时可创建范围。测试页显示插件版本、方法、事件、平台状态与实际返回数据，并持续执行到用户手动关闭窗口；一次 `POST /dev/api/capability-tests` 仍只返回该轮结果。
- `required` 非空时，主 SDK 在 App 与浏览器每次加载游戏时都必须展示全部能力并等待用户确认；拒绝则退出，结果不得持久化或写入 Authority 主机。文件缺失或列表为空时不弹窗。
- 当前平台不支持的能力必须在 SDK 弹窗中标注“本平台暂不支持”，但不能阻止用户同意后进入。游戏应通过 `playmesh.app.capabilities.getAvailable()` 做非阻塞降级；SDK 只允许创建已经声明、用户本次确认且当前设备可用的插件。
- 浏览器玩家必须由 SDK 读取或生成 `p_...` 玩家 ID 并确认昵称后，才能调用加入接口获得短期凭证。分享 URL 不得携带昵称或玩家 ID；`localStorage` 只允许保存 SDK 管理的 `playmesh.player-id.v1` 与昵称偏好，不得保存玩家凭证或游戏 Bucket。
- Core 必须保留掉线玩家的稳定 ID 和 `connected: false` 状态；同 ID 在线时拒绝后续 Join 和 WebSocket，旧连接掉线并撤销旧凭据后才允许同 ID 重新签发凭据。游戏通过 SDK 连接事件处理等待、中途加入和状态恢复。
- `playmesh.main.player.setNickname()` 必须在普通浏览器和 App WebView 的多人 Player 页面保持同一语义：浏览器把偏好写入当前 origin 的 `localStorage`，App 由宿主持久化，两者都同步当前 Core。单机和 `single_screen_multiplayer` 公共 Authority 屏必须拒绝。SDK 仍在普通浏览器提供统一昵称修改悬浮入口；App WebView 不要因此重复创建网页悬浮入口。
- 外部网页只能访问当前游戏和当前会话，不能访问 App token、用户文件、其他游戏包或任意原生端口。
- USB 设备优先映射为标准输入事件；不向 AI 生成的游戏默认开放原始 USB 设备。
- 所有权限必须在 SDK、服务端和 UI 三处保持一致，不能只隐藏界面按钮。
- AI 只能调用持久开发者工作区 token 有权限的项目 API，不能执行任意系统命令或访问其他项目。该 token、端口和工作区路径保存在 `playmesh-library/developer/settings.json`，不得写入日志或暴露给非开发者页面。
- 开发者工作区项目列表必须来自统一游戏库，不按“开发中”等展示状态过滤。最近打开项目只在浏览器本地持久化；首次进入或记录项目已不存在时必须强制选择，在尚未选择项目时不能关闭选择层。

## 游戏包安装规范

面向游戏作者的目录、`main.json` 和 SDK 契约统一维护在 `docs/game/`；本节只约束平台工程实现。

游戏包采用“压缩包作为传输格式，解压目录作为运行格式”。导入后先进入隔离临时目录，完成路径安全、大小、文件类型、`main.json` 和必需入口校验，再安装到用户安装库的 `packages/{gameId}/` 目录。运行时不重复动态解压。

Android 与 iOS 的 `playmesh-library` 位于系统应用支持目录。Windows、macOS、Linux 和其他非移动端必须将 `playmesh-library` 放在当前运行可执行文件同级，禁止写入 AppData 或其他用户应用支持目录。开发者工作区新建项目直接写入同一 `packages/{gameId}/`，不设置独立开发项目目录或发布步骤。

导入压缩包只在临时目录中存在；安装元数据保存 `gameId`、版本、内容哈希、解压路径和校验结果，用于问题定位和一致性检查。解压目录必须只读。安装失败不得覆盖已安装游戏。用户安装库只负责扫描、存储、加载、卸载和清理，不负责开发者版本回滚、版本决策或自动切换旧版本。卸载时直接删除整个 `packages/{gameId}/` 目录。

## 能力插件与 WebView 权限

能力宿主采用有状态实例协议，不把所有能力约束为订阅。公开桥接命令固定为 `app.capability.create/invoke/dispose`，异步输出固定为 `app.capability.event/error`；公开 SDK 通过 `playmesh.app.capabilities.create()` 返回 `invoke/on/onError/dispose` 实例。具体方法和事件由插件 `apiVersion` 定义，录音、语音转写等能力可以要求用户主动调用 `start/stop`。仅用于 WebView 权限声明且方法、事件均为空的插件不要求游戏创建实例，但每个能力仍必须保留独立插件和以该能力 code 注册的唯一权限执行器。

当前调用链：

```text
capabilities.json：按需声明 media.camera / media.microphone / device.midi
  -> SDK 初始化：App/浏览器每次展示能力确认，拒绝则退出
  -> 游戏直接调用 getUserMedia() / requestMIDIAccess({sysex:true})
  -> App WebView 权限回调把资源统一映射为能力 code
  -> 统一层核对当前角色声明与插件可用性，按 code 调用唯一执行器
  -> 未声明即拒绝；执行器拒绝或系统权限失败同样拒绝

capabilities.json：声明 device.vibration
  -> capabilities.create('device.vibration', {})：创建实例
  -> instance.invoke('vibrate', {duration/pattern/...})：通过 vibration 插件触发震动
  -> instance.invoke('cancel', {})：取消持续或重复震动
  -> instance.dispose()：释放实例

capabilities.json：声明 sensor.pose6d
  -> capabilities.create('sensor.pose6d', {rateHz})：按需启动共享 ARCore Session
  -> pose 事件：持续发送米制 XYZ、XYZW 四元数和跟踪状态
  -> openVideo({width,height,fps})：只签发不透明媒体源
  -> playmesh.app.media.open(source)：由已注册媒体适配器返回 MediaStream
  -> media.close() / instance.dispose()：关闭消费者并回收媒体源
```

原始加速度计、陀螺仪、设备方向等非敏感能力不注册 Playmesh 能力，游戏按平台支持情况
直接使用标准 Web API。文件选择由 `<input type="file">` 的显式用户动作触发，不声明
能力且不得静默读取文件。摄像头、音频、MIDI 和震动各自位于独立插件目录。
`media.camera` 与 `device.midi` 当前没有公开方法或事件；`media.microphone@1.1.0`
提供 `toText` 以及识别结果、声音级别事件。后续原生拍照、录音或 MIDI 适配继续在
对应插件扩展。震动插件完整透传 `vibration` 的时长、振幅、波形、强度、重复、锐度
和预设参数，并提供 `cancel`；工作区自检只查询支持状态，不得主动制造震动。
基于相机和 ARCore 的 `sensor.pose6d` 是明确例外，必须声明、确认并在创建实例时申请
相机权限；位姿与按需视频分别走能力事件和媒体适配器，不能把视频帧塞入 JSON Bridge。

## Authority Client 与 Go Core 边界

Go Core 只做通用中转，不承载任何具体游戏规则。创建会话时必须把当前 App 游戏运行端明确写入 `authorityClientId`；后续加入者不能自行成为 Authority。`single_screen_multiplayer` 中 App 主机不进入 `players`；`multi_screen` 中 App 主机可同时作为 Player 并计入人数，但 Authority 判定不得依赖玩家数组位置或加入顺序。

游戏包可以按需使用 `app/static/js/service/` 目录或 `service.js` 入口组织上述权威逻辑，此目录和文件名是推荐约定，不是强制目录。该逻辑应在 Authority Runtime 中执行，不应被 Go Core 直接解析。SDK 应提供当前客户端角色、`authorityClientId`、玩家成员快照、Authority 连接状态和权威状态版本号；大屏公共显示端的当前玩家必须为 `null`。

每个多人游戏运行时最多由 SDK 管理两条物理 WebSocket：原有 Session WS 负责 JSON 会话、权威动作和状态同步；Binary WS 在首次调用 `playmesh.main.binary` 或 `playmesh.main.rpc` 时按需创建，复用当前会话凭证，并在游戏退出、Session WS 断开或 Authority 退出时由平台统一释放。游戏代码和 `service.js` 不得直接创建、保存或操作任何 Core WebSocket。

一条 Binary WS 复用多个逻辑 Channel，Channel ID 同时是加入令牌。只有 Authority 可以创建和关闭 Channel，创建后 Authority 自动加入；其他玩家只能凭 ID 加入。`playmesh.main.binary.authorityPlayerId` 固定为 `"authority"`。所有参与方统一使用 `send(targetPlayerId, data)` 单发、`send(targetPlayerIds, data)` 多发、`send(data)` 广播；`sendLatest(targetPlayerId 或 targetPlayerIds, data)` 发送定向最新帧，`sendLatest(data)` 发送最新广播，不增加 Authority 专用发送签名。

Channel `mode` 只有 `authority` 与 `relay`。`relay` 直接转发原始字节；`authority` 中非 Authority 消息先交给 Authority 的 `onForward`，其上下文始终提供去重后的 `targetPlayerIds` 数组，一次多目标发送只审核一次；返回 `void` 原样通过、返回 `Uint8Array` 替换后通过、抛错则拒绝。Authority 自己发送时直接投递，不能再次进入审核形成循环。带目标的 `sendLatest` 只替换同一 Channel、发送者和规范化目标集下尚未发送或尚未开始审核的旧帧，单参数 `sendLatest(data)` 对广播做相同合并；Authority JavaScript 处理器一旦开始执行，旧新审核都必须继续并各自处理结果。

`playmesh.main.rpc` 必须使用同一条已认证 Binary WS 上的内部 RPC 帧，不得退回
`game.submitAction`、`authority.result` 或其他 JSON 信封，也不得为每个 path 创建公开
Channel。客户端只有异步 `request(path, data, options?)`；`onRequest(path, handler)`
只能由 Authority 调用，Core 后台只向固定 Authority 投递并只接受该连接的响应。
handler 可以返回任意受支持的可传输值或 Promise：JSON 兼容值、`undefined`、`Blob`、
`File`、`ArrayBuffer`、`Uint8Array`；函数、DOM、循环引用和其他类实例必须拒绝。
Core 不解析业务 payload，只校验会话身份、path、单帧大小、每局/每玩家挂起数量、总挂起
字节和 100～60000 ms 超时。客户端超时不等于取消已开始的 Authority handler。

权威处理函数通过 `playmesh.main.authority.onService` 注册，返回目标玩家 ID 列表：一个 ID 表示定向回复，多个 ID 表示回复多个玩家，当前所有在线玩家 ID 表示广播，空列表表示不发送。Go Core 根据目标列表执行路由，但不参与游戏业务判断。游戏逻辑只能使用 SDK 注入的 `playerId`、角色和成员快照，不能使用或伪造底层连接对象。`onWs` 不属于普通游戏开发 API。

SDK 必须负责连接级协议分发，开发者负责业务层消息处理和权威目标声明。普通玩家默认模板只暴露 `playmesh.main.game.onMessage(handler)`；权威模板必须暴露 `playmesh.main.authority.onService(handler)`，允许处理函数返回 `targetPlayerIds` 和 `payload`，从而定向回复一个或多个玩家、广播给当前成员或返回空列表。开发者不能根据玩家 ID 查找连接、直接实现广播、重复分发消息或直接调用底层 WS。未来的 `game.on(eventType, handler)` 只能是普通玩家端 `onMessage` 的本地语义化封装。

Go Core 只校验连接、会话、角色、凭证、消息格式、大小、频率和基础序列，不判断动作在具体游戏中是否正确。所有玩家动作由 SDK 注入真实会话身份后路由到权威服务入口；普通玩家不能直接发布权威状态。MVP 权威玩家断开后暂停或结束对局，不自动选举新权威；权威迁移必须另立协议并补充测试矩阵。

不建议将游戏 `service.js` 直接嵌入 Go Core：这会使 Go Core 依赖某个 JS 引擎，且必须额外处理脚本沙箱、死循环、内存、异步模型、跨平台打包和恶意游戏包。若未来确实需要独立进程级服务器，应优先评估受限 Node.js/QuickJS 服务进程或 WASM 服务运行时，但它们属于后续架构，不能作为第三阶段前置条件。

### 权威链路性能规则

权威链路允许存在 SDK、App 中转和 Go Core 转发，但不得把所有数据都按同一可靠等级处理：

- 答题、跳过、准备、开始和结算确认属于可靠动作，必须有序进入权威服务。
- 传感器采样、动画帧和连续摇杆值属于状态流，由 SDK 限频、合并并允许丢弃旧值。
- 权威服务只广播必要的状态变化或固定频率快照，不重复广播未变化的大对象。
- 权威状态必须带 `revision` 或等价版本号，客户端丢失中间状态后可以请求最新快照。
- SDK 应记录动作从提交到权威确认的耗时，便于区分本机 JS 处理、App 桥接、Go 转发和局域网传输问题。
- Binary WS 单帧上限为 4 MiB，单次定向发送最多 1024 个去重目标，单连接允许每秒 2000 帧和 64 MiB 入站流量，出站队列上限为 32 MiB，每局最多 1024 个 Channel；Authority 审核最多挂起 1024 项或 128 MiB，单次审核 15 秒超时。内部 RPC 每局最多挂起 256 项、每个发送者最多 32 项、总 payload 最多 32 MiB，请求超时为 100～60000 ms；SDK 单值编码上限为 `4 MiB - 64 KiB`。这些是局域网防失控边界，不是建议业务速率。多目标 payload 只能上行一次并由 Core 扇出；广播目标由 Core 按 Channel 当前在线成员展开并排除发送者。可靠帧达到上限时必须返回错误，连续状态应优先使用 `sendLatest` 合并尚未发送的状态帧。

## 完成定义

一个功能只有在以下内容齐全时才算完成：

- 代码实现和模块边界明确。
- 调用链和数据模型已记录。
- 成功、失败和权限边界已处理。
- 相关测试通过。
- 日志可以定位关键步骤。
- 相关文档和示例已同步。
- 已完成版本影响评估，并按当前版本规则升级受影响组件。
- 已知限制和后续工作已记录。
