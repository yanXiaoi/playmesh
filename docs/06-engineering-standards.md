# 工程开发规范

## 目标

Playmesh 的开发必须满足四个目标：

- 可复用：通用能力只有一份实现，页面、Go 服务、Game SDK 和游戏包不重复造轮子。
- 可回溯：一次用户操作可以追踪到页面、协议、服务端、游戏和日志。
- 可验证：每个重要行为都有对应的单元测试、集成测试或手工验收步骤。
- 可演进：协议、游戏包和 SDK 具备明确版本，所有改动同步更新实现、契约、模板、测试和文档。

## 开发期变更原则

当前处于软件开发期，不是已发布产品的迭代期。新版本修改不兼容旧版本内容，不保留旧接口、旧路由、字段别名、迁移适配器、废弃入口、历史模板或不可达代码。技术决策变化时直接替换现实现，并同步删除失效的代码、资源、测试和当前文档；不得以“可能兼容旧版本”为理由保留双实现。历史阶段文档只记录事实，不参与运行时，也不能成为保留历史代码的依据。

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
  entries.game（默认 app/index.html）-> Player Runtime + 条件初始化 Authority Service -> Game SDK
  entries.controller（默认 app/controller/index.html）-> Player Runtime -> Game SDK
  Shared Data -> types/constants/pure functions only
```

各层职责：

- UI 只负责展示状态和传递用户意图，不直接拼接 HTTP、WebSocket 或本地文件路径。
- Application Service 编排一个完整用例，例如创建会话、加入会话、启动游戏。
- Repository/Client 负责外部通讯和持久化，不包含页面业务判断。
- Domain 负责用户、游戏声明、会话、玩家和输入事件的规则。
- Go Handler 只负责解析请求、鉴权、调用服务和生成响应，不直接修改会话内部状态。
- Game SDK 是游戏访问平台能力的唯一入口，游戏页面不直接调用 Flutter、Go、原生桥接或任意端口。
- 游戏分享运行时采用严格的最小公开面，只允许提供 `/app/**`、`/bucket/**`、`/playmesh/**`，以及 SDK 在浏览器沙箱内确实无法替代的受控底层连接能力（例如当前游戏受控的 WebSocket Upgrade）。该清单是完整公开边界而非接口示例。新增平台功能时必须遵循“SDK 优先”原则，优先修改 Game SDK 或 App Bridge SDK，不得为接入便利新增分享 HTTP 业务接口；只有确属连接或传输层的能力才可增加底层入口，且必须固定绑定当前游戏和会话、在建连前鉴权、禁止任意目标地址，并同步补齐协议文档与回归测试。
- SDK 分为权威主机运行时 `playmesh.js` 与 App 本机桥接 `playmesh-app.js`。前者负责会话、联机和主机存储；后者只负责当前 App 的身份与本机能力，由 App 自动注入，不得持久化游戏能力授权。Console 必须由 WebView/浏览器宿主在底层捕获并只保留在当前设备，禁止经 SDK 或游戏网关跨设备转发。普通浏览器不得加载 App SDK，主 SDK 必须提供安全的 `playmesh.app` 空实现。
- 游戏可以自带引擎或工具库，但必须放在自己的游戏包内并通过包校验流程管理；不得因为使用第三方引擎而绕过 SDK 的身份、存储和联机边界。
- SDK 不额外设计启动回调，页面脚本执行就是启动；必须提供 `onPause`、`onResume` 和由 App 主动触发的 `onExit` 生命周期接口。
- `onExit` 只作为退出前的最佳努力通知，必须幂等、有超时，不能作为唯一的数据持久化时机；重要数据应在状态变化后及时保存。
- 游戏库采用“目录扫描优先”原则：游戏包导入后由 App 自动扫描、校验和建立索引，不增加开发者注册步骤；索引失效时可以从目录重新构建。
- 游戏自定义数据必须通过 `playmesh.storage.getBucket(bucket)` 持久化。JSON 值存放在 `packages/{gameId}/data/json/{bucket}.json`；`upload(file)` 写入 `packages/{gameId}/data/data/{bucket}/{timestamp-ms}.{ext}`。不能写入游戏包目录或直接操作文件系统。
- 平台只按 `gameId + bucket` 选择上述目录，不得自动增加 `{userId}` 层。游戏需要区分用户时，由开发者在 Bucket、key 或 JSON 内容中自行设计。
- Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`；SDK 在调用前校验，Flutter 存储层在落盘前再次校验。点号、空白、斜杠、反斜杠、非 ASCII 字符和前导下划线/连字符都不允许。
- `getData`、`setData`、`removeData` 和 `clearData` 默认操作宿主内存缓存，App 按固定时间窗口或脏数据阈值批量持久化，不能每次 API 调用都写磁盘。游戏不提供 flush 接口；WebView 重启、退出或会话关闭前由 App 等待最终落盘。`upload(file)` 使用原始请求体流式写盘，不允许 Base64 或 JSON 包装，单文件上限为 256 MiB。
- 持久化数据的唯一落盘端是开始游戏的 Authority 主机。Authority WebView 直接访问主机存储服务；普通浏览器和其他 App 玩家统一通过权威 Game SDK 及当前受控 Session WebSocket 的存储 RPC 路由到 Authority，不得为存储恢复 `/api/storage` 等分享 HTTP 业务接口。浏览器 `localStorage` 不得保存游戏 Bucket，加入设备不得创建自己的数据副本。
- `packages/{gameId}/app/` 是 WebView 静态映射根。运行时只把 `data/data` 中的文件映射为不可枚举的 `/bucket/{bucket}/{timestamp-file}`；`data/json` 始终私有，任何资源服务、路径拼接和预览接口都必须拒绝访问或穿越到该目录。
- 当前游戏的 `app/` 只通过 `/app/...` 暴露；SDK、平台头像等公共资源统一放在 `playmesh-library/public/` 并通过 `/playmesh/...` 暴露。游戏不得以相对路径越出 `app/`，也不得读取其他游戏包。
- 游戏详情页清除缓存/数据和删除游戏必须调用统一的数据清理流程；数据清理必须有用户确认、日志和明确的不可恢复提示。
- 原始压缩包只存在于导入和分享的临时生命周期内，安装库不长期保存压缩包；分享包由已安装目录临时生成。
- 平台不随构建产物内置游戏 Demo。工作区新建项目和用户导入项目统一进入 `packages/{gameId}/`，使用同一套扫描、校验、索引、运行和删除流程。
- `tags` 是开发者自定义显示数据，平台必须原样保存和展示，不得擅自翻译、重命名或限制标签集合；仅在渲染时使用安全文本方式，不能把标签当作 HTML/脚本执行。
- Player Runtime 和 Authority Runtime 必须分层。玩家页面只负责展示和提交动作，权威运行时只负责验证和产生权威结果；二者不得通过页面全局变量共享可变状态。
- `shared` 代码只能是无副作用的纯数据层，不能借此绕过 Player/Authority 边界。
- `app/index.html` 必须预先引入 authority service，但只能在 `playmesh.session.isAuthority()` 为真时初始化监听；`app/controller/index.html` 不初始化 authority service。
- 权威处理端不得操作 DOM、创建 WebSocket、读取控制器输入元素或依赖某个页面是否打开。
- 联机项目必须从平台默认模板创建，模板负责 SDK 接入、身份注入、动作路由和目标分发；AI 或开发者只修改明确标记的规则区和 UI 区。
- 默认模板的 SDK 接入区不得被游戏代码复制或重写。若需要调整协议，必须同步修改 SDK、模板、契约和校验器，而不是让单个游戏自行改变路由。
- 默认模板必须在 `app/index.html` 中完成 `isAuthority()` 判断，并在权威时注册 `authority.onService()`；必须在 `app/controller/index.html` 中完成 `game.onMessage()` 注册。角色判断、WS 接入和处理器注册不应留给 AI 临时编写。
- 模板中的待实现区域统一使用中文 `TODO` 注释，且必须明确标注所属层级和允许修改范围。
- SDK 性能接口只统计游戏主动调用 `playmesh.performance.reportFrame()` 上报的真实完成帧。Canvas/WebGL 游戏应在实际绘制完成处调用；禁止由平台启动独立 RAF 循环猜测游戏 FPS。FPS 和延迟必须由 SDK 在网页内自动渲染，游戏代码不得创建性能组件。
- App 运行时由 App 工具区控制 SDK 性能悬浮层的显示开关；普通浏览器运行时由 SDK 创建可收纳/展开的悬浮组件，并提供昵称修改入口。两种环境都不得重复创建第二套 FPS/延迟 UI。

## 调用链规范

每个跨模块功能都要能写出明确调用链。例如浏览器玩家加入：

```text
浏览器
  -> GET /app/{declared-entry}?channelId=...&token=...
  -> Authority 分享网关返回当前游戏页面与权威 Game SDK 配置
  -> SDK 从 localStorage 读取或生成持久化 playerId，并读取昵称偏好
  -> SDK 直接调用受控 Core Join 能力
  -> Go JoinService
  -> 校验 playerId 没有在线连接；掉线身份可重连
  -> 签发短期浏览器凭证
  -> Game SDK 建立受控 Session WebSocket
  -> 游戏页面通过 onPlayerJoin/onPlayerLeave/onPlayerReconnect 收到连接事件
```

新增功能时必须补充：

1. 入口是谁调用的。
2. 中间经过哪些模块。
3. 数据模型如何变化。
4. 成功和失败如何返回。
5. 日志中如何定位这次调用。
6. 哪些测试覆盖这条链路。

跨层调用禁止绕过中间层，例如 UI 不直接操作 Go 会话对象，游戏页面不直接访问 Go HTTP 端口。

## 可复用代码规范

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

## 数据和协议规范

- JSON 字段使用明确、稳定、可读的命名；同一概念只能有一个字段名，例如统一使用 `sessionId`，不混用 `roomId`。
- 每个跨进程消息必须包含 `type`、协议版本或可推断版本、时间戳和必要的关联 ID。
- 重要请求使用 `requestId`，跨用户操作使用 `sessionId`、`userId`、`playerId` 和 `deviceId` 关联。
- `main.json` 是游戏包定义的唯一入口；字段变更必须更新示例、校验器、文档和测试。
- 页面入口只从 `main.json.entries.game` 与 `entries.controller` 解析，默认值分别为 `app/index.html` 与 `app/controller/index.html`；Authority JavaScript 只从 `authority.entry` 解析。扫描器、校验器、App WebView 和浏览器网关不得各自硬编码另一套入口。
- 对外提供的 SDK、开发者通道和 Go API 必须提供机器可读接口文档；AI 应通过正式 API 契约调用能力，不为单个 AI 客户端编写专用 Agent。
- HTTP 接口使用 OpenAPI，数据、事件和错误使用 JSON Schema；每个接口记录权限、风险等级、幂等性、重试规则和示例。
- `main.json.orientation` 必填且只允许 `landscape` 或 `portrait`；单屏多人还必须声明 `controllerOrientation`，其他模式禁止该字段。WebView 必须按当前页面角色在方向应用完成后创建，进入全屏时把对应方向传到原生宿主，退出游戏后恢复系统方向。
- `main.json.author` 与 `lastModifiedAt` 是平台只读发布元数据。网页、Agent 和 CLI 上传时必须分别以当前 App 昵称和 Unix 毫秒时间戳覆盖，普通 manifest 编辑不得修改；旧包缺失时不得阻断扫描，分别显示“佚名”和“无”，有时间值时按设备本地时区换算。
- `sdkVersion` 用于声明游戏包要求的当前 Game SDK 版本；开发期只接受当前实现明确支持的版本，不能静默降级。
- SDK 使用 `MAJOR.MINOR.PATCH` 标识契约版本，但开发期版本号不承诺向后兼容。
- 协议字段、语义或入口变化时必须升级版本，并在同一次变更中删除旧实现和旧契约。

## 版本与升级策略

后续所有更改都必须先判断影响到哪些可发布组件，并按需升级这些组件的版本号；禁止功能、接口、协议或包结构已经变化，但仍沿用旧版本号。版本号遵循当前定义的 `MAJOR.MINOR.PATCH`：

- `PATCH`：不改变公开契约的兼容性修复、性能修复或实现修正。
- `MINOR`：保持当前主版本兼容的新增能力、公开 API 或可选字段。
- `MAJOR`：删除或重命名公开能力，改变既有字段、状态、数据格式或调用语义等不兼容变更。
- Flutter App 每次形成新的可分发构建时，除语义版本外还必须递增 `+build`；只修改说明文字且不形成新构建时不递增 App 版本。
- 纯文档勘误、阶段归档或未改变执行约束的提示词整理，不单独推动运行时版本；一旦提示词、Schema、Manifest 或 OpenAPI 反映了新的运行时契约，必须与对应组件在同一变更中升级。

版本按组件独立维护，不升级没有受到影响的组件。当前发布版本基线为：

| 组件 | 当前版本 | 版本来源 |
| --- | --- | --- |
| Playmesh App | `1.6.1+8` | `pubspec.yaml` |
| Go Core | `0.2.0` | `go-core/main.go`、`go-core/mobile/core.go` |
| Game SDK | `1.4.2` | `sdk-src/playmesh.ts` 及生成的 JS、类型、Manifest 与 Schema |
| App Bridge SDK | `1.2.1` | `sdk-src/playmesh-app.ts` 及生成的 JS、类型与 App 注入配置 |
| Developer API / OpenAPI | `1.4.0` | Developer Gateway 契约 |
| Developer CLI | `1.1.0` | `dev-cli/`、`playmesh-cli` 文件名、CLI User-Agent 与桌面平台构建规则 |
| Catalog API | `1.1.0` | `/apps/list`、`/apps/download` 与 `docs/catalog-api.md` |
| Core 协议 | `1.0.0` | Flutter/Go health 与会话协议定义 |

当前未发布开发线在 `docs/version/NEXT.md` 维护；当前开发版本为 Playmesh App `2.0.0+18`、Go Core `0.4.0`、Core 协议 `1.2.0`、Game SDK `2.2.1`、App Bridge SDK `2.1.0`、Catalog API `1.4.0`、Relay 协议 `2.0.0`、Developer API / OpenAPI `1.7.0` 和 Developer CLI `1.3.1`，不得继续按上表正式基线生成新项目。

游戏包的 `main.json.version` 同样使用语义版本，并由游戏开发者在发布内容变化时升级；`sdkVersion` 和 `appSdkVersion` 分别声明 Game SDK 与 App Bridge SDK。CLI 在 `push/dev` 前必须以项目 `playmesh/sdk/` 中实际 SDK 文件的内置版本覆盖这两个字段，禁止手工声明与待上传 SDK 不一致的版本。CLI 本地 `app/`、`playmesh/` 必须分别镜像运行时 `/app/`、`/playmesh/`；上传只包含 `main.json`、`capabilities.json` 和 `app/`。CLI `get` 与开发者项目列表是损坏项目的自救通道：只要求 `main.json` 能解析出非空 `id`，不得先执行 Manifest、能力、入口或运行校验，缺少 `app/` 时也要拉取现有内容；`push/dev`、运行、正式导入仍严格校验。CLI 交互式创建不得复制项目创建逻辑：选项从统一能力注册表读取，最终调用 Developer Gateway 的现有项目创建接口，并复用项目包与 SDK 下载链路写入当前空目录。所有 Developer Gateway 整包发布必须经过开发者本地历史事务，Agent/CLI 不得绕过；整包恢复覆盖 `main.json`、`capabilities.json` 与 `app/`。开发者工作区禁止通过普通文件接口写入 `main.json`，只允许可视化项目设置和受校验的 manifest API 更新；`id`、`author` 和 `lastModifiedAt` 始终不可修改，其他字段经完整清单校验后可保存。所有包导入、导出和下载中转使用按入口固定命名的临时 ZIP，操作前覆盖旧文件、完成后删除；并发请求必须串行，禁止按次数生成永久累积的随机中转文件。

Game SDK 与 App Bridge SDK 的唯一手写源分别是 `assets/playmesh-library/sdk-src/playmesh.ts` 和 `playmesh-app.ts`。正式构建先执行 `tool/generate_sdk.ps1`，生成 `public/sdk/v1/` 下的 `.js`、`.d.ts` 以及 Dart 版本常量；运行时注入、IDEA 类型提示、Developer Gateway 下载和版本校验只能使用这些生成产物。一次版本变更必须同步更新代码常量、默认模板、机器契约、编辑器补全、测试断言和开发文档，并在版本或验证记录中写明升级原因。App、SDK、默认骨架、示例契约、AI 提示词和项目校验器始终只维护一套当前版本；版本升级后，不提供旧 SDK 入口、兼容矩阵、字段适配、自动迁移或双写逻辑。

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

日志禁止记录长期 token、完整头像文件、摄像头画面、传感器原始敏感数据和用户未公开的资料。输入事件可以记录摘要，调试原始数据必须显式开启。

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
- 修改 HarmonyOS/OpenHarmony 工具链、能力或打包链：同步更新 `harmony-release.md`、`01-architecture.md`、`version/NEXT.md` 和相应 `verification/` 记录。
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
- SDK 必须在浏览器环境统一提供昵称修改悬浮入口，使用当前玩家凭证更新会话；App WebView 不显示也不需要该入口。
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

## 能力插件与高频传感器

能力宿主采用有状态实例协议，不把所有能力约束为订阅。公开桥接命令固定为 `app.capability.create/invoke/dispose`，异步输出固定为 `app.capability.event/error`；公开 SDK 通过 `playmesh.app.capabilities.create()` 返回 `invoke/on/onError/dispose` 实例。具体方法和事件由插件 `apiVersion` 定义，录音、语音转写等能力可以要求用户主动调用 `start/stop`。

高频传感器由对应插件负责正常使用体验，游戏代码不直接处理原生采样：

```text
capabilities.json：声明 sensor.accelerometer / sensor.gyroscope
  -> SDK 初始化：App/浏览器每次展示能力确认，拒绝则退出
  -> capabilities.create(code, {fps})：创建实例
  -> instance.invoke('start')：启动插件
  -> instance.on('reading')：接收采样

capabilities.json：声明 device.vibration
  -> capabilities.create('device.vibration', {})：创建实例
  -> instance.invoke('vibrate', {style})：主动触发一次反馈
  -> instance.dispose()：释放实例
```

当前加速度计与陀螺仪各自位于独立插件目录，插件 API 版本均为 `1.0.0`，方法为 `start/stop`，事件为 `reading`。内部每种传感器只建立一条原生流，原生采样频率取该插件全部运行实例请求频率的最大值；最后一个实例停止、页面重载或退出时必须释放原生流。频率范围为每秒 `1` 至 `120` 次。

能力 ID 与提供方解耦，后续摄像头、麦克风等能力可以由 App 原生适配器或浏览器标准 API 提供。当前局域网浏览器分享使用 HTTP，加速度计、陀螺仪和震动只由 App SDK 提供；普通浏览器将这些原生能力标为暂不支持，但用户同意后仍可进入游戏，游戏不得把原生能力设为不可降级的主流程前提。震动插件不建立持续采样流，工作区自检也不得主动制造副作用。

## Authority Client 与 Go Core 边界

Go Core 只做通用中转，不承载任何具体游戏规则。创建会话时必须把当前 App 游戏运行端明确写入 `authorityClientId`；后续加入者不能自行成为 Authority。`single_screen_multiplayer` 中 App 主机不进入 `players`；`multi_screen` 中 App 主机可同时作为 Player 并计入人数，但 Authority 判定不得依赖玩家数组位置或加入顺序。

游戏包可以按需使用 `app/static/js/service/` 目录或 `service.js` 入口组织上述权威逻辑，此目录和文件名是推荐约定，不是强制目录。该逻辑应在 Authority Runtime 中执行，不应被 Go Core 直接解析。SDK 应提供当前客户端角色、`authorityClientId`、玩家成员快照、Authority 连接状态和权威状态版本号；大屏公共显示端的当前玩家必须为 `null`。

每个多人游戏运行时最多由 SDK 管理两条物理 WebSocket：原有 Session WS 负责 JSON 会话、权威动作和状态同步；Binary WS 在首次调用 `playmesh.binary` 时按需创建，复用当前会话凭证，并在游戏退出、Session WS 断开或 Authority 退出时由平台统一释放。游戏代码和 `service.js` 不得直接创建、保存或操作任何 Core WebSocket。

一条 Binary WS 复用多个逻辑 Channel，Channel ID 同时是加入令牌。只有 Authority 可以创建和关闭 Channel，创建后 Authority 自动加入；其他玩家只能凭 ID 加入。`playmesh.binary.authorityPlayerId` 固定为 `"authority"`。所有参与方统一使用 `send(targetPlayerId, data)` 单发、`send(targetPlayerIds, data)` 多发、`send(data)` 广播；`sendLatest(targetPlayerId 或 targetPlayerIds, data)` 发送定向最新帧，`sendLatest(data)` 发送最新广播，不增加 Authority 专用发送签名。

Channel `mode` 只有 `authority` 与 `relay`。`relay` 直接转发原始字节；`authority` 中非 Authority 消息先交给 Authority 的 `onForward`，其上下文始终提供去重后的 `targetPlayerIds` 数组，一次多目标发送只审核一次；返回 `void` 原样通过、返回 `Uint8Array` 替换后通过、抛错则拒绝。Authority 自己发送时直接投递，不能再次进入审核形成循环。带目标的 `sendLatest` 只替换同一 Channel、发送者和规范化目标集下尚未发送或尚未开始审核的旧帧，单参数 `sendLatest(data)` 对广播做相同合并；Authority JavaScript 处理器一旦开始执行，旧新审核都必须继续并各自处理结果。

权威处理函数通过 `playmesh.authority.onService` 注册，返回目标玩家 ID 列表：一个 ID 表示定向回复，多个 ID 表示回复多个玩家，当前所有在线玩家 ID 表示广播，空列表表示不发送。Go Core 根据目标列表执行路由，但不参与游戏业务判断。游戏逻辑只能使用 SDK 注入的 `playerId`、角色和成员快照，不能使用或伪造底层连接对象。`onWs` 不属于普通游戏开发 API。

SDK 必须负责连接级协议分发，开发者负责业务层消息处理和权威目标声明。普通玩家默认模板只暴露 `playmesh.game.onMessage(handler)`；权威模板必须暴露 `playmesh.authority.onService(handler)`，允许处理函数返回 `targetPlayerIds` 和 `payload`，从而定向回复一个或多个玩家、广播给当前成员或返回空列表。开发者不能根据玩家 ID 查找连接、直接实现广播、重复分发消息或直接调用底层 WS。未来的 `game.on(eventType, handler)` 只能是普通玩家端 `onMessage` 的本地语义化封装。

Go Core 只校验连接、会话、角色、凭证、消息格式、大小、频率和基础序列，不判断动作在具体游戏中是否正确。所有玩家动作由 SDK 注入真实会话身份后路由到权威服务入口；普通玩家不能直接发布权威状态。MVP 权威玩家断开后暂停或结束对局，不自动选举新权威；权威迁移必须另立协议并补充测试矩阵。

不建议将游戏 `service.js` 直接嵌入 Go Core：这会使 Go Core 依赖某个 JS 引擎，且必须额外处理脚本沙箱、死循环、内存、异步模型、跨平台打包和恶意游戏包。若未来确实需要独立进程级服务器，应优先评估受限 Node.js/QuickJS 服务进程或 WASM 服务运行时，但它们属于后续架构，不能作为第三阶段前置条件。

### 权威链路性能规则

权威链路允许存在 SDK、App 中转和 Go Core 转发，但不得把所有数据都按同一可靠等级处理：

- 答题、跳过、准备、开始和结算确认属于可靠动作，必须有序进入权威服务。
- 传感器采样、动画帧和连续摇杆值属于状态流，由 SDK 限频、合并并允许丢弃旧值。
- 权威服务只广播必要的状态变化或固定频率快照，不重复广播未变化的大对象。
- 权威状态必须带 `revision` 或等价版本号，客户端丢失中间状态后可以请求最新快照。
- SDK 应记录动作从提交到权威确认的耗时，便于区分本机 JS 处理、App 桥接、Go 转发和局域网传输问题。
- Binary WS 单帧上限为 4 MiB，单次定向发送最多 1024 个去重目标，单连接允许每秒 2000 帧和 64 MiB 入站流量，出站队列上限为 32 MiB，每局最多 1024 个 Channel；Authority 审核最多挂起 1024 项或 128 MiB，单次审核 15 秒超时。这些是局域网防失控边界，不是建议业务速率。多目标 payload 只能上行一次并由 Core 扇出；广播目标由 Core 按 Channel 当前在线成员展开并排除发送者。可靠帧达到上限时必须返回错误，连续状态应优先使用 `sendLatest` 合并尚未发送的状态帧。

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
