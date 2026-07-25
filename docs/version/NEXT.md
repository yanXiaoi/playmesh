# Playmesh 下一版本临时更新日志

## 状态

- 状态：开发中，尚未发布。
- 当前正式基线：App `1.6.1+8`。
- 当前开发版本：App `2.1.1+20`、Go Core `0.4.0`、Core 协议 `1.2.0`、Game SDK `2.2.1`、App Bridge SDK `2.1.0`、Catalog API `1.4.0`、Relay 协议 `2.0.0`、Developer API / OpenAPI `2.0.1`、Developer CLI `1.3.1`。

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
- Go Core 升级到 `0.4.0`，Core 协议以兼容新增字段升级到 `1.2.0`。游戏侧 Game SDK `2.2.1` 与 App Bridge SDK `2.1.0` 公共 API 未改变，现有游戏包和默认模板不变；AI 提示词仅同步传输透明、统一使用 SDK 的约束。

## 游戏返回导航

- 游戏工具区的返回语义统一为“返回上一页”，退出时只弹出当前游戏路由。
- 从游戏详情启动时返回详情；从开发者工作区发起运行时保留工作区及设置页，
  不再清空导航栈并跳转首页。

## 开发者工作区项目与差异操作

- Developer Gateway 按 system/runtime/projects/files/capabilities/packages/ai/approvals 分组为资源控制器；每个 controller 从自身 `definitions` 自动注册 method/path，核心处理逻辑留在同一资源文件，`developer_web_gateway_io.dart` 只保留生命周期、公共中间件和控制器清单。
- 路由、OpenAPI、完整操作目录、Chat 基础指令和 Agent 指令全部由同一 `DeveloperOperationDefinition` 注册表生成；鉴权、风险、幂等、危险标识和公共响应由中间件注入。删除静态 OpenAPI 副本和旧快速操作协议，Developer API / OpenAPI 破坏性升级到 `2.0.0`。
- “快速操作”替换为上下结构的“对话控制台”，执行一个 JSON 指令对象或数组并返回结构化 HTTP 结果。新增 `file-changes/preview/apply`，支持创建、完整替换、锚点精确替换及前后插入，并按 `baseRevisions` 原子应用。
- 危险接口统一声明 `dangerous=true`。Chat 控制台与 Agent 使用 `X-Playmesh-AI-Channel` 进入审批中间件；SSE 弹窗提供“允许一次 / 此游戏或项目允许 / 始终允许 / 拒绝”，拒绝返回 403，30 秒未决定返回 408。SSE 输出同时改为串行写并消除首个事件订阅竞态。
- 新增高风险 `POST /dev/api/projects/{projectId}/webview/javascript`，通过当前 `GamePage` 注册的移动端 WebView / Windows WebView2 求值入口执行任意 JavaScript 并返回结果。工作区新增复用 CodeMirror 的 WebView JS 操作台、结构化返回区和按项目隔离的最近 30 次本地历史；Chat/Agent 调用统一进入危险审批。
- 所有非静态 Developer API 响应增加 `X-Playmesh-Operation-ID`；回归测试强制完整操作目录与 OpenAPI 路由一致，并禁止 `developer_web_gateway_io.dart` 手写 `/dev/api/**` 旁路。
- Android 开启开发者模式时启动 `specialUse` Foreground Service，持有当前 FlutterEngine、CPU WakeLock 与高性能 Wi-Fi Lock；切换后台或锁屏后文件、校验、日志、状态等 Developer API 继续服务，关闭开发者模式时同步释放服务和锁。
- Developer 操作定义新增 `requiresForegroundView` 元数据并同步到操作目录与 OpenAPI。启动/重启游戏、执行 WebView JavaScript 和运行平台能力自检在 App 后台、锁屏、熄屏或窗口失焦时返回 `409 app_view_unavailable`，错误详情包含准确的 Activity、窗口、屏幕和锁屏状态；停止运行仍可在后台执行。
- 移动端顶部恢复可用的项目入口，并收敛为“项目 / 运行 / 保存 / AI / 更多”紧凑工具栏；项目选择至少保留 `120px`，其他按钮使用明确的最小宽度。一行不足时项目选择独占第一行，四个操作按钮均分第二行，不再压缩入口。
- 项目入口和“更多”改为 IDEA 风格锚点下拉菜单；新建、复制当前项目、项目设置和删除项目集中在项目菜单。复制时可填写新的项目 ID 和名称，并排除运行数据、缓存及本地历史。
- 文件 Diff 和本地历史继续使用 CodeMirror MergeView 左右双栏；AI 批量文件修改统一由 `file-changes/preview/apply` 结构化接口预览并原子应用。
- 新增项目复制和删除的 Developer API；本轮统一操作注册表最终将 Developer API / OpenAPI 升级到 `2.0.0`。

## 游戏源声明 1.4.0

- 新增 `/apps/info`，可声明名称、作者、主页和公共中转能力；名称缺失时显示 `host:port`，默认 HTTP/HTTPS 端口省略。
- 中转声明新增由 Go Server 配置的 `publicBaseUrl`。App 使用该公共 Origin 建立 Host/Client Upgrade 并生成二维码，不再从游戏源 Host 推导；HTTP/HTTPS 与对外域名由服务器部署配置决定，协议本身直接决定是否使用外层 TLS，不设置冗余策略字段。
- 中转声明新增 `maxConnectionsPerTunnel`，由 Go Server 返回当前单隧道容量；
  App 只把它作为动态池上限，最终限流仍由服务器执行。
- App 自带游戏库分享服务器固定返回“`{用户昵称}的游戏库`”，不返回作者、主页或 Relay 声明，且永远不支持联机中转。

## 游戏库兼容与最近打开

- 旧游戏缺少 `author` 时显示“佚名”，缺少 `lastModifiedAt` 时显示“无”，不再导致整库扫描失败。
- 其他清单或入口错误只要 `main.json` 能解析出非空 `id`，就以“待修复”条目进入游戏库和开发者工作区；无法识别 ID 的目录只记录诊断并跳过。
- “最近打开时间”只存于包外 `playmesh-library/cache/app/game-library.json`，每个 ID 覆盖单个时间戳；删除游戏同步删除记录，最多保留 2048 条并淘汰最旧记录。
- 游戏库默认按最近打开时间倒序，未打开游戏排在最后并按名称稳定排序。

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
- 游戏详情以紧凑信息卡展示作者、最后上传、游戏/SDK 版本、人数、模式、主画面方向、控制器方向和运行入口。

## 角色化能力声明

- `capabilities.json.required` 只属于主画面；单屏多人新增 `controllerRequired`，只属于控制器。
- 开发者网页和 CLI 创建项目时分别选择两组能力；非单屏多人声明控制器能力会校验失败。
- 本地 WebView 与 App Bridge SDK 只返回当前页面角色的能力集合；`/api/app-capabilities` 已删除，能力确认和插件实例创建不会越权到另一角色。
- 单屏多人页面角色统一驱动入口、方向和能力选择；权威显示端的空 `required` 是最终结果，不会回退到非空 `controllerRequired`。
- App WebView 的 Game SDK 只以 App Bridge `getDeclared()` 返回的当前页面声明决定是否弹能力确认。

## Agent / CLI 发布历史

- `POST /dev/api/packages/import` 改为复用 Developer Project Catalog 的发布事务，不再直接绕过本地历史。
- 同 ID 发布记录整包 before/after 快照；恢复整个工作区时同时恢复 `main.json`、`capabilities.json` 与 `app/`，继续保留 `data/` 和 `cache/`。
- 新增回归测试覆盖上传时作者/时间覆盖、发布历史生成与整包恢复。

## 契约与资料

- Manifest、能力 Schema、OpenAPI、默认模板、开发者工作区、CLI、AI 提示词、SDK 声明与游戏开发文档均同步到当前字段。
- AI 游戏提示词遵守最小披露原则，只提供可调用的公开 SDK 和任务必需约束，不暴露回环代理、中转鉴权、密钥协商或加密通道实现。
- Game SDK 升级到 `2.2.1`，App Bridge SDK 保持 `2.1.0`，Developer API 当前为 `2.0.1`，CLI 当前为 `1.3.1`。
- Go Core 升级到 `0.4.0`，Core 协议升级到 `1.2.0`；Player 在线状态增加来源与延迟字段，用于统一房间状态展示，现有游戏侧 SDK 公共 API 保持不变。

## 验证与构建

- 使用固定 SDK 在沙箱外串行执行 Dart/Flutter 静态分析、定向测试、全量测试、SDK JavaScript 契约与 CLI Go 测试。
- 删除绑定特定版本号、构建号和发行文案的设置页日志测试，避免正常版本升级触发无意义回归；设置页其他行为测试继续保留。
- Android 与 Windows 已按用户要求通过统一发布脚本在沙箱外串行构建，产物、签名类型、包结构和 SHA-256 记录在 `docs/verification/playmesh-2.0.0-remote-relay-2026-07-24.md`。
- 声明入口邀请修正后的代码级回归记录在
  `docs/verification/playmesh-2.0.0-declared-entry-invitation-2026-07-24.md`；
  现有 `2.0.0+18` 安装包早于该修正，尚未重新构建。
- Server Info 容量声明与动态中转池回归记录在
  `docs/verification/playmesh-2.0.0-dynamic-relay-pool-2026-07-24.md`。
- Android 后台开发者工作区的 Foreground Service、View 可用性错误契约、
  全量 Flutter 回归和 debug APK 编译记录在
  `docs/verification/playmesh-2.1.1-android-background-developer-gateway-2026-07-25.md`。
