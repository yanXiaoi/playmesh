# Playmesh 下一版本临时更新日志

## 状态

- 状态：开发中，尚未发布。
- 上一份历史详细日志：`docs/version/2.2.0.md`；它不代表当前工作树版本。
- 当前开发版本：App `3.0.0+22`、Go Core `0.5.0`、Core 协议 `1.3.0`、Game SDK `2.4.0`、App Bridge SDK `2.2.0`、Catalog API `2.0.0`、Relay 协议 `2.0.0`、Developer API / OpenAPI `2.3.0`、Developer CLI `1.4.0`。

## 3.0.0 破坏边界

- 游戏源配置升级为只接受 HTTP/HTTPS `publicURL`，本地源配置、声明缓存、游戏库使用
  统计与在线偏好均使用新格式；旧格式不兼容读取，用户需要重新添加源。
- Catalog 只返回每个 `gameId` 当前最新公开版本，下载必须显式携带版本；App 以
  `gameId + publisher` 聚合跨源结果，并按语义版本提供更新与来源选择。
- 用户资料从文字头像升级为本机图片头像。稳定 `userId` 与头像生命周期由平台管理，
  会话只传播只读头像路径，游戏不能写入平台保留的 `_sys-*` Bucket。
- Go Server 使用全新的用户、凭证、版本化游戏与审核 schema；旧 SQLite 数据库必须
  先备份并换用全新数据库，不执行自动 `ALTER` 或兼容迁移。

## 局域网与公共中转双链路

- 游戏分享弹窗统一为“局域网 / 服务器 / 房间状态”三个同级页签，默认显示局域网地址；局域网和服务器可以同时接收加入，不改变同一 Core 会话。
- “服务器”复用在线游戏库中已启用的源，异步请求 `/apps/info`、筛选中转声明、展示最新探测延迟，并提供搜索、每页 5 项分页、连接、断开和重试状态。
- Go Server 首期只提供手写声明、空游戏目录和临时 TCP 隧道，不提供登录、后台、游戏管理或通用代理；Source Token 由全局 Gin 中间件和可配置白名单处理。
- 公共中转的主机与客户端都不需要公网 IP。Go Server 只配对 Host/Client Upgrade 并复制密文字节，不接收目标 Host、端口或 URL。
- 主机连接池改为动态热池，上限读取
  `/apps/info.relay.maxConnectionsPerTunnel`；空闲时最多预热 4 条连接，被配对后
  立即补回，活跃连接结束后自然收缩，不再固定占用 16 条连接。
- 局域网邀请保留 `main.json` 当前模式声明的实际 `/app/**` 游戏或控制器入口，
  查询参数缩短为 `channelId + token`；普通浏览器直接打开，App 解析同一链接后
  在本地回环 Origin 下加载，并建立绑定当前分享 Token 的受控 Core Upgrade。
- 公共中转邀请缩短为
  `https://relay.example/j/{tunnelId}#inviteToken={opaqueToken}`；fragment 只由 App
  解析，不会发送给 Go Server。真实 `/app/**` 入口和 `channelId` 也封装在令牌
  内，由 App 在回环 Origin 下恢复；`/j/**` 不参与页面资源映射。旧的 Core
  端口、联机码、游戏 ID、名称、方向和 Relay 连接参数全部退出分享 URL。该
  破坏性邀请变更将 Relay 协议升级到 `2.0.0`。

## 端点持钥透明加密

- 主机 App 本地生成 256 位随机端点密钥；密钥只进入邀请 URL fragment，不进入中转的创建隧道、Upgrade、响应、运行状态或日志。
- 每条 TCP 连接建立一次持续的透明加密流，使用随机 Salt、HKDF-SHA256 双向派生和 AES-256-GCM 记录层；HTTP、静态资源、Range 与 WebSocket 均作为原始字节自动传输，不需要业务消息逐条调用加解密。
- Go Server 没有端点密钥，密码学上无法解密游戏路径、SDK 消息、玩家昵称或内容；外层 TLS 可选。
- 局域网 App 链路继续透明直传且不增加加密。
- 局域网 HTML 继续直接加载 Authority 短链接，不依赖 App SDK、回环网关或
  公共中转；页面由 Authority 按 `channelId` 选择并注入当前运行上下文。

## 本地回环 Origin 与 Authority 收敛

- App 通过局域网或服务器加入时都先建立 `127.0.0.1` 本地网关，再由 WebView 从稳定本地 Origin 加载；普通局域网浏览器继续直连主机 Authority 地址。
- 游戏分享 Authority 只提供 `/app/**`、`/bucket/**`、`/playmesh/**`，以及 SDK 无法替代的受控底层连接能力（例如当前游戏 WebSocket Upgrade）。
- 加入、昵称、存储和能力优先由 Game SDK、App Bridge SDK 与 Session WebSocket 实现，删除旧 `/api/join`、`/api/storage`、`/api/player/nickname`、`/api/app-capabilities` 和通用 Core HTTP 代理。
- 权威 `playmesh.js` 始终由主机提供；加入方 App 本地只提供 `playmesh-app.js`，用于本机 ID、昵称和能力。

## 统一房间状态

- Go Core 玩家快照新增来源和延迟，并区分“服务器 / 局域网 App / 局域网 HTML”；断线玩家保留在当前房间状态中，延迟清空，重连后按 `playerId` 更新。
- 房间状态独立于具体分享通道，实时显示全部已加入玩家、在线状态和 RTT。
- Go Core 当前为 `0.5.0`，Core 协议为 `1.3.0`。Player 快照兼容新增只读
  `avatar`；Game SDK `2.4.0` 继续公开该字段，App Bridge SDK 当前为 `2.2.0`。
  现有游戏包继续由兼容发行范围承接。

## 游戏返回导航

- 游戏工具区的返回语义统一为“返回上一页”，退出时只弹出当前游戏路由。
- 从游戏详情启动时返回详情；从开发者工作区发起运行时保留工作区及设置页，
  不再清空导航栈并跳转首页。
- App 与浏览器 SDK 的游戏工具统一把“运行日志”提升为一级按钮；“显示性能信息”
  移入“更多”，二级菜单不再提供设置。浏览器昵称编辑移动到游戏信息弹窗。

## 首页与设置入口

- 首页恢复大简介卡和柔和几何背景；用户资料只通过简介卡进入，右上角提供扫码加入和
  设置。
- 简介卡下方的“游戏库－最近游戏”既是游戏库入口也是快速启动栏：优先最近启动，
  不足时按库顺序补位，最多三项，点击条目直接进入游戏。其后只保留“加入对局 /
  在线游戏库”两个主入口。
- 快速启动项显示发布者、版本、联机/单机、单屏多人/多屏多人和横屏/竖屏；完整游戏库
  保留上述信息与简介，并以左侧大图标重新排版。
- 在线游戏库右上角新增扫码添加游戏源；游戏源管理也保留在该处和设置页，添加页移除
  publicURL 与 `/apps/info` 提示。设置页将软件/构建版本置顶，并将入口统一命名为
  “游戏源管理”、副标题精简为“管理你的游戏源”。开发者工作区地址选中态改用
  当前主题的 `secondaryContainer/onSecondaryContainer`，夜间模式保持可读。
- 修复 App 根快捷键表覆盖 Flutter 默认键盘契约的问题。Windows 首页现在以资料卡为
  初始焦点，方向键/Tab 可遍历，Enter/Space 可激活；Android TV 与桌面端共用同一
  焦点策略，不再依赖平台偶然兜底。

## 开发者工作区项目与差异操作

- Developer Gateway 按 system/runtime/projects/files/capabilities/packages/ai/approvals 分组为资源控制器；每个 controller 从自身 `definitions` 自动注册 method/path，核心处理逻辑留在同一资源文件，`developer_web_gateway_io.dart` 只保留生命周期、公共中间件和控制器清单。
- 路由、OpenAPI、完整操作目录、Chat 基础指令和 Agent 指令全部由同一 `DeveloperOperationDefinition` 注册表生成；鉴权、风险、幂等、危险标识和公共响应由中间件注入。删除静态 OpenAPI 副本和旧快速操作协议后，本轮再兼容新增多源发布和定义驱动的能力交互测试 Operation，Developer API / OpenAPI 当前为 `2.3.0`。
- “快速操作”替换为上下结构的“对话控制台”，执行一个 JSON 指令对象或数组并返回结构化 HTTP 结果。新增 `file-changes/preview/apply`，支持创建、完整替换、锚点精确替换及前后插入，并按 `baseRevisions` 原子应用。
- 危险接口统一声明 `dangerous=true`。Chat 控制台与 Agent 使用 `X-Playmesh-AI-Channel` 进入审批中间件；SSE 弹窗提供“允许一次 / 此游戏或项目允许 / 始终允许 / 拒绝”，拒绝返回 403，30 秒未决定返回 408。SSE 输出同时改为串行写并消除首个事件订阅竞态。
- 新增高风险 `POST /dev/api/projects/{projectId}/webview/javascript`，通过当前 `GamePage` 注册的移动端 WebView / Windows WebView2 求值入口执行任意 JavaScript 并返回结果。工作区新增复用 CodeMirror 的 WebView JS 操作台、结构化返回区和按项目隔离的最近 30 次本地历史；Chat/Agent 调用统一进入危险审批。
- 所有非静态 Developer API 响应增加 `X-Playmesh-Operation-ID`；回归测试强制完整操作目录与 OpenAPI 路由一致，并禁止 `developer_web_gateway_io.dart` 手写 `/dev/api/**` 旁路。
- Android 开启开发者模式时启动 `specialUse` Foreground Service，持有当前 FlutterEngine、CPU WakeLock 与高性能 Wi-Fi Lock；切换后台或锁屏后文件、校验、日志、状态等 Developer API 继续服务，关闭开发者模式时同步释放服务和锁。
- Developer 操作定义新增 `requiresForegroundView` 元数据并同步到操作目录与 OpenAPI。启动/重启游戏、执行 WebView JavaScript 和运行平台能力自检在 App 后台、锁屏、熄屏或窗口失焦时返回 `409 app_view_unavailable`，错误详情包含准确的 Activity、窗口、屏幕和锁屏状态；停止运行仍可在后台执行。
- 移动端顶部恢复可用的项目入口，并收敛为“项目 / 运行 / 保存 / AI / 更多”紧凑工具栏；发布操作移入手机端“更多”，不再因第六项进入固定高度之外而错位。
- Developer Workspace 固定使用同一套深色编辑器配色，不随 App 日间/夜间模式改变；
  主题选择仍写入 App 统一偏好。项目、展开/收起目录、代码文件、图片、压缩包、
  `main.json` 和普通资源使用不同的本地内联 SVG 图标与语义色；AI 是工具栏唯一的
  强强调操作。
- 工作区图标改由 `workspace-icons.js` 直接生成内联 SVG，移除外部 SVG sprite 引用，
  修复 WebView 控制台重复输出 `Resource load failed: [object SVGAnimatedString]`。
- 项目入口和“更多”改为 IDEA 风格锚点下拉菜单；新建、复制当前项目、项目设置和删除项目集中在项目菜单。复制时可填写新的项目 ID 和名称，并排除运行数据、缓存及本地历史。
- 文件 Diff 和本地历史继续使用 CodeMirror MergeView 左右双栏；AI 批量文件修改统一由 `file-changes/preview/apply` 结构化接口预览并原子应用。
- 新增项目复制、删除、多源发布和能力测试实例的 Developer API；统一操作注册表当前为 `2.3.0`。

## App 统一国际化与 Web UI 联动

- 内置 Developer Workspace 属于 App 界面；Flutter 页面、工作区 HTML/JS 和平台
  注入游戏 WebView 的能力确认、工具栏、昵称、信息与日志层，显示文案统一来自当前
  locale 的 `app.json`。
- 工作区不再消费独立 `developer.json` 或 JavaScript 内置中英字典。Developer
  Gateway/宿主只暴露已经应用 fallback 的只读 `locale + workspace.* messages`
  投影，App 语言切换时推送到已打开工作区，并更新 `document.lang`、现有 DOM 和
  后续动态渲染。
- 平台游戏 UI 只消费 `platform.game.*` 投影：App WebView 使用私有
  `_playmeshPlatformUi` bootstrap，普通浏览器由分享网关注入全部启用语言的受限
  投影，再由 SDK 按 `navigator` 语言选择；临时配置在 SDK 消费后删除。后续切换通过私有
  `platform.ui.configure` 更新 Shadow DOM。配置同时携带宿主有效主题：App WebView
  跟随当前显示 App，普通浏览器跟随系统；能力确认、工具/昵称/信息/日志与性能浮层
  不保存独立主题偏好。
- 私有国际化桥接不改变游戏内容、公开 `playmesh.ready`、机器错误 code 或
  API JSON。独立部署的 Go Server 继续使用自己的 `go-server.json`。
- Game SDK 新增同步只读 `playmesh.runtime.getLocale(): string`。App WebView 返回
  当前显示/加入方 App locale，绝不继承 Authority 主机语言；普通浏览器按
  `navigator.languages`、`navigator.language` 直接读取第一个合法系统 locale，
  失败回退 `zh`，且不受平台覆盖层支持语言限制。该 API 不返回 App messages，
  游戏业务翻译仍由游戏开发者维护。

## SDK 单一 Dart 源

- Game SDK 与 App Bridge SDK 参考 Developer Gateway 的 operation 注册方式，改为
  `lib/core/game_sdk/features/` 下按功能组织；网页端 TypeScript 片段与对应 Dart
  宿主执行器保存在同一 feature 文件，并只在 `sdk_feature_registry.dart` 注册一次。
- 正式构建从 Dart 注册表自动组装 `sdk-src/*.ts`、公开 `.js/.d.ts` 和版本/契约产物；
  生成器同时比较网页端实际发出的命令与 Dart 执行器集合，不一致时立即失败。
- Game SDK 通过 `__PLAYMESH_APP_SDK_VERSION__` 引用同批 App SDK 版本；即时注册表和
  正式生成器同时注入 `.ts/.js/.d.ts`，删除浏览器空宿主的固定 `*-empty` 伪版本。
- App 开发运行时、游戏/分享/Developer Gateway、SDK 下载与 AI 声明不再读取
  打包静态 SDK，而是直接从当前 Dart 注册表即时组装；日常修改后只需重新运行，
  正式打包脚本会自动刷新静态产物，无需手动执行生成命令。
- 新增单一源架构断言，扫描并禁止 `rootBundle`、文件系统和旧生成版本常量旁路，
  同时逐个验证所有 SDK 网关/API 响应与注册表即时组装内容一致。
- 注册表新增不可重叠的 Game/App SDK 兼容发行范围；游戏清单版本在网关启动时解析，
  SDK Bridge 命令携带实际 bundle 版本并再次校验。当前 Game SDK 明确承接
  `1.0.0-2.4.0`，App SDK 明确承接 `1.0.0-2.2.0`，未知版本仍直接拒绝。
- 每个 Dart 命令执行器通过 `supportedVersions` 自行声明支持范围；调用契约未变化时
  使用 `SdkVersionRange.last` 开放上界，后续 SDK 升级无需逐个修改。相同命令名允许
  存在多个不重叠版本实现，但注册器和生成器都会拒绝同一版本命中两个执行器。只有
  参数、消息、返回值、事件或错误语义不兼容时，才封口旧范围并在 v3 等目录注册新实现。
- 本地 App SDK 服务删除测试脚本注入参数，所有版本响应都必须经过同一注册表；
  未注册或格式错误的版本请求直接失败。
- Game SDK 新增 `Player.avatar`、只读 `runtime.getLocale()`，并把 App 级分享、
  游戏工具和退出能力统一声明在 `playmesh.app`，升级到 `2.4.0`。
- App Bridge SDK 新增 `openSharePanel()`、`showToolDock()`、`hideToolDock()` 和
  `exitGame()`，升级到 `2.2.0`。SDK 拉起工具时自动聚焦，任一实际工具操作后整组
  自动隐藏；用户手动展开时操作后只收起为悬浮按钮。现有已注册游戏包继续按清单
  版本运行，旧 `playmesh.authority.openSharePanel()` 不再保留。

## 游戏源声明与 Catalog API 2.0.0

- `/apps/info` 使用 Catalog `2.0.0` 声明源名称、主页、公共中转和用户上传能力；
  App 添加源时必须先校验声明，失败的地址不落盘。
- 单个 `publicURL` 同时承载 Origin 与可选正式 Catalog Token；分享、扫码、粘贴和手动
  输入均使用该链接，不再支持 `playmesh://catalog-source` 配置协议。
- 搜索响应只允许每个 `gameId` 一个 latest offer，并提供同源图标 URL；版本化下载
  以 `gameId + version` 精确寻址，不允许源静默替换内容。
- App 自带游戏库分享服务器固定返回“`{用户昵称}的游戏库`”，并明确声明
  `supportsGameRelay=false`、`userUpload.supported=false`；不提供主页或写入能力，
  且永远不支持联机中转和用户上传。这个 `name` 与用户自定义源名一样属于 Catalog
  API 动态数据，消费端逐字显示，不能把它作为国际化键。

## 游戏库兼容与最近打开

- 旧游戏缺少 `author` 时在数据层保留空动态值，App 固定外壳显示当前语言的“未知发布者”；非空发布者、游戏名、源名和其他 API 值始终原样显示。缺少 `lastModifiedAt` 时由 App 外壳显示本地化“无”，两者都不再导致整库扫描失败。
- 其他清单或入口错误只要 `main.json` 能解析出非空 `id`，就以“待修复”条目进入游戏库和开发者工作区；无法识别 ID 的目录只记录诊断并跳过。
- 使用统计 v2 只存于包外 `playmesh-library/cache/app/game-library.json`，每个 ID 保存 `lastOpenedAt + launchCount`；每次成功启动原子递增，删除游戏同步删除记录，最多保留 2048 条并按最旧、最低启动数顺序淘汰。
- 游戏库默认按启动次数倒序、最近打开时间倒序、语义版本倒序、名称和 gameId 稳定排序；在线热度聚合使用同一统计。

## 损坏项目自救与临时文件

- Developer Gateway 项目包下载和 `playmesh-cli get` 不执行 Manifest、能力、入口或运行语义校验；缺少 `app/` 的残缺项目仍可下载已有内容。
- 运行、`push/dev` 和正式导入继续执行完整校验。
- App 分享导出、在线库导入导出和 Developer Gateway 包传输改用固定临时 ZIP；每次操作前覆盖旧文件、完成后清理，并串行化共享中转文件。

## 单屏多人方向与全屏

- `main.json` 新增 `controllerOrientation`；单屏多人必填，其他模式禁止声明。
- 主画面使用 `orientation`，控制器使用 `controllerOrientation`。本地 App WebView、远程 App WebView、普通浏览器分享入口均按当前页面角色选择方向。
- Game SDK 在 App 中调用 `playmesh.app.device.setFullscreen(true, orientation)`，原生宿主进入全屏并应用横竖屏；退出时解除方向限制。
- 普通浏览器不再显示全屏提示层，SDK 会直接尽力请求 Fullscreen API，再调用 Screen Orientation API；用户激活、浏览器策略或平台不支持导致的失败不阻断 SDK 初始化和加入对局，悬浮工具栏保留全屏按钮供用户手势重试。

## 发布元数据与详情

- `main.json` 新增只读 `author` 与 `lastModifiedAt`。网页、Agent 和 CLI 上传时分别使用当前 App 设置昵称与 Unix 毫秒时间戳覆盖包内值。
- 普通项目设置不能修改 `id`、`author` 或 `lastModifiedAt`；最后上传时间在 App 游戏详情和开发者工作区按设备本地时区显示。
- 游戏详情移除与其他状态重复的 Game SDK 和运行入口卡片；最后上传与最近打开统一使用
  `yyyy-MM-dd HH:mm:ss` 本地时间格式，并保持单行按可用空间缩小字体。

## 浏览器扫码工具

- 普通浏览器扫码加入页在当前页面本地拦截 `console.log/info/warn/error/debug`、资源错误、
  未捕获异常和 Promise rejection；最近 500 条可从悬浮菜单“运行日志”查看和清空，
  不上传到 App、Developer Gateway、Core 或中转服务，刷新页面后清空。
- 普通浏览器的游戏悬浮工具支持指针和触摸拖动，并限制在当前视口内；拖动不会误触
  工具按钮。App WebView 继续使用宿主工具，不启用该浏览器本地实现。

## 角色化能力声明

- `capabilities.json.required` 只属于主画面；单屏多人新增 `controllerRequired`，只属于控制器。
- 开发者网页和 CLI 创建项目时分别选择两组能力；非单屏多人声明控制器能力会校验失败。
- 本地 WebView 与 App Bridge SDK 只返回当前页面角色的能力集合；`/api/app-capabilities` 已删除，能力确认和插件实例创建不会越权到另一角色。
- 单屏多人页面角色统一驱动入口、方向和能力选择；权威显示端的空 `required` 是最终结果，不会回退到非空 `controllerRequired`。
- App WebView 的 Game SDK 只以 App Bridge `getDeclared()` 返回的当前页面声明决定是否弹能力确认。

## Agent / CLI 发布历史

- `POST /dev/api/packages/import` 改为复用 Developer Project Catalog 的发布事务，不再直接绕过本地历史。
- 同 ID 发布记录整包 before/after 快照；恢复整个工作区时同时恢复 `main.json`、可选
  根 `icon.png`、`capabilities.json` 与 `app/`，继续保留 `data/` 和 `cache/`。
- 新增回归测试覆盖上传时作者/时间覆盖、发布历史生成与整包恢复。

## Go Server 游戏包平台

- Go Server 将公开门户、匿名上传/浏览/已审核下载、Catalog 与 Relay 统一迁移到
  App 外部端口；管理监听只保留安全路径下的页面、登录和后台 API。
- 正式 Token 只返回已通过游戏，待审核 Token 只返回待审核游戏并追加临时标签；
  公开门户可以展示待审核元数据，但前端不提供链接且后端下载接口强制阻断。
- SQLite schema `3` 包含用户、邮箱验证、用户 Session、上传密钥、游戏归属、版本化
  游戏、审核事件与发布状态；现有非 schema 3 数据库拒绝启动。
- 用户上传要求登录或独立上传密钥，同一 `gameId` 永久绑定首个账号；新版本必须严格
  高于当前最高版本，并执行 ZIP 路径、大小、压缩比、扩展名、Manifest、ClamAV 与
  活动内容正则检查。危险原包删除，检测结果继续留存。
- `server.json` 改由已鉴权后台结构化管理并原子保存；内容规则与 ClamAV 设置可热
  更新，端口、数据库、限流与 Relay 等运行级参数安全重启后生效。正则规则包含
  ID、说明、表达式、适用扩展名与启用状态，无需修改 Go 源码即可扩展。
- 管理登录验证码改用开源图像组件：数字计算由 `base64Captcha` 生成，文字点选由
  `go-captcha/v2` 生成主图、提示图并在后端校验坐标；不再向前端返回可直接计算的
  结构化题目或目标数据。
- 后台统一修复 checkbox/radio 的尺寸和标签布局，并明确暴露 `publicBaseUrl`。
  公开门户与用户中心显示可直接导入 App 的 HTTP/HTTPS `publicURL` 与二维码。
- 用户首页新增当前访问地址、配置公开地址与正式加入 Token 的展示和复制入口，无法
  扫码时可直接在 App 中手动添加；待审核 Token 仍不会公开。
- 管理员密码、App 双 Token 与管理安全路径取消长度限制，继续要求非空、双 Token
  不同以及管理路径满足安全字符和保留路径规则。
- 管理页面入口新增仅由 `.env` 提供的 `PLAYMESH_ADMIN_PATH`；公开门户移除后台
  跳转，后台脚本、验证码、登录和全部管理员 API 一并挂入安全路径，不再暴露固定
  `/api/auth`、`/api/admin` 或后台静态资源旁路；管理员 Session 鉴权保持不变。
- 深度安全审计收紧下载/删除的存储根目录与符号链接校验，ZIP 大小运算、条目上限、
  大小写冲突、Windows 设备名、符号链接和特殊文件检查，并以目录范围文件 API
  原子持久化；App API/Relay 增加鉴权前限流，ClamAV 扫描增加可配置并发上限。
- Go Server 固定 Go `1.26.5` 安全工具链并升级 `x/crypto`、`x/image`、`x/net`、
  `x/text`；`govulncheck` 结果为可达漏洞 0、导入包漏洞 0，`gosec` 为问题 0。
- `.env` 只保存管理员凭证、正式/待审核 Token 与可选 SMTP 密钥。
- `.env` 新增默认开启的 `PLAYMESH_CLAMAV_ENABLED`；受控环境可显式关闭病毒签名
  扫描，但 ZIP 边界、类型、Manifest 与内容正则检查始终保留。
- 修复正常导出包中的 `app/static/js/**` 相对模块引用被 `parent-path` 内容规则误报
  的问题；ZIP 条目路径穿越继续由归档边界强制阻断，旧默认规则启动时自动迁移移除。
- 公开门户和管理后台补齐手机响应式布局、触摸尺寸、安全区和防输入缩放；后台审核
  表格在窄屏转换为字段化卡片，并补充局域网 IP、`publicBaseUrl` 与管理网络配置说明。
- 修复后台更新 `publicBaseUrl` 后 `/apps/info` 仍返回进程启动值的问题；该字段现在
  并发安全地热更新并禁止缓存，App 下一次游戏源探测即可读取新中转地址。
- 修复公开上传完成后继续访问已失效事件 `currentTarget`，导致浏览器抛出
  `Cannot read properties of null (reading 'reset')` 的问题；表单引用现在会在异步
  请求前固定保存。

## 契约与资料

- Manifest、能力 Schema、OpenAPI、默认模板、开发者工作区、CLI、AI 提示词、SDK 声明与游戏开发文档均同步到当前字段。
- `main.json` 整体移除 `permissions` 与 `icon`；能力只由同级
  `capabilities.json` 声明，列表图标只认包根 `icon.png`。输入中出现的同名键和
  其他未知键一样按普通多余字段静默忽略；工作区保存、CLI SDK 版本重写、导入和
  导出规范化均不输出这些键。
- AI 游戏提示词遵守最小披露原则，只提供可调用的公开 SDK 和任务必需约束，不暴露回环代理、中转鉴权、密钥协商或加密通道实现。
- Game SDK 升级到 `2.4.0`，App Bridge SDK 升级到 `2.2.0`，Developer API / OpenAPI
  升级到 `2.3.0`；CLI 因 `icon.png` 包契约升级到 `1.4.0`。
- Go Core 升级到 `0.5.0`，Core 协议升级到 `1.3.0`；Player 增加只读头像路径，
  在线状态继续包含来源与延迟字段。

## 验证与构建

- 使用固定 SDK 在沙箱外串行执行 Dart/Flutter 静态分析、定向测试、全量测试、SDK JavaScript 契约与 CLI Go 测试。
- App `3.0.0+22` 已完成 265 项 Flutter 回归、Flutter analyze、三套 Go
  `test/race/vet`、全部 SDK/本地化 Node 契约、浏览器中英文/主题/管理入口联调，以及
  Android/Windows 统一发布构建。产物 SHA-256、内部 Android 签名边界和完整结果记录在
  `docs/verification/playmesh-3.0.0-2026-07-26.md`。
- 删除绑定特定版本号、构建号和发行文案的设置页日志测试，避免正常版本升级触发无意义回归；设置页其他行为测试继续保留。
- 历史 App `2.2.0+21` 的 SDK 注册表、175 项 Flutter 回归、5 组 Node SDK 契约、Go 测试、
  Android/Windows 构建、签名、架构、包内 SDK 版本和 SHA-256 记录在
  `docs/verification/playmesh-2.2.0-sdk-registry-build-2026-07-25.md`。
- App `2.0.0+18` 的 Android 与 Windows 历史产物记录在
  `docs/verification/playmesh-2.0.0-remote-relay-2026-07-24.md`。
- 声明入口邀请修正后的代码级回归记录在
  `docs/verification/playmesh-2.0.0-declared-entry-invitation-2026-07-24.md`；
  现有 `2.0.0+18` 安装包早于该修正，尚未重新构建。
- Server Info 容量声明与动态中转池回归记录在
  `docs/verification/playmesh-2.0.0-dynamic-relay-pool-2026-07-24.md`。
- Android 后台开发者工作区的 Foreground Service、View 可用性错误契约、
  全量 Flutter 回归和 debug APK 编译记录在
  `docs/verification/playmesh-2.1.1-android-background-developer-gateway-2026-07-25.md`。
