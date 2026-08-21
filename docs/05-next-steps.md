# 下一步任务

## 当前阶段

第一至第六阶段均已完成并归档，事实基线见：

- `docs/status/phase-01-flutter-webview.md`
- `docs/status/phase-02-go-core.md`
- `docs/status/phase-03-game-sdk-fishing.md`
- `docs/status/phase-04-web-dev-channel.md`
- `docs/status/phase-05-complete.md`
- `docs/status/phase-06-complete.md`

Playmesh `1.6.1+8`、Go Core `0.2.0`、Game SDK `1.4.2` 等数字仅是第六阶段历史
归档基线，不再用于当前生成、运行或发布。当前正式版本为 App `4.2.0+28`、Go Core
`0.5.0`、Core 协议 `1.3.0`、Catalog API `3.0.0`、Relay 协议 `3.0.0`、
Developer API / OpenAPI `4.3.0`、Developer CLI `2.0.0`、Game SDK `4.1.0`、
App Bridge SDK `3.3.0`；当前没有新的未发布变更。Game SDK 以 `playmesh.main.*` 公开游戏本体与对局能力，
App Bridge SDK 以 `playmesh.app.*` 公开当前客户端能力。面向游戏开发者的唯一全局
对象是 `window.playmesh`，其根级公开成员严格只有 `ready`、`main` 与 `app`；
`window.playmeshApp` 与公开 `__*` 内部桥接均不存在，内部协作使用不可枚举的私有
`Symbol` runtime。`main.ready` 内部先等待 `app.ready`，根 `playmesh.ready`
只复用这条初始化链并返回 `{main, app}`。第六阶段后
不再开始新阶段，后续交付统一进入版本更新日志。正式游戏固定从已安装包启动，经
`GamePage -> GameLauncher -> InstalledGameWebResourceSource -> LocalGameWebView`
进入统一运行时；联机时再由 `GameRuntimeBridge -> GoCoreSessionClient` 接入 Core，
游戏代码不得直连 Core。外部 CLI `dev` 只把同一链中的资源源临时替换为
`DevelopmentGameWebResourceSource`；App WebView 仍由 `playmesh-app.js` 提供本机
身份与当前可用设备能力。

## 当前稳定基线

```text
游戏库扫描 playmesh-library/packages/{gameId}/main.json
  -> 游戏详情
  -> 应用 orientation，并行尝试可选全屏
  -> GamePage / GameLauncher
  -> InstalledGameWebResourceSource / InstalledGameWebResourceProvider
  -> GameAssetGateway / WebView / Game SDK + App SDK
  -> 返回详情 / 退出游戏库 / 刷新游戏
  -> 恢复进入前的全屏状态和系统屏幕方向
```

当前文件导出入口固定在源代码开发工作区：原“发布”改为“导出”，其下“导出源码”
直接复用既有 `/package` 宽松备份 Operation；普通浏览器下载，App WebView 由原生宿主
流式保存。“上传到发布源”仍执行完整校验和既有多源发布流程；“安装包导出”通过新增的
`package_exports.*` Operation 选择 Android ARM64、Android x86_64 或 Windows x64，
按需下载/复用固定 Runtime 底包，Android 与 Windows 都通过私有 Go provider 注入
RSA-OAEP + AES-GCM 的 PME1 加密游戏载荷，并在载荷内写入可选中转服务器后生成 APK 或
Windows ZIP。安装包与源码包共用浏览器下载/App 原生保存链。游戏详情只负责查看、开始、清理数据
和删除，不再提供导出；既有 `/package` 与 CLI 损坏项目修复语义不变。

```text
外部 CLI dev
  -> adapter.Adapter / development.Mapping / CLI development.Proxy
  -> DeveloperWebGateway 建立临时会话
  -> GamePage / GameLauncher
  -> DevelopmentGameWebResourceSource / DevelopmentGameWebResourceProvider
  -> 与正式游戏共用 GameAssetGateway / WebView / Bridge / 存储 / Core
```

```text
Go Core 监听 0.0.0.0:0
  -> 宿主上报实际端口
  -> Flutter 本机使用回环地址
  -> 分享层列出全部可用局域网 IPv4 地址
  -> /{entry} 权威页面
  -> Game SDK 直接调用受控 Core Join 能力并建立 Session WebSocket
```

会话拓扑固定为：

- `single_screen_multiplayer`：创建会话的 App 主机是公共显示端与 Authority Client，不属于 `players`；玩家只能通过 Controller 加入。
- `multi_screen`：创建会话的 App 主机固定为 Authority Client，并可同时作为 Player 计入人数；不得把玩家首位或加入顺序当作 Authority 规则。

## 已归档开发记录：Playmesh 1.8.0

## 第四阶段交付基线

已归档的纵向链路：

1. 首页“制作游戏”页可在独立固定端口开启开发者模式，默认 `16666`，并持久化端口、自定义或随机 token 和工作区路径；用户再按需要展开“源代码开发”或“可视化开发”。
2. 关闭开发者模式或 App 退出时停止监听；重新开启或 App 重启后恢复同一工作区链接，局域网设备可直接重连。
3. 工作区可新建、复制、设置和删除项目，以 IDEA 风格项目树浏览并编辑文本文件；支持新建、删除、上传、Git 风格双栏 Diff、差异块应用、快速批量操作和项目级本地历史，不提供嵌入式主页面预览。
4. 工作区提供运行按钮；多人项目运行后显示与游戏分享面板一致的地址切换、链接复制和二维码入口。
5. 已提供 `/dev/docs`、OpenAPI、Developer Session Schema、SDK Manifest、请求示例和当前接口鉴权/AI 可用性面板。
6. 文件变更、运行状态和客户端日志通过统一 SSE 通道同步；浏览器原生 `console` 输出保留，同时在存在开发者监听时复制到后台日志面板。
7. “制作游戏”页、Core 地址、开发者模式地址和游戏分享链接均支持长按或拖选复制。
8. App 内置 WebView 与外部浏览器使用同一套响应式工作区。

项目校验、文件行列诊断、5 分钟窗口项目级本地历史、机器契约、运行状态、SSE 和 Console 日志诊断闭环均已纳入交付。第四阶段不包含测试会话、虚拟玩家、设备模拟、热重载或游戏包导入/导出。

## 第五阶段完成

第五阶段已于 2026-07-17 完成。`entries.game`、`entries.controller` 与 `authority.entry` 已统一进入 Manifest、游戏库扫描、开发校验、App/浏览器运行、模板和机器契约；状态同步、自动延迟、App SDK 网页性能层、应用包导入/导出与工作区文件整理也已完成。完成归档见 `docs/status/phase-05-complete.md`。

第五阶段把 SDK 升级为 AI 友好的轻量权威状态同步运行时，并加入 SDK 自动联机延迟显示。默认采用状态同步而不是帧同步：游戏或 AI 只维护权威状态、处理玩家输入、编写 tick 规则和渲染表现；SDK 负责连接、输入限频/合并、Authority tick、快照版本、状态分发、重连恢复和基础诊断。FPS 和延迟都由 App SDK 在网页内自动渲染，多人游戏显示当前玩家到权威端并收到返回的往返耗时，和 FPS 共用左上角位置及开关；App 运行时由 App 工具坞控制开关，普通浏览器由 App SDK 提供悬浮组件并放入昵称修改入口；Game SDK 不创建浏览器性能 panel，单人游戏不显示延迟，游戏代码不需要手动创建组件。

第五阶段同时实现统一 `packages/{gameId}` 游戏库的导入与导出：导入包经过路径、清单和资源校验后原子安装；导出由用户直接选择系统保存位置，因此不产生需要清理的临时分享包。这里“同一目录”只指 App 内 Developer Workspace 新建或编辑的项目与其他已安装游戏都位于 `packages/{gameId}/`。外部 CLI `dev` 使用临时开发资源源，不把网页变更写入正式 `app/`；只有 `playmesh-cli run` 才把 `playmesh/package/` 原子安装为正式包。

第五阶段还允许游戏在 `main.json` 中自定义运行入口，覆盖普通游戏首页、控制器首页和权威 JS。当前模板会相对于外层物理 `app/` 显式写入普通游戏首页 `index.html`、控制器首页 `controller/index.html` 与多人 `authority.entry`；所有游戏都必须声明 `entries.game`，单屏多人必须另行声明 `entries.controller`，多人必须声明 `authority.entry`，运行时不为缺失字段提供默认回退。自定义入口只能解析到当前游戏包 `app/` 内文件，必须由项目校验拦截平台保留命名空间、编码绕过、越界路径、缺失文件和外部 URL。用户首段 `app` 合法，例如入口 `app/index.html` 解析到物理 `app/app/index.html` 和运行时 `/app/index.html`；只有 `playmesh`、`bucket` 是保留首段。当前游戏库本地导入在此严格结构之上增加普通网页 ZIP 转换：包内必须存在 HTML，由用户确认方向、模式、显示方式和主/控制器入口，转换服务把网页内容整体迁移到 `app/` 并保留包内原相对路径、生成 `main.json`，再复用标准包校验和原子提交；已有 `main.json` 的包仍严格导入。

第五阶段实施任何 SDK/API/模板改动后，必须同步更新所有相关项目文档、SDK 文档和 AI 提示词文档，特别是 SDK Manifest、JSON Schema、OpenAPI、开发者工作区说明和 `assets/playmesh-library/public/developer/prompts/` 下的提示词。

## 第六阶段完成

第六阶段已于 2026-07-18 完成。加入 App 不再要求预装游戏，而是直接加载权威主机提供的当前入口；游戏与控制器的全屏请求不再参与运行前置条件，失败时只提示，并可在 WebView 悬浮工具中按需进入或退出。Android 已接通系统文件打开/分享入口：压缩包复用 Playmesh 包导入，单个 HTML 使用无 SDK 的独立 WebView，游戏包导出交给系统保存或分享。

运行身份拆分为两层：`playmesh-main.js` 在所有平台以 `playmesh.main.*` 使用 Authority
主机提供的游戏声明、会话、玩家和游戏数据；`playmesh-app.js` 以
`playmesh.app.*` 提供当前终端环境、本机日志和覆盖层，App 中还提供持久身份与能力
插件宿主。两者在 App WebView 和普通浏览器中成对注入，旧 `playmesh.js` 不兼容。
普通浏览器的 App 原生能力不可用，但统一覆盖层仍由 App SDK 渲染。具有公开方法或
事件的原生适配能力通过 `capabilities.create()` 创建有状态实例，再使用
`invoke/on/addEventListener/onError/dispose`；摄像头、麦克风和 MIDI 在 WebView
权限回调中核对声明，游戏直接使用标准 Web API。Android `sensor.pose6d` 通过能力
事件输出位姿，需要画面时再由 `playmesh.app.media` 按需打开不透明媒体源。单屏多人
按主画面/控制器拆分方向和能力声明，空声明不会回退到另一角色；Game SDK 另提供平台
托管的独立 Binary WebSocket、多逻辑 Channel 和 Bucket 二进制上传。

移动端开发工作区顶部操作、二级菜单、弹层边界、项目搜索选择、文档跳转和界面切换动效已收口。完整归档见 `docs/status/phase-06-complete.md`，验证记录见 `docs/verification/phase-06-complete-2026-07-18.md`。

## Playmesh 4.2.0 局域网发现实机验收交接

正式 App `4.2.0+28` 已完成局域网发现与 App SDK 自动化开发并发布，后续工作
不是再造分享或加入通道，而是四个受支持平台的跨设备实机验收：

- Android、macOS、Windows、Linux 分别验证自定义 IPv4 UDP multicast 的发布、发现、
  更新/丢失、权限拒绝、物理及支持组播的虚拟网卡动态增删、部分接口失败和真实加入；Web
  与 iOS 只验证明确的 `unsupported` 自动发现/发布。iOS 的扫码、手工邀请和分享链接仍须
  保持可用。
- 验证启动和开发预览默认不公开；打开分享面板或无参数 `setPublished()` 后出现，关闭
  面板仍保持，退出游戏后移除；重复调用不能重复注册。
- 验证 App 页面显示全部游戏的附近对局，以纯文本展示游戏名、主机昵称、数据报真实来源
  IP、多人当前/最大人数或“单机”，能随公告/presence 自动更新并支持手动刷新；点击后
  发现 lease 与候选必须保留到预检和复查结束。游戏 SDK 只显示当前 gameId 的既有
  `instanceId/gameId/name/host`，不增加内部展示元数据或图标端点；手工链接、扫码、发现项
  和 SDK 加入都经过统一预检并进入既有 `RemoteGamePage`。
- 验证固定组播 `239.255.80.77:53584`、wire v1、1 秒公告、4 秒 TTL 与 1200 字节上限；
  地址必须来自数据报 source IP。没有 DNS-SD/TXT 兼容、第二发现栈或已知节点单播探测，
  也不能把 AP 隔离、VLAN、防火墙、禁用组播或 VPN 策略下的不可达误报为全 LAN 保证。
- 验证 `getShareLinks()` 与面板读取同一 LAN/有效 Relay URL 和同一 PNG，且仅本机
  Authority/standalone host 的 App WebView 可用。该返回包含 bearer 凭据，测试日志、
  崩溃信息和持久文件不得记录 URL、token 或 PNG。
- 验证 `disableSystemMenuTriggers()` 在 ready 后单向解绑 Escape/Menu/Back 自动触发，
  显式菜单仍可打开/关闭，重复调用无副作用，文档刷新后恢复默认绑定。

实现边界见 `docs/implementation/playmesh-4.2.0-lan-game-discovery.md`。App、Game SDK、
App Bridge SDK、Go Core、Core 与 Relay 版本在该功能中均保持现有值；实机验收完成前
不得把自动化通过写成四个受支持平台的跨设备完成；iOS 仅验收稳定 unsupported 与保留入口。

## 后续变更要求

后续所有更改都必须按需升级版本号，并遵循 `docs/06-engineering-standards.md` 当前定义的语义版本与 Flutter 构建号规则。每次变更必须评估 App、Go Core、Game SDK、App Bridge SDK、Developer API、Core 协议和游戏包中哪些组件受影响；只升级受影响组件，但必须同步代码常量、模板、机器契约、编辑器补全、测试与文档。

不再创建第七阶段或新的阶段状态文档。每个发布版本在 `docs/version/{MAJOR.MINOR.PATCH}.md` 保存详细更新日志，并同步 `lib/core/release/playmesh_release_notes.dart` 供 App 设置页显示简略版；规则与当前入口见 `docs/version/README.md`。

## Playmesh 1.2.0 完成

本机游戏库可以通过独立 Catalog Gateway 分享，提供带可选 Bearer Token 的分页搜索和标准游戏包下载。现有游戏库内部新增在线游戏库入口，可并发读取多个启用源、按 ID 去重、扫码配置与分享源，并通过可停止/删除的多选下载队列安装游戏。详细接口和边界见 `docs/catalog-api.md`，版本事实见 `docs/version/1.2.0.md`。

## 已归档开发记录：Playmesh 2.0.0

- 分享弹窗统一为“局域网 / 服务器 / 房间状态”，局域网和公共中转可同时承载同一 Core 会话。
- App 无论经局域网还是服务器加入，都先通过稳定的 `127.0.0.1` 本地 Origin 加载；普通局域网浏览器继续直连 Authority 地址。
- 公共中转服务器从在线游戏源列表选择，按 `/apps/info` 声明筛选并异步展示最新延迟；中转连接和二维码 Host 前缀使用 Go Server 声明的 `publicBaseUrl`，不再从游戏源地址推导。Go Server 只持有配对凭据，端点密钥从未发送给它，因此它只能复制无法解密的密文字节。
- 主机中转采用动态热池：上限直接读取 `/apps/info.relay.maxConnectionsPerTunnel`，
  空闲时最多保留 4 条热连接，被配对后立即补充，活跃连接结束后自然收缩。
- 端到端密钥只存在于两个 App 端点，放在邀请 fragment 中且不进入任何中转 HTTP/Upgrade 请求；TLS 保持可选。
- 局域网邀请使用 `/playmesh/join#inviteToken=...` 落地页交换 HttpOnly Cookie，
  再重定向到 `main.json` 声明的实际游戏或控制器入口；manifest 查询参数不含平台
  覆盖键。普通浏览器继续直连，局域网 App 解析同一链接后
  使用本地回环。公共邀请收敛为 `/j/{tunnelId}#inviteToken=...`，只有 App
  解析 fragment，并在回环 Origin 下恢复真实根相对入口。
- 游戏页返回只弹出当前路由并恢复来源页面；开发者工作区运行游戏时不再清空
  工作区导航栈。
- Authority 分享面只保留外层物理 `app/` 映射的根资源、`/bucket/**`、`/playmesh/**` 和 SDK 无法替代的受控底层连接能力。`/app/**` 是物理 `app/app/**` 存在时的普通游戏资源路径，不是外层目录的别名；新增平台能力仍优先修改 SDK，平台入口只放入 `/playmesh/**`，不增加 `/api/*` 分享路由。
- 完整架构与验收项见 `docs/remote-game-relay.md`。

## 必须保持的边界

- 游戏包直接位于 `playmesh-library/packages/{gameId}/`，不增加版本或 `files` 中间目录。
- 源代码工作区导出只复用 `GET /dev/api/projects/{projectId}/package`；浏览器与 App
  WebView 只是交付适配器，不得再实现第二套打包器或借用需要 GDevelop editor lease 的
  Blob 暂存路由。
- `packages/{gameId}/app/` 直接映射为运行时 `/`；平台公共 SDK、头像等资源位于 `playmesh-library/public/` 并通过 `/playmesh/...` 暴露。运行时只额外映射 `data/data` 中由 SDK 上传的文件到 `/bucket/{bucket}/{file}`；`data/json` 与 `cache/` 永不映射。
- 普通 JSON 持久化文件位于 `packages/{gameId}/data/json/{bucket}.json`；同步 GDevelop
  逻辑名使用 `data/json/logical/sha256-{digest}.json` 原名 envelope。二进制上传位于
  `packages/{gameId}/data/data/{bucket}/{timestamp-ms}.{ext}`，不增加 `{userId}` 目录。
  异步与上传 Bucket 名称仍必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- Core 每次启动都使用系统分配端口，实际端口由宿主上报。
- 开发者 Gateway 与 Core 分离，默认固定端口 `16666`，可在首页“制作游戏”页修改；不得为了修改开发者端口重启 Core。
- Android 发布物包含 `playmesh_core.aar`，Windows 发布物包含 Runner 同目录的 `playmesh-core.exe`。
- `orientation`、`displayModes` 和 `modes` 是独立维度；当前 `displayModes` 与 `modes` 都只能声明一个值。
- 浏览器分享 token 在当前游戏会话期间有效，关闭附加层和刷新游戏不撤销；退出游戏、会话结束或 Core 重启后失效。
- 分享地址列表可点选，二维码始终对应当前选中的地址。
- 主机与 App 扫码加入页使用同一套悬浮工具语义；主机分享入口为一级按钮，所有 App 游戏工具只保留返回而不重复提供退出。普通浏览器由 SDK 提供不含 App 导航和分享能力的对应功能区。
- 分享链接/二维码面板在视口内居中并动态适配，内容超出屏幕时允许整体滚动；悬浮工具二级界面固定使用高对比度配色，不继承游戏显示颜色。
- 所有 Bucket 数据只保存在开始游戏的 Authority 主机；普通浏览器和其他 App 玩家由 Game
  SDK 通过绑定当前游戏/会话的同源 JSON Bucket HTTP GET/PUT/DELETE 路由访问，旧 Session
  WebSocket 存储 RPC 与 fallback 不保留。该路由是 SDK 内部传输，不恢复可任意调用的
  `/api/storage`。Binary upload 继续独立使用原始字节 POST。
- FPS 由游戏在真实渲染点调用当前客户端的 `playmesh.app.performance.reportFrame()` 上报，默认显示在左上角并可从悬浮工具坞关闭。
- 平台构建仅在用户明确要求时执行；产物结构验证必须记录到 `docs/verification/`，安装、真机运行和生产签名仍由用户或 CI 验证。
- 公共显示端不得进入 `players` 或提交玩家动作。

## 明确排除

- 中心化完整房间大厅；局域网只提供用户显式公开后的 UDP multicast 附近对局，不做后台
  常驻服务、云端房间索引、旁观者列表或已知节点单播探测。
- 云端账号。
- 完整原生键盘、USB、摄像头、音频和 MIDI 方法适配。加速度计、陀螺仪和设备方向由游戏按 WebView 支持情况直接使用标准 Web API；原生震动继续通过 `device.vibration` 插件接入。
- iOS 自动发现/发布；扫码、手工邀请和分享链接仍保留。另不包含 iOS 正式发行/商店分发
  和云端游戏包分发。
- 创意工坊与生产级签名审核系统。
