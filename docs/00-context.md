# Playmesh 项目上下文

## 文档阅读顺序

当前文档推荐按这个顺序阅读：

1. `00-context.md`：项目定位、阶段基线和当前取舍。
2. `01-architecture.md`：Flutter、Go、Native、HTML Game Runtime 的职责边界。
3. `02-roadmap.md`：当前阶段和后续路线。
4. `05-next-steps.md`：最近可执行任务清单。
5. `04-dev-env.md`：本机开发环境记录。
6. `harmony-release.md`：OpenHarmony 工具链、能力边界、Go Core 注入、HAP 构建与签名。
7. `06-engineering-standards.md`：代码复用、调用链、测试、日志和文档规范。
8. `version/README.md`：第六阶段之后的版本更新日志与 App 简略日志规则。
9. `catalog-api.md`：本机游戏源、在线多源游戏库、鉴权和下载队列。
10. `remote-game-relay.md`：局域网、本地回环网关、公共中转和端到端加密边界。
11. `game/README.md`：游戏开发文档入口，包含游戏包、SDK、默认模板和开发者通道文档。

## 项目定位

Playmesh 是一个局域网优先的跨平台派对游戏平台。应用负责用户身份、游戏启动、联机会话和统一入口；具体游戏运行在 WebView 中。

核心模式：

- App 充当游戏启动器、房主端和加入入口。
- Go 提供本地 HTTP/WebSocket 联机会话服务。
- Flutter 负责 App UI、页面流转、WebView 容器和平台交互入口。
- HTML 游戏运行在 WebView 中；游戏声明区分大屏模式和普通模式。
- 手机、手柄、键盘、摄像头、陀螺仪等输入源被抽象成统一输入事件。
- TypeScript Game SDK 是 HTML 游戏访问平台能力的唯一入口。

## 当前核心判断

- Go 适合做本地通讯、房间、协议、包管理，不适合直接读取摄像头、手柄和系统权限。
- Android/iOS/HarmonyOS 的硬件能力分别由 Kotlin、Swift、ArkTS 原生层采集，再传给 Flutter/Go/HTML SDK。
- AI 生成的 HTML 游戏不能直接获得原生 JS Bridge 权限，必须经过受限 SDK 和权限系统。
- 默认自动验证限于静态分析、Flutter/Go/SDK 代码级测试以及与平台编译无关的资源和语法检查。只有用户明确要求平台构建时，才可使用其已配置工具链生成并检查产物；安装、真机行为和生产签名仍需用户或 CI 验证。iOS 发布、体感和云端仍放在后续版本评估。
- 第三阶段已完成真实会话、WebSocket、Game SDK、统一游戏包扫描和浏览器控制器入口；平台当前不内置游戏 Demo。
- 远程联机只通过已启用在线游戏源声明的公共中转提供；Go Server 没有端点密钥，只能配对和复制密文字节，不能成为通用反向代理。

## 第一阶段目标

第一阶段只验证 Flutter 基础界面和最核心的 WebView 容器，WebView 先显示 App 内置静态 HTML，不接 Go 和真实联机：

```text
Flutter App
  -> 设置当前用户资料
  -> 从游戏库选择游戏
  -> 查看游戏详情
  -> 点击“开始游戏”
  -> 进入独立的全屏游戏页
  -> WebView 加载内置静态界面
  -> 返回详情 / 退出到游戏库 / 刷新游戏 WebView
```

第二阶段已实现 Go Core 与 Flutter 通讯；第三阶段在此基础上完成真实会话、联机码、二维码与浏览器加入和 Game SDK。

第三阶段已实现可供游戏使用的 SDK。启动当前会话的 App 游戏运行端固定为 Authority Client；大屏公共显示端不属于 `players`，普通多屏 App 主机可同时作为 Player，但其玩家顺序不参与 Authority 判定。开发者工作区创建的项目直接写入统一 `playmesh-library/packages/{gameId}/` 游戏库，平台不提供内置游戏 Demo。

第四阶段网页开发者通道已完成并归档：用户在设置中开启开发者模式后，App 使用独立固定端口（默认 `16666`）启动开发者 Gateway；端口、token 和工作区路径一并持久化，App 重启或重新开启后恢复同一工作区链接。同一局域网内的浏览器与 App 内置 WebView 使用同一工作区。当前链路支持单机/联机项目创建与复制、项目设置和删除、IDEA 风格文件树、编辑保存、文件/文件夹新建与删除、上传、Git 风格双栏 Diff 与差异块应用、快速批量操作、项目级本地历史、结构化项目校验、运行游戏、联机二维码、SSE 同步、统一日志以及 AI 可读 SDK/接口/项目文档；工作区不嵌入主页面预览。完成事实见 `status/phase-04-web-dev-channel.md`。

第五阶段已于 2026-07-17 完成并归档：`playmesh.sync`、自动权威往返延迟、SDK 网页性能层、可配置运行入口、Playmesh 包导入/导出、工作区文件整理、游戏存储收尾、运行重启与最近日志接口、游戏数据清理、正式版移动端界面、扫码加入、资料持久化、Logo 与全平台全屏均已落地。完整代码地图和产品边界见 `status/phase-05-complete.md`，自动验证见 `verification/phase-05-complete-2026-07-17.md`。

第六阶段已于 2026-07-18 完成并归档：加入者无需安装游戏即可加载权威主机入口；全屏成为不阻塞运行的可选能力；Android 外部文件导入、导出和独立 HTML 打开链路完成；Game SDK 与 App Bridge SDK 明确分层；App 身份自动注入，浏览器 ID 与昵称持久化；同 ID 在线冲突拦截、离线成员保留、玩家加入/离开/重连事件和 `session.finish()` 已形成完整重连模型；移动端开发工作区与界面切换性能同步收口。事实归档见 `status/phase-06-complete.md`，验证见 `verification/phase-06-complete-2026-07-18.md`。

## 第一阶段不做

- iOS 发布能力
- 创意工坊
- 云端账号
- 房间自动发现（mDNS、局域网广播等）
- 观看/旁观者模式
- 体感识别
- AI 游戏生成器
- 游戏包签名和审核系统

## 当前开发建议

第一至第六阶段均已完成并归档，第六阶段是最后一个阶段。正式基线仍为 Playmesh `1.6.1+8`、Go Core `0.2.0`、Game SDK `1.4.2`、App Bridge SDK `1.2.1`、Developer API / OpenAPI `1.4.0`、Developer CLI `1.1.0`、Catalog API `1.1.0`。当前开发版本为 Playmesh `2.2.0+21`、Go Core `0.4.0`、Core 协议 `1.2.0`、Game SDK `2.2.2`、App Bridge SDK `2.1.1`、Catalog API `1.4.0`、Relay 协议 `2.0.0`、Developer API / OpenAPI `2.1.0`、Developer CLI `1.3.1`；两套 SDK 已收敛为 Dart 唯一手写源、统一 feature 注册、运行时自动组装和显式多版本兼容发行。所有游戏/分享/Developer 网关、SDK 下载与 AI 声明只能经过同一注册表；游戏 Authority 决定玩法开始和结束条件，SDK 只提交受控会话状态请求。变化统一记录在 `docs/version/2.2.0.md` 与 `docs/version/NEXT.md`。后续不再建立阶段，所有更改必须先按 `06-engineering-standards.md` 的当前版本定义评估受影响组件并按需升级版本号，同时维护 `docs/version/` 详细日志和 App 内简略日志。

建议顺序：

1. 保持游戏库到游戏运行页、屏幕方向和 Windows/移动端 WebView 回归稳定。
2. 保持动态 Core 端口、会话协议、Authority/Player 拓扑和浏览器加入回归稳定。
3. 所有游戏继续从 `playmesh-library/packages/{gameId}/main.json` 自动发现。
4. 任何 SDK、Schema、Manifest、OpenAPI 或 AI 提示词变更仍必须保持同一契约，并按 `docs/04-dev-env.md` 执行回归。

## 当前仓库快照

```text
lib/main.dart                         Playmesh App 入口
lib/features/games/                   游戏库与游戏详情页
lib/features/game/                    全屏游戏页、Launcher 和本地 WebView
assets/playmesh-library/packages/     直接按 `{gameId}/main.json` 存放游戏包
lib/core/game_sdk/features/           Game SDK/App Bridge 的 Dart 唯一手写源、宿主执行器与生成片段
assets/playmesh-library/sdk-src/      构建生成的 TypeScript 中间产物，不直接修改
assets/playmesh-library/public/       平台统一公开资源，包含生成的 JS 与 .d.ts
dev-cli/                              Go Developer CLI
test/widget_test.dart                 首页、导航、启动、刷新、返回和退出测试
docs/status/phase-01-flutter-webview.md  第一阶段事实归档
docs/status/phase-02-go-core.md          第二阶段事实归档
go-core/go.mod                        Go Core 模块已创建，使用 Go 1.26.2
go-core/main.go                       动态端口 HTTP Core 进程入口
go-core/mobile/                       Android gomobile 生命周期入口
go-core/harmony/                      OpenHarmony c-shared C ABI 入口
ohos/                                 OpenHarmony API 12 Flutter/ArkTS/HAR 工程
tool/build_release.ps1                HarmonyOS/Android/Windows 统一发布入口
tool/install_harmony_go.ps1           固定 SIG Go 工具链安装与校验
lib/core/                             Flutter Core 宿主、Client、协议与状态服务
go-core/internal/session/             会话、Player/Authority 拓扑与 WS 路由
go-server/                            游戏源声明、空目录与无密钥公共中转服务器
```

Flutter Counter Demo 和 Go 默认示例均已替换。游戏页面不绕过 Game SDK 直连 Core；大屏公共显示端不伪装成玩家。

## 近期成功标准

- App 启动后看到 Playmesh 首页，而不是 Flutter Counter Demo。
- 首页可以进入用户资料、游戏库和设置页。
- 游戏库进入游戏详情，只有详情页提供“开始游戏”。
- 游戏页默认最大化显示 WebView，主机与 App 扫码加入页共用可拖动、可展开/收纳的悬浮工具坞；扫码加入不显示主机分享入口。
- 游戏工具坞只提供返回，不再提供独立“退出游戏”按钮；刷新游戏会在保留会话的前提下重建 WebView。主机的链接/二维码是工具坞一级入口，普通浏览器由 Game SDK 模拟无 App 导航能力的对应功能区。
- 游戏库右上角可以手动后台扫描；扫描期间继续展示旧缓存，成功后原子替换列表，新增游戏不要求重启 App。App 级缓存保留 revision、刷新时间和搜索索引，为后续分页/搜索提供数据源。
- 游戏必须声明横屏或竖屏；WebView 创建前切换方向，离开后恢复。
- Go Core 使用系统分配端口，设置页展示当前实际服务地址和结构化状态。
- `flutter test` 不再依赖 Counter 文案，改为验证 Playmesh 首页或导航入口。

## 当前产品取舍

- 联机码用于定位会话；浏览器二维码和链接还必须携带当前游戏会话有效的随机 token。关闭分享附加层和刷新游戏都不撤销 token；刷新只重建 WebView 内容，不重置 Core 会话，并保留会话、网关和 token；退出游戏、会话关闭或 Core 重启后失效。
- 分享附加层居中显示并根据视口动态调整宽高；内容超过屏幕时整体可滚动。它列出全部可用局域网地址，用户点选任一地址时二维码必须立即切换到该地址。
- 加入前允许查看房主昵称、游戏名称、最小/最大人数和当前在线人数。
- 不提供房间列表、局域网自动发现和旁观者入口。
- 游戏声明文件是游戏能力的来源，至少描述名称、版本、运行入口、单机/联机模式和人数范围。
- 游戏声明必须使用 `orientation` 明确声明 `landscape` 或 `portrait`，不允许缺失或自动猜测。
- 游戏声明文件使用 `displayModes` 声明唯一显示模式：`single_screen_multiplayer`（大屏模式）或 `multi_screen`（普通模式）。当前不允许同时声明两者。
- 大屏模式下主机使用 `app/index.html` 作为公共显示端与 Authority Client，不属于 `players`；所有玩家使用 `app/controller/index.html`。
- 普通模式下主机、其他 App 设备和普通浏览器都使用 `app/index.html`；创建会话的 App 主机固定为 Authority Client，并可同时作为一个 Player，任何玩家进入顺序都不参与 Authority 判定。
- 游戏运行时公开当前游戏的 `app/`、平台 `public/` 资源和 SDK 上传的 Bucket 文件；分别通过 `/app/...`、`/playmesh/...` 与 `/bucket/{bucket}/{file}` 访问。`data/json`、其他游戏包和 App 私有文件不可通过 URL 读取。
- 游戏持久化目录固定为 `packages/{gameId}/data/`，不生成 `{userId}` 子目录；JSON 位于 `data/json`，上传文件位于 `data/data`，游戏开发者只能通过合法 Bucket API 组织数据。
- 所有 SDK 持久化数据统一写入开始游戏的 Authority 主机；JSON 读写经 Game SDK 的受控连接完成，文件通过 `/bucket/**` 上传和读取，加入设备不能写入自己的游戏库副本。
- FPS 默认显示在游戏页左上角，可在悬浮工具坞关闭。SDK 只统计游戏在实际渲染完成处调用 `playmesh.performance.reportFrame()` 上报的帧；未接入时显示 `-- FPS`。
- 二维码与链接统一放在游戏分享弹窗中，并与“局域网 / 服务器 / 房间状态”同级页签配合展示；局域网和公共中转可以同时承载同一会话的加入。
- App 通过局域网或公共中转加入时都从本地回环入口加载；普通浏览器只能直接使用主机公开的局域网 Authority 地址。
- 局域网分享链接保留 `main.json` 声明的实际 `/app/**` 页面入口，查询参数只包含
  `channelId + shareToken`；公共中转链接只包含
  `tunnelId + fragment inviteToken`，不再公开 Core 端口、联机码或游戏元数据。
- 主游戏网页和控制端网页都可以通过同级可选 `capabilities.json` 声明平台能力；能力 code、中文名、说明和 App/HTML 适配状态由统一能力注册表提供。
- `permissions` 保留给键盘等既有输入声明；传感器以及后续摄像头、麦克风等受保护能力使用 `capabilities.json`。两者都不控制浏览器自身的 DOM 键盘事件或浏览器原生权限。
- 是否允许普通浏览器访问游戏，是游玩期间的会话设置，由用户单独确认，默认不公开。
- 未安装 App 的玩家通过房主分享的局域网地址进入浏览器游戏端或控制端。SDK 在浏览器 `localStorage` 中持久化随机玩家 ID 与昵称，刷新后复用同一身份；分享链接不携带昵称或玩家 ID。
- 公开浏览器页面前必须提示游戏包和不可信网络风险，并使用短期会话凭证。
- 用户昵称可修改；唯一 ID 首次创建时自动生成，之后保持稳定，避免仅依赖昵称识别玩家。
- 头像只保存到本地，MVP 不做云端头像同步。
- 阶段归档只记录功能和代码路径。平台构建只在用户明确要求时执行并写入独立验证记录；安装、真机运行和商店签名不能由静态或包结构检查替代。
- OpenHarmony Public SDK API 12 不提供 HMS `@kit.ScanKit`。鸿蒙包保留手动输入加入码/游戏源的回退，不把扫码列为已适配能力；系统文件分享则由 ArkTS HAR 使用 `ohos.want.action.sendData` 实现。
- 第一阶段不以二维码、联机码、真实 Go 服务、浏览器加入或硬件输入作为验收条件。
