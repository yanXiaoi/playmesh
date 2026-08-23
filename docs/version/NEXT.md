# Playmesh 下一版本临时更新日志

## 状态

- 状态：App `4.3.1+31` 已于 2026-08-23 完成正式构建；当前没有新的未发布变更。
- 当前发行基线：App `4.3.1+31`、Runtime `1.0.2+5`、Go Core `0.5.0`、Core 协议 `1.3.0`、
  Game SDK `4.1.0`、App Bridge SDK `3.3.0`、Catalog API `3.0.0`、
  Relay 协议 `3.0.0`、Developer API / OpenAPI `5.0.0`、Developer CLI `2.0.0`。
- 最新正式发布日志：`docs/version/4.3.1.md`；本文件保留 4.3.1、4.3.0、4.2.1、4.2.0、4.1.0 与 4.0.0
  发布归档。
- Game SDK `4.1.0` 为 `game.submitAction` 与 `authority.onService` 兼容新增
  隔离 namespace 路由，旧调用仍使用原线格式和稳定默认路由；GDevelop 官方 Multiplayer
  行为在 Playmesh 内改用命名空间 Authority 服务与 Binary relay，不存在 Playmesh SDK 时
  保留官方运行层。Go Core 与 Core 协议版本不变。
- JSON Bucket 存储传输执行破坏性替换：保留既有异步
  `getData/setData/removeData/clearData/upload` 的签名与 Promise 语义，只新增精确的
  `getDataSync/setDataSync`；异步与同步 JSON 统一改走同源 HTTP GET/PUT/DELETE、
  SHA-256、requestId 幂等和 revision/CAS，binary upload 继续独立使用 POST 与
  `data/data`。SDK、App host、GameRuntimeBridge 与 Go Core 主 Session 链中的旧 WS 存储
  请求/响应、pending/settle、双读、双写和 fallback 全部删除。正式项目清单使用升级完成的
  Game SDK `4.1.0`；其公共异步 API 签名与 Promise 语义保持兼容。

## 未发布变更

- 当前没有新的未发布变更。

## 4.3.1 发布归档

- 修复 `media.microphone@1.1.0` 把系统语音引擎初始化失败统一误报为授权问题。Android
  与 Windows 的主 App、Runtime 均增加失败诊断桥；能力自检仍完整执行真实创建、初始化和
  释放，平台诊断只在初始化失败后补充稳定 `errorCode`。
- App Bridge 命令错误、能力异步错误和 App SDK `Error.code` 保留诊断码；Runtime 与
  GDevelop 扩展按 SDK 文档同步，Game SDK `4.1.0`、App SDK `3.3.0` 均不升版。
- “检查更新”弹窗改为克制的短文案；新版本说明独立弹出，下载线路在窄屏下保持单行并直接
  显示 `xxxms`。App 升级到 `4.3.1+31`，Runtime 底包升级到 `1.0.2+5`。

## 4.3.0 发布归档

- Game SDK `4.1.0` 兼容新增 `playmesh.main.rpc.request/onRequest`，版本号保持不变。
  客户端请求全部异步，只有 Authority 能监听；handler 可同步或异步返回。请求与结果
  复用会话认证的 Binary WebSocket 内部帧，支持 JSON 兼容值、Blob/File、ArrayBuffer
  和 Uint8Array，不再通过 JSON action 信封传输。Go Core 只做身份、path、限流、大小和
  超时校验，且后台拒绝非 Authority 伪造响应。GDevelop 扩展同步加入 RPC 调用、监听和
  `$binary/$file` 请求响应桥接。

- App Bridge SDK `3.3.0` 兼容新增 `playmesh.app.storage.getBucket()`，版本号保持不变。
  App 页面在当前设备读写独占 JSON Bucket；数据不通过 Authority、Session 或其他玩家同步，
  原生宿主按游戏隔离持久化，普通浏览器使用当前源的 `localStorage`。

- GDevelop WebIDE Playmesh revision 升到 `20`，Tool Contract 兼容升级为 `4.1.0`（51 个工具）。
  AI 扩展安装在 Playmesh 完成目录解析、制品下载、哈希校验和审批后，改为把真实
  `EventsFunctionsExtensionsState` 交给官方 `addSerializedExtensionsToProject`，随后沿用官方
  `onExtensionInstalled`，并移除官方处理后的二次存在性校验。新增
  `preview_or_refresh_project`，只调用 WebIDE 工具栏当前选择的官方新建预览或热重载回调。
- Runtime 分享面板现在可在多条局域网地址间切换二维码；主 App 与 Runtime 的 SDK 启动
  遮罩统一为仅含 Playmesh 标识和转圈的加载层。Runtime 底包版本提升为 `1.0.1+4`。
  统一加载层由新的本地包 `packages/playmesh_ui` 提供，避免主 App 与 Runtime 维护分叉 UI。
- 安装包导出新增默认关闭的“自动同意能力授权”开关，并在需要下载或更新 Runtime 底包时
  强制用户明确选择下载线路；客户端提交受校验的 opaque ID，服务端只下载所选线路且不
  自动回退。导出流程调整为“平台与底包 → 导出参数 → 生成安装包”三步并支持逐步返回；
  底包弹层再按“选择来源 → 选择线路”两步推进并支持返回，线路显示并发探测的延迟状态。
  导出平台改为纵向紧凑单选行，来源与线路信息统一左对齐，两个开关的控件与文字垂直居中。
  点击入口后先显示向导并异步回填本地状态；只有明确更新或下载时才读取目标来源，线路测速
  只在选中来源后针对该来源异步回填，且不阻塞线路选择；中转服务器也延后到第二步读取，
  不再阻塞弹窗出现。
- Developer API / OpenAPI 升级为 `5.0.0`：源代码工作区“上传到发布源”不再执行项目
  语义校验，也不再返回校验报告或 `package_validation_failed` 422；包导出仍保留 ZIP
  路径、容量、符号链接和基础清单元数据等传输安全边界。项目校验函数与 Operation、既有
  AI 提示、本地运行、安装包导出与重新导入的校验要求不变。
- 源代码工作区只在当前源的 `localStorage` 记忆最近项目 ID；下次进入时仅在该项目仍存在时
  自动打开，否则展示项目选择器，不回退到服务端活动项目或列表首项。
- Go Server 接收包不再绑定当前 SDK 版本或固定清单结构，并保留未知清单字段；默认内容扫描
  不再拒绝 HTTP/HTTPS/WS/WSS、协议相对链接、动态 `Function`、`file:`、`javascript:`
  或 `iframe/object/embed`。旧配置中精确等于历史默认值的对应规则会在加载时迁移移除，
  运营方显式配置的其他自定义规则不受影响。`app/` 内其他资源不再使用扩展名或文件类型
  白名单；只按 `main.json.entries.game` 定位 `.html` 首页并确认其为非空、合法 UTF-8、
  无 NUL 的网页文本。App 上传与网页上传共享的服务端 IP 限流窗口由 30 秒缩短为 2 秒。

## 4.2.1 发布归档

- 安装包导出使用横向平台卡片和安装/更新角标，移除 Runtime 版本及重复的安装/下载诊断行；
  `package_exports.options` 兼容新增 `updateAvailable`，只按本地与清单 SHA-256 判定更新。
- 移动端中转服务器菜单改为文档流内展开且不自动聚焦搜索框，避免软键盘覆盖选项；桌面和
  Android 继续复用同一套工作区前端。
- GDevelop 主页侧栏和动作短文案完成响应式修复；开发者 WebView 刷新统一加载去除一次性
  query/fragment 的稳定 URL，不再重放已轮换 capability。
- App 升级为 `4.2.1+29`，Developer API / OpenAPI 升级为 `4.4.0`，其余 SDK、Core、
  Catalog、Relay 与 CLI 版本不变。

## 4.2.0 发布归档

- 游戏详情移除“导出游戏包”，源代码开发工作区把原“发布”入口改为“导出”，并提供
  “导出源码 / 上传到发布源”两个选项。源码导出直接复用既有宽松
  `GET /dev/api/projects/{projectId}/package`：App WebView 由原生宿主携带当前 Developer
  Token 流式保存，普通浏览器触发标准下载，不新增 Operation。源码工作区与 GDevelop
  复用同一原生保存钩子和宿主下载/写盘/清理函数，但项目包不在 WebView 中聚合 ZIP，也不
  POST 到需要 editor lease 的 GDevelop Blob 暂存链；多源上传的完整校验、单包并行上传、SSE 状态和失败重试
  保持不变。产物仍只含发布内容并排除运行数据、缓存和开发历史；重新导入继续严格校验。
  导出选择器只保留两个动作名称并使用并列操作卡；触发源码导出后先显示不可重复点击的
  “处理中”状态，再分别交给浏览器下载或既有 WebView 原生保存界面。
  浏览器响应与 WebView 原生保存建议名重新统一为 `{游戏名称}-v{版本}.zip`，共同复用游戏包
  文件名清洗函数，不再暴露 `{projectId}.playmesh.zip`。
  在文件树中打开文本、图片或其他资源时不再重新请求并重建整棵树，只更新当前文件选中态，
  因而保留左侧滚动位置和目录展开状态。
- “安装包导出”使用独立 `package_exports.*` Operation，选择 Android ARM64、Android
  x86_64 或 Windows x64，并可配置一个内置中转服务器。主 App 不携带 Runtime 底包；
  服务按 `App.json -> Runtime update.json -> 目标下载线路` 获取并校验 SHA-256，已有底包
  默认复用且可强制刷新。Android 导出执行注入、加密与签名，Windows 导出重写资源并打包
  ZIP；源码包与安装包共用浏览器下载/App 原生保存函数和进度状态。
- 完成默认不公开的局域网附近对局：游戏启动和开发预览不申请 publication lease；用户
  打开分享面板或
  本机房主调用无参数 `playmesh.app.lan.setPublished()` 后，App 才通过唯一自定义 IPv4
  UDP multicast 发布，关闭面板不取消，退出游戏或页面销毁时停止公告并 best-effort 发送
  goodbye。协议固定 `239.255.80.77:53584`、wire v1、1 秒公告、4 秒 TTL、单包最多
  1200 字节；不保留 DNS-SD/TXT、第二发现栈或已知节点单播兼容。
- Android、Windows、macOS、Linux 分别覆盖全部有效物理 IPv4 网卡和支持组播的虚拟网卡，
  不依赖默认路由；接口动态重整且部分失败隔离，发现地址只取数据报真实 source IP。iOS
  自动发现/发布显式为 `unsupported`，扫码、手工邀请和分享链接仍可用。该能力不承诺穿透
  AP 隔离、VLAN、防火墙、禁用组播或 VPN/虚拟网卡策略。`169.254/16` link-local 只放宽给
  游戏发现/分享，不扩大到 Developer Gateway 等其他地址暴露链。
- App 加入页显示所有 gameId，并以纯文本展示游戏名、主机昵称、真实 source IP、多人
  当前/最大人数或“单机”，随公告/presence 自动更新且保留手动刷新；点击后发现 lease 与
  候选保留至统一预检和复查结束。游戏 SDK 仍只投影当前 gameId 的既有
  `instanceId/gameId/name/host`，不增加内部展示元数据或图标端点；手工链接、扫码、发现项
  和 SDK 加入复用同一邀请预检及既有 `RemoteGamePage`。
- Go Core Session 的 `MaxPlayers` 硬上限由 16 提升为 32，局域网 presence 同步接受
  `maxPlayers <= 32`，33 及以上仍在创建 Session 时拒绝。GDevelop 联机运行时的独立 8 人
  编号与 readiness 协议不随本项机械扩容。
- 分享链收口为单一 `GameShareCoordinator`：Core/standalone 授权、网关、multicast
  publication lease、Relay、generation、清理和不可变 `GameShareLinkSnapshot` 由一个
  权威写入者管理。分享面板、开发状态与 App SDK 读取同一组非回环 IPv4/当前有效 Relay
  URL 和同一 PNG；没有可用 LAN 地址时不返回 `127.0.0.1` fallback，Relay 内部使用独立
  回环邀请入口。multicast 公开失败保留手工分享通道并允许只重试公开。
- App Bridge SDK `3.3.0` 兼容新增 `playmesh.app.lan`：发现、链接加入和扫码加入需要
  真实用户操作；`getShareLinks()` 则只允许 App-only 当前本机 Authority/standalone host
  无副作用读取完整 LAN/Relay bearer URL 与逐链接 PNG Data URL，不新增 capability、确认
  或 user activation。这一授权替代旧的绝对禁读规则；平台仍不把 URL、token 或 PNG 写入
  日志、磁盘、分析、崩溃详情或错误。另新增无参数、单向且幂等的
  `playmesh.app.ui.disableSystemMenuTriggers()`，可解绑当前文档默认 Escape/Menu/Back 自动
  菜单触发而不影响显式 UI 方法，刷新文档后恢复默认绑定。
- 本功能保持 App `4.2.0+28`、Game SDK `4.1.0`、App Bridge SDK `3.3.0`、Go Core
  `0.5.0`、Core 协议 `1.3.0`、Catalog `3.0.0` 与 Relay `3.0.0` 不变；
  `/playmesh/join` 只兼容增加 `gameId/gameName` 预检字段。自动化与静态契约已完成，
  Android、Windows、macOS、Linux 的发布、发现、丢失、权限、网络切换和实际加入仍待
  跨设备实机验收；正式包发布不代表这些实机项完成。iOS 回归范围是稳定 unsupported 与保留入口。
- 设置页“关于 Playmesh”新增手动检查更新。App 只打包统一资源渠道目录
  `assets/app/App.json`，检查更新时仅投影存在 `app` 字段的渠道；缺少该资源的渠道跳过，
  其他资源键不校验。并发请求全部 App 远端 JSON 后按严格语义版本选择最高有效清单，再按
  当前平台展示下载线路名称与复用的端点延迟检测结果；界面始终显示当前/远端版本和新版本
  说明。下载地址只交给系统默认浏览器，App 不下载、不校验安装包且不安装；动态
  `app_update.json` 不打包。
- `App.json`、GDevelop `update.json` 与 Runtime `update.json` 的链接不再受 HTTPS、凭据或
  Fragment 策略限制；HTTP/HTTPS 网络请求自动跟随最多 5 次重定向且不复查跳转目标。
  Runtime 清单改为每个 `x86`、`arm`、`windows` 目标各声明一次 SHA-256，渠道只保留
  `name/url`，所有渠道下载后统一使用目标摘要校验，不再允许渠道级摘要分叉。
- 设置页不再承载开发者模式。首页“加入对局/在线游戏库”下方新增“制作游戏”入口，统一
  控制同一个 Developer Gateway 会话；源代码开发与基于开源 GDevelop 的可视化开发使用
  两个独立折叠入口，各自维护链接、可用性和打开语义，公共层不再使用
  `workspaceKind` 条件分支。GDevelop WebIDE 的远端版本清单渠道同样只从 `App.json` 的
  `gdevelop` 字段投影，不再维护独立入口文件。GDevelop 官方 WebIDE 仍为运行时可替换资源，
  不内置下载器或新服务器。
- Developer API / OpenAPI 兼容升级到 `4.3.0`，新增安装包导出、临时开发资源会话与独立 capability
  `gdevelop.history.v3`。GDevelop 当前工程与历史 revision 同时保存官方 folder-project
  多文件树、
  图片、音频、视频、字体、3D 等完整 PlaymeshLocal 资源 manifest；每项目独立 CAS 以 SHA-256
  去重并由 current/history 分别 pin，只有零引用 blob 才可 GC。
- GDevelop 资源通过现有同源 Developer Gateway 流式暂存；Content-Length 存在时只用于提前
  拒绝明显超限，最终始终严格校验实际字节数、SHA-256、MIME、大小、gameId 和 logicalId，
  不把完整资源驻留内存。snapshot staging 验证全部资源后原子提交；restore 在同一事务中
  先快照当前工程和资源，再切换目标版本；
  修订冲突、资源缺失、配额超限、上传超时和请求超限具有稳定错误码。
- WebIDE 在保存前使用批量 presence 接口检查最多 2048 个 `{contentHash,size}`，只上传
  CAS 中缺失的新增或更新资源。连续相同快照、删除资源和改回仍由历史 pin 的旧 hash 都
  不产生重复 Blob 上传；客户端不能用受项目 pin 授权的逐个资源 GET 代替存在性预检。
- GDevelop 的既有 `autosaveOnPreview` 开关成为自动保存总开关：PlaymeshLocal 有新修改时
  每 60 秒自动保存，并在预览前复用同一去重入口；成功自动保存以 `autosave` reason 创建
  可见历史修订，不清除手动保存 dirty 状态。busy、历史未创建和瞬时失败保留游标供下一周期
  重试；revision conflict 则阻断定时器重放同一 generation，直到出现新的本地修改。
- GDevelop 历史默认保留每项目 50 revision、每项目 unique CAS 256 MiB、
  project files 合计 32 MiB、单资源 64 MiB、未 pin staging 24 小时；桌面配置对象可提高到
  每项目 100 revision / 1 GiB / 单资源 128 MiB。不存在全局历史配额或跨项目淘汰；
  项目内淘汰永不删除 current，配额失败保持其他项目原状态。
- GDevelop managed project 的身份、项目列表、canonical current 与历史证据改由 App Gateway
  持有，浏览器 IndexedDB 仅作为可丢弃编辑缓存。新增 project-allocation 事务：冻结 immutable
  workspace target，声明完整资源计划，上传缺失 raw blob 与 exact projectFiles tree，finalize 时按
  官方资源顺序建立首个 history current，durable decision 后原子发布项目根，并支持幂等查询、
  只向前 recover 和决议前 abort。生命周期和历史 wire 直接使用与
  `properties.packageName`、`main.json.id` 相同的
  `gameId`，不签发额外 opaque handle。managed root 固定为 `packages/{gameId}`，历史位于
  平台 sidecar `.playmesh/gdevelop/history`；另存为共享历史，复制为新工程分配新 ID 和
  独立历史。
- GDevelop 本地 AI 开发流升级为 v4：Chat/Agent 共用固定 5.6.276 的唯一 50-tool 合约、
  两套可覆盖提示词、短期内存 editor session、turn/call 幂等状态机、统一危险操作审批、
  单 writer lease 以及明确的超时/取消边界。Gateway 只协调调用；当前 WebIDE 直接把同一个
  活动 `gdProject` 传给官方 EditorFunctions，并在函数返回后触发官方回调和 dirty 状态。
  AI 不保存工程、不写 GDevelop current/历史、不创建 revision 或提交证据，也不执行快照、
  回滚、浏览器 pending journal、启动恢复或事件纠错。用户继续按 GDevelop 正常流程自行
  保存。Chat 提示词不包含 Token；Agent 继续使用现有 Developer Gateway Token，不签发
  第二种凭据。SSE 断开时可按 sequence 轮询调用状态，AI、prompt 或 locale 加载失败不影响
  普通编辑、保存和预览。Chat 粘贴协议严格使用根 `{echo,calls}`；单个或批量提交都只带
  一个根级 echo，调用项不带 echo。Chat 返回状态升级为
  `playmesh.gdevelop.ai.return-status.v3` 并在 `schemaVersion` 同级回显 echo；Agent 返回状态
  保持 v1 且不包含 echo。
- GDevelop 内核升级至 5.6.276（Playmesh revision 18）；移除上游已经正式修复的本地
  SceneEditor/Mosaic 补丁，重新冻结源码策略、官方 libGD 配对与完整测试包证明链。
- GDevelop AI editor-session wire 升级为不兼容旧宿主的 `4.0.0`，保留独立 `GDevelopAiProjectContext
  1.0.0`：上下文直接使用官方完整 SimplifiedProject、ExtensionSummary、选中场景事件和
  当前工具能力引用，并做 canonical SHA-256、体积/深度限制及 Token/URL/Bridge 拒绝。
  session 创建或 PATCH 均可提交 context。execution 只接受 `success`、`output` 以及失败时
  可选的字符串错误字段；WebIDE 在回传前以 `gameId + sessionId + callId` 缓存固定结果，
  响应丢失只重发同一结果，不重新执行内部函数。
- `add_scene_events` 新增固定 `GDevelopEventPayload 1.0.0` 信封，只接受官方
  `AiGeneratedEventChange` DTO，不接受裸 EventsList 或自造 placement。Chat 粘贴 envelope 在
  `name`、`arguments` 同级携带完整 `eventPayload`；浏览器校验后把它作为
  `input.eventPayload` 与 call 一次入队，并纳入幂等指纹。输入在审批前锁定，审批后不能补交
  或替换；不存在 `awaiting_event_payload`、correction API、自动纠错或旧 CAS 引用兼容。
- GDevelop Tool Contract 破坏性升级为 `4.0.0`。GDevelop 5.6.276 源码 ZIP 不包含服务端
  AI 输入 Schema，因此本地契约明确标记为针对固定源码的 v12 兼容快照，而不再声称由官方
  Schema 自动生成。17 个直传工具统一使用官方当前函数名与完整参数，参数原样进入官方
  runner；旧资源/对象子集别名以及 `delete_object`、`remove_behavior`、`delete_scene` 被移除，
  删除语义由完整 change 函数的 `delete_this_*` 字段提供，并按完整函数的最高风险审批。
  对象组成员使用 `objects_to_add: string[]` / `objects_to_remove: string[]`，同时补齐 2D 实例
  rotation/opacity、首场景、图层可见性、批量变量与资源必需名称等源码消费字段。新增
  clean-replay 校验直接读取锁定的 `Utils.js` 与 `EditorFunctions/index.js`，核对官方 v12、
  实现名、修改标记及 `SafeExtractor` 字段，旧 `objects` 形状或字段漂移会阻断构建。
- 恢复 GDevelop 5.6.276 官方 Piskel、Jfxr、Yarn 本地外部编辑器及原入口。三套固定版本编辑器
  作为离线锁定构建输入，资源继续走官方 `save -> fetch -> free` 生命周期并由 PlaymeshLocal
  接管存储；分析、账号、公共发布、远程词典等联网服务被移除。本地 AI 工具真实复用同一套
  Piskel 切图/GIF 解码、Jfxr 合成与 Yarn 数据引擎，不复制其算法。
- AI “始终允许”授权改为按 `scopeKind + scopeId + operationId` 持久化，新增授权列表与撤销
  API；source/GDevelop 项目删除分别清理自身授权，损坏授权文件按 fail-closed 处理。
- GDevelop WebIDE 新增 editor-session scoped `approvalMode`。新 session 固定从 `request_approval`
  开始，同一 session reattach 保留；显式 close 或 Developer Mode 进程/Gateway 重启后恢复
  `request_approval`，且模式不写项目、历史、配置或授权文件。切到 `always_allow` 会立即批准
  当前 session 所有 pending 及后续危险调用；切回 `request_approval` 不撤销已经批准、排队或
  执行的调用。既有按工具与 scope 保存的 grant 继续生效；外部 Agent 无权修改该设置。
  WebIDE 首次申请 editor lease 还要求 App 启动链接签发的独立内存 capability，并在成功申请
  后轮换；Developer Bearer 本身不能获取 lease，也不能经通用审批 API 自行批准 GDevelop 调用。
- GDevelop 临时预览只接受标准 Playmesh ZIP，并通过 DeveloperRun -> GamePage ->
  GameWebGateway/Core 的现有运行链启动；不安装、不写 Catalog、不暴露临时资源凭据。
  GDevelop `index.html` 的 locale bootstrap 只含 `workspace.gdevelop_*` UI 文案，桥接失败
  原样返回 IDE，且动态 index 强制不缓存。canonical Multiplayer Bootstrap 仅在预览/
  发布且明确启用多人或无法可靠判断时注入，明确禁用时跳过，原始官方导出保持零注入；
  `unknown` 仅保守携带兼容脚本，不能据此把 `main.json` 提升为多人，未显式启用时仍按
  `solo` 运行并由 Bootstrap 的多人会话守卫保持休眠。
- 标准 `POST /dev/api/packages/import` 改为请求流直接落临时 ZIP，声明长度或实际字节超限、
  连续 30 秒无数据、空流和中途异常都有稳定错误并清理部分文件，不再在 Gateway 内聚合
  整包字节。同 ID 更新安装继续原子替换用户包内容，同时保留平台拥有的 `data/`、`cache/`
  和 `.playmesh/`；上传包仍禁止伪造 `.playmesh`。
- GDevelop 多人发布保持既有 Manifest 协议：生成包显式声明
  `authority.entry: static/js/service/index.js`，并由主 HTML 唯一加载同一入口。入口内容从
  平台唯一 canonical Bootstrap 源生成，不在每个项目维护分叉；Bootstrap 等待迟到的
  Playmesh SDK，按固定 `session.isAuthority()` 角色只处理低频 channel 发现、加入与清理，
  高频 GDevelop 状态帧仍走 Binary Channel bridge。guest 不注册 Authority 服务，也不能在
  dispose 时关闭共享 channel；Authority 注册幂等且只关闭自己创建的 channel。

- App Bridge SDK 升级到 `3.3.0`，新增
  `playmesh.app.ui.onGameMenuOpen()` 与 `onGameMenuClose()`。游戏可注册并注销菜单开关
  回调，用于暂停/恢复自身逻辑；事件覆盖公开方法、悬浮按钮、菜单键、返回键、继续、
  遮罩、重启、退出和禁用兜底 UI 等入口，只在真实状态切换时触发，单个回调异常不会
  阻止菜单或其他监听器。
- Developer CLI 新增 `playmesh-cli convert`，可把从 App Developer API 手工复制出的
  标准 `main.json + app/` 项目包原子转换为 JavaScript CLI 2.0 工程；转换会安装当前
  SDK、升级清单版本、迁移可选能力与图标、保留无关文件，并拒绝覆盖已有脚手架。

## 4.1.0 发布归档

- 根 `README.md` 改为完整英文默认入口，原中文内容保留为 `README.zh-CN.md`，两者在
  顶部互链；`docs/` 继续作为中文权威资料，不建立英文镜像。
- AI 提示词模板按全局 locale 分入
  `assets/playmesh-library/public/developer/prompts/{locale}/`，同一清单为全局语言配置中
  每个启用 locale 声明完整模板映射。英文版覆盖 ChatAI、AgentAI、单机、多人及两种
  显示模式，中文模板内容保持不变。
- 提示词不再维护 App 级文案或第二份 locale/fallback 配置。模板名称、分类、动态标题、
  说明和能力描述统一读取全局 `app.json`；默认 locale、启用语言和 fallback 统一读取
  `assets/playmesh-localization/manifest.json`。Dart/JavaScript 只保留公共解析与拼装逻辑。
- Developer API / OpenAPI 兼容升级到 `4.1.0`：提示词模板列表、保存、恢复和项目提示词
  导出接受可选 BCP 47 `locale` 查询参数，返回解析后的 locale；未精确命中时按全局语言
  清单选择同语言资源或 default locale。不同 locale 的用户模板覆盖相互隔离。
- Developer Workspace 自动把当前 App locale 传给模板与项目提示词接口。新增语言只需
  补齐全局语言声明、对应 `app.json`、提示词语言目录、清单映射和 Flutter 资产目录，
  不修改提示词业务代码。

## 4.0.0 发布归档

- 游戏包物理结构继续保留根 `main.json`、可选 `capabilities.json`、可选
  `icon.png` 与 `app/`，外层物理 `app/` 直接挂载为运行时 `/`。清单入口使用
  `index.html`、`controller/index.html`、`static/js/service/index.js` 这类相对于
  外层 `app/` 的路径；用户首段 `app` 合法，例如入口 `app/index.html` 对应物理
  `app/app/index.html` 和运行时 `/app/index.html`，但不会别名到外层
  `app/index.html`。
- 所有游戏必须显式声明 `entries.game`；`single_screen_multiplayer` 必须显式声明
  `entries.controller`；`multiplayer` 必须显式声明 `authority.entry`。运行时只按
  清单实际值解析，缺失字段直接拒绝，不硬编码模板路径回退。
- `entries.game` 与 `entries.controller` 现统一支持 `relative.html?query`；物理包
  校验只使用 `?` 前路径，本地 CLI/App 保留查询参数段顺序、重复键与编码值语义。
  页面查询仅是自定义启动配置；App 身份、昵称、能力和 Core 地址统一由标准 App SDK
  通过原生 Bridge 调用 Dart `app.bootstrap` 获取，不再使用 App 模式、SDK URL 或
  昵称查询参数。go-server 云分发上传会对
  查询串递归 URL 解码并执行外链主动内容扫描；`authority.entry` 仍禁止查询串。
- 局域网邀请改为 `/playmesh/join#inviteToken=...` 两段式握手：落地页以 POST
  交换短期 HttpOnly Cookie 后重定向到 manifest 完整入口。最终游戏 URL 不再追加
  或覆盖 `channelId/token`，普通浏览器和 App WebView 使用同一协议。
- Game SDK 升级到 `4.0.0`，App Bridge SDK 升级到 `3.2.0`。公共游戏域只位于
  `playmesh.main.*`，当前客户端域只位于 `playmesh.app.*`；locale 固定为
  `playmesh.app.runtime.getLocale()`，性能固定为 `playmesh.app.performance.*`，
  不存在 `playmesh.main.performance`。面向游戏开发者的唯一全局对象是
  `window.playmesh`，其根级公开成员严格只有 `ready`、`main` 与 `app`；
  `window.playmeshApp` 与公开 `__*` 内部桥接均被删除，内部协作改为不可枚举的私有
  `Symbol` runtime。`main.ready` 内部先等待 `app.ready`，根 `playmesh.ready`
  只复用这条初始化链并返回 `{main, app}`。运行文件成对改为
  `/playmesh/sdk/v1/playmesh-main.js` 与
  `/playmesh/sdk/v1/playmesh-app.js`，类型文件成对改为 `playmesh-main.d.ts` 与
  `playmesh-app.d.ts`；旧 `playmesh.js` 和旧 Game 类型文件均不兼容、不回退。
- 性能浮层唯一由 App SDK 创建和维护；Game SDK 的旧浏览器性能 panel 已删除。
- `main.json.sdkVersion` 只接受 `4.0.0`；`appSdkVersion` 只接受 `3.2.0`。
  更旧、未知或格式错误值直接拒绝，
  不提供历史静态文件或旧命名空间 shim。
- `/playmesh/**` 与 `/bucket/**` 成为唯一平台保留命名空间。App、CLI 与 Go Server
  统一拒绝物理 `app/playmesh/`、`app/bucket/` 的大小写变体，以及百分号编码、
  反斜杠、空段、`.`、`..` 和符号链接绕过；游戏/控制器入口只允许 `.html`，
  Authority 入口只允许 `.js/.mjs`。`app` 不属于保留名，物理 `app/app/**` 和
  运行时 `/app/**` 均按普通用户资源处理。
- App 只区分正式已安装游戏资源和临时开发资源，二者共用
  `GameWebResourceSource` / `GameWebResourceProvider` 接口。游戏 WebView、局域网
  分享和开发运行复用同一资源边界；开发态只把普通路径代理到固定开发源，
  `/playmesh/**`、`/bucket/**` 仍由 App 本地处理，并支持 GET、HEAD 与保留
  WebSocket 子协议。在开发资源链路中，Developer Gateway 位于控制面，负责建立和
  撤销开发会话；页面资源请求仍经 `GameAssetGateway` 与开发 Provider 转发。主机/
  加入端、浏览器/App、局域网/公共中转是正交的共享与传输维度，不改变资源源类型。
- 游戏启动全屏改为入口显式策略：游戏库详情与首页快速游戏固定全屏；开发者工作区、
  CLI `run` 和 CLI `dev` 在 Android/iOS 手持端仍全屏并应用方向，在 Windows、
  macOS、Linux 桌面端默认窗口化；控制器/加入端继续默认全屏。SDK 后续主动切换
  全屏的能力不受限制，退出窗口化开发页时会清理 SDK 临时进入的全屏状态。
- Developer API 升级到 `4.0.0`，新增
  `GET/POST/DELETE /dev/api/projects/{projectId}/development`。开发会话绑定项目、
  当前 CLI 来源、一次性凭据与最长 24 小时有效期，只驻留内存；重复 `dev`、正式
  `run/restart`、DELETE 和到期清理按 `runId` 串行，替换前关闭旧页面、资源网关及
  既有 WebSocket，停止失败保留可重试句柄。
- Developer CLI 升级到 `2.0.0`。所有项目必须使用根 `playmesh-cli.json`、隔离的
  `playmesh/package` 与 `playmesh/sdk`，不再兼容
  `main.json/app/playmesh/sdk` 直接位于项目根的 1.x 结构；旧 JavaScript 项目只可在
  空目录重新 `get`，不可逆的 TypeScript/Cocos 源码必须从版本库迁移。上传只读取
  `playmesh/package/` 中的必需 `main.json`、可选 `capabilities.json`、可选安全根
  `icon.png` 与必需 `app/`；`playmesh/sdk/` 永不上传。
- CLI 新增 `run`（正式构建、完整上传并运行，不附加日志）、`logs`
  （只附加当前项目实时日志）和 `update`（更新 SDK 后转交项目适配器）。`dev` 改为
  本地开发资源代理 + 真实 App 运行 + 日志：仅目标缺少项目时上传包含必需清单、可选
  能力声明、可选 `icon.png` 和必需入口占位文件的最小基础包。公开
  `create/push/sdk` 已删除。
- CLI Go 源码按职责迁入 `dev-cli/internal/`：模块根只保留薄入口 `main.go`；命令、
  项目模型、打包、SDK、目标凭据、开发资源和各引擎适配器分别成包。Cocos 扩展资源
  随适配器归档，Windows/Linux 构建递归跟踪内部源码与嵌入资源。
- `dev` 的开发资源统一收口为公共 `development.Source` /
  `development.Mapping`：Adapter 只提供来源、路径、headers 与 `Start/Stop`
  生命周期，CLI 公共代理和 App Developer Gateway 都不包含 Cocos 或其他引擎分支。
  JavaScript、TypeScript、Cocos 及未来 Godot 只在 CLI 的唯一 `adapter.Registry`
  注册；新增引擎不修改 App 代码或 App 资源源类型，也不新增第二份适配器实例表或
  第三套代理。
- CLI 目标 App token 不再明文写入 `cli-target.json`：Windows 使用当前用户 DPAPI，
  macOS 使用 Keychain，Linux 使用 Secret Service；旧版明文配置不迁移，必须重新
  执行 `playmesh-cli to`。安装目录不保存凭据，避免只读、多人共享和应用升级替换。
- 项目创建统一为公共 `init [平台]` 入口。无平台参数时用数字选择 JavaScript 或
  TypeScript，并生成 Vue 风格的根 `package.json`、`src/` 源码目录、
  `jsconfig.json/tsconfig.json` 和 npm `build/dev/run/logs/update` 脚本；IDEA 可直接
  点击 npm `dev` 运行按钮把开发 Web 根代理到真实 App。空目录 `get` 固定把
  App 发布包恢复为 JavaScript 2.0 工程；由于发布包不含 TypeScript 类型或 Cocos
  工程源码，生成结果不能还原这两类原始工程，它们必须从源码版本库恢复。
- 首个 `init cocos` 适配器支持 Cocos Creator 3.x，从项目描述文件自动读取名称，
  通过带可见默认值和数字选项的向导调用现有创建 API，并生成隔离包目录、SDK 类型
  引用、配置 Schema 和项目级 Cocos 扩展。已初始化或已经是 Playmesh 项目的目录会
  在任何写入和远端创建前拒绝重复初始化。
- CLI 生成的 `playmesh-cli.schema.json` 完全使用项目内本地引用，不声明虚构域名或
  外部 JSON Schema 地址；内置 SDK、Manifest 与能力契约 Schema 同样使用本地相对
  标识。
- Cocos 扩展接入 Web Mobile/Web Desktop `onAfterBuild`，并在两个 Web 构建面板
  显示“启用 Playmesh 发布”和“构建后上传并运行到 App”选项。构建结果先进入临时
  目录，注入标准 Game SDK 标签后原子替换 `playmesh/package/app/`，再按选项调用
  `playmesh-cli run` 在真实 App 中上传并启动；“扩展 -> Playmesh”菜单可打开构建
  发布、使用浏览器预览地址启动 `dev`、运行最近构建、附加日志和执行完整集成更新。
  预览地址按消息参数、`PLAYMESH_DEV_SERVER_URL`、`integration.developmentServerUrl`
  依次解析；Cocos 3.8 的公开扩展接口不支持向发布平台或顶部预览设备下拉框注册
  自定义项。
- 游戏库本地导入新增普通网页 ZIP 转换。压缩包根目录没有 `main.json` 但包含 HTML 时，
  App 会让用户确认游戏名称、主屏方向、游戏模式、显示模式和主入口；单屏多人另外确认
  控制器方向与控制器入口。找到 `index.html` 时默认使用其非空 `<title>` 作为游戏名，
  否则回退到压缩包文件名。
- 普通网页包转换会剥离统一公共外层目录，把全部内容迁入标准包物理 `app/`。由于
  `app/` 已直接挂载为运行时 `/`，原相对路径和 `/assets/**` 等根路径保持不变，
  转换器不会为外层物理目录自动添加 `/app` 前缀；用户内容原有的 `app/` 目录和
  `/app/**` 引用、外部 URL、协议相对 URL、未知 `/api`/路由和二进制文件同样保持
  不变。转换结果重新经过标准包清单、入口、保留目录、路径、大小和危险文件校验后
  原子提交；已有根 `main.json` 的包继续走严格导入，没有 HTML 的压缩包明确拒绝。
- 普通网页包选择多人不表示导入器自动增加联机玩法；转换只生成平台所需的模式、玩家
  和入口声明。单屏多人会保留独立主屏与控制器 HTML，并生成内部兼容 Authority 入口，
  页面之间的游戏业务和通信逻辑仍由原网页包负责。
- 普通网页包导入新增标准包识别、非网页包拒绝、`index.html` 标题、公共外层目录、
  原相对路径与根资源保留和单屏多人条件表单回归测试；`dart analyze lib test` 无问题，
  全量 `flutter test --no-pub` 共 336 项通过。
- 为兼容 Cocos HTML 游戏较大的 `.wasm`、`.data` 和资源合包，游戏包导入预算提高为
  压缩文件 100 MiB、解压总量 512 MiB、单文件 128 MiB、最多 8000 个文件；目录穿越、
  符号链接、重复路径、危险文件类型和原子提交保护保持不变。
- Catalog API 升级到 `3.0.0`。Go Server 在接收并规范化游戏包时把 ZIP 实际字节数
  写入 SQLite，后续游戏列表以可选 `packageSizeBytes` 返回，不再为每次列表请求读取
  文件；默认上传预算同步为 100 MiB 压缩、512 MiB 解压、128 MiB 单文件和 8000 文件，
  并采用与 App 相同的根相对入口、入口扩展名和一级保留目录校验。
- Relay 协议升级到 `3.0.0`。局域网邀请和端点加密公共邀请都封装
  `/controller/index.html` 这类根相对入口；若清单声明 `app/controller/index.html`，
  则原样生成 `/app/controller/index.html` 并解析到物理 `app/app/controller/index.html`。
- 下载弹框新增“准备游戏包”“下载”“校验并安装”阶段。App 临时局域网源按需压缩时
  显示不定进度，收到响应后按 1024 进位展示总大小、当前速率和已下载/总量；列表未
  提供大小时使用响应 `Content-Length`，无需为 App 临时分发预生成或持久化 ZIP。
- 修复 App 加入端加载权威主机游戏或单屏多人控制器时，虽已通过
  `controllerRequired` 声明并获得系统摄像头/麦克风权限，WebView 仍因没有接通权限
  回调而拒绝 `getUserMedia()` 的问题。
- Android、iOS 与 macOS 加入端现在按权威页面下发的最新运行时能力声明处理 WebView
  摄像头、麦克风和 MIDI SysEx 权限；Windows 加入端改为读取 App Bridge 的运行时
  声明，不再使用构造阶段的空能力数组。
- App WebView 敏感权限改为统一能力注册表模型：统一层按当前页面角色声明把请求资源
  映射为现有能力 code，检查插件可用性，再按 code 调用能力注册时绑定的唯一平台授权
  执行器。执行器不再维护额外 ID，也不负责路由或声明判断；本地页、加入页、Windows
  WebView 和 Android Activity 不再维护摄像头、麦克风或 MIDI 的外部 switch。普通
  浏览器不进入 App 原生权限执行链；新增权限型能力只需注册资源映射与唯一执行器，
  系统静态权限声明仍按平台要求同步配置。
- 加入端开始新导航时立即清除上一页面的动态能力声明和确认状态，避免旧页面权限被
  后续页面短暂沿用；未知、未声明或平台不支持的权限继续默认拒绝。
- Android 加入端补齐网页文件选择器接入，与本地游戏 WebView 保持一致，文件选择仍由
  用户主动触发且不申请存储权限。
- 新增 Android `sensor.pose6d@1.0.0` 能力。游戏可按 `1..60 Hz` 接收 ARCore 的
  米制 XYZ 与 XYZW 四元数，实例支持独立 `recenter()`，多个实例共享一个 ARCore
  Session 并以最高订阅频率驱动原生采样。
- 新增协议无关的 `playmesh.app.media`。能力实例只签发不透明媒体源，网页需要画面时
  才调用 `media.open(source)` 得到 `MediaStream`；停止消费或释放能力实例会回收媒体
  会话和源。公共层只负责适配器注册、选择、签发和生命周期，`adapterOptions` 由具体
  适配器自行解析。
- 首个 Android 媒体适配器为 WebRTC。offer/answer 通过现有 App Bridge 单次交换，
  PeerConnection 只在同一终端的原生宿主与 WebView 之间建立，不增加 HTTP 地址、开放
  端口或信令服务器。后续协议只需实现并注册自己的 Dart/网页适配器。
- 能力句柄新增 DOM 风格 `addEventListener/removeEventListener` 别名；既有
  `on()`、`onError()` 与 `dispose()` 保持不变。
- 能力平台注册改为 `CapabilityPlatform.WINDOWS/ANDROID/HTML` 枚举列表
  `supportedPlatforms`。运行时、WebView 权限和开发者自检统一按当前平台列表门控；
  项目创建/修改弹窗只展示列表中的支持平台。游戏包的能力 code 声明及既有
  `playmesh.app.platform` 协议值不变。
- App bootstrap 不再预探测任何能力、硬件或原生服务。`sensor.pose6d` 只在网页实际
  创建能力实例时启动 ARCore，安装、设备支持和 Session 创建错误直接返回。开发者
  一键自检统一改为 `create({})` 后立即 `dispose()`，创建失败即自检失败。
- Developer API 的能力描述符继续使用 `3.0.0` 阶段引入的
  `supportedPlatforms`，Developer CLI 的能力选择只输出列表中支持的平台；本轮又因
  新增开发资源会话契约整体升级到 `4.0.0`。
- 新增动态权限声明、权限重置及加入端跨平台权限接线回归测试；全量
  `flutter test` 共 324 项通过，`flutter analyze lib test` 无问题，
  `flutter build apk --debug` 构建成功。摄像头、麦克风系统弹窗及 Windows WebView2
  行为仍需目标平台真机/实机验收。
