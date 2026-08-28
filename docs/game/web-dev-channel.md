# 网页开发者通道规格

## 目标

第四阶段提供一个运行在局域网浏览器中的游戏开发者工作区。它不是普通玩家入口，而是开发和验证 Playmesh 游戏 SDK 的工具。

App 端不维护独立文件编辑器。从首页进入“制作游戏”、开启开发者模式并展开“源代码开发”后，可使用内置 WebView 打开同一个响应式工作区；电脑端和 App 端共享文件修订、Diff、历史、运行状态、SSE 事件及 Console 日志。

工作区页面、样式、脚本、CodeMirror 和默认项目骨架统一位于 `playmesh-library/public/developer/`。Dart 网关只负责鉴权、静态资源装载和 API/SSE，不内嵌页面模板或项目骨架。

工作区是 App 界面的一部分，语言跟随 App。全部静态和动态显示文案都由 App 当前
locale 的 `app.json` 提供，Developer Gateway/内置 WebView 只传递已经解析 fallback
的 `locale + messages`；App 切换语言后，已打开工作区即时更新。工作区不会另外保存
语言偏好，也不维护独立的中英文词典。API 路径、机器错误 code、游戏源码和日志原文
保持不翻译。

用户必须先从 App 首页进入“制作游戏”并主动开启开发者模式，再选择“源代码开发”或“可视化开发”。开发者网页通道只在开发者模式有效，关闭后立即失效。

开发者 Gateway 使用独立监听端口，不修改 Go Core 的动态端口。按当前产品决策，Gateway 绑定 `0.0.0.0`；“制作游戏”页默认端口为 `16666`，用户可以修改，并只展示当前设备解析到的局域网 IPv4 链接。端口被占用或无权限时必须显示明确错误，不得重启 Core 或中断当前游戏会话。“制作游戏”页展示的开发者地址、文档地址和游戏分享地址都必须支持长按或拖选复制。

## 开启流程

```text
App 首页 -> 制作游戏
  -> 开发者模式开关
  -> 源代码开发 / 可视化开发
  -> Go Core/本地服务启动开发者通道
  -> 首次生成或加载持久 token
  -> 首次生成或加载持久工作区路径
  -> 展示完整访问地址和二维码
  -> 浏览器输入地址
  -> token 校验
  -> 进入网页开发者工作区
```

示例地址：

```text
http://192.168.1.10:16666/dev/7f4c.../workspace?token=...
```

实际实现中 token 不应只依赖 URL 路径；服务端应同时校验 token 和当前开发者模式状态。端口、token 和工作区路径构成持久工作区身份，关闭开发者模式或 App 退出时链接暂时不可访问，重新开启后恢复同一链接。

### Android 后台与锁屏

Android 开启开发者模式时必须启动 `specialUse` Foreground Service，并由该服务持有当前 App 的同一个 FlutterEngine。服务期间使用 CPU WakeLock 与高性能 Wi-Fi Lock，使 Developer Gateway 在切换到其他 App、Activity 被系统回收或设备锁屏后仍能处理局域网请求。系统必须持续披露前台服务：取得通知权限时显示常驻通知；Android 13 及以上若用户拒绝通知权限，系统仍会在 Foreground Service 任务管理入口披露。通知渠道名、渠道说明、标题和正文只从当前 App `app.json` 的 `platform.android.developer_service.*` 投影取得，原生层不维护 `strings.xml` 副本或可见中英文 fallback；端口保持独立整数参数，只替换正文中的 `{port}`。App 固定语言或跟随系统语言发生变化时，运行中的服务立即用同一端口刷新通知。关闭开发者模式时同步停止服务并释放两个锁。

后台可用接口包括状态、项目与文件读写、Diff、本地历史、校验、文档、日志、事件、包操作和停止当前运行。需要真实 Activity/View 的操作必须在统一操作定义中声明 `requiresForegroundView=true`；当前包括启动项目、重启项目、执行 WebView JavaScript 和运行平台能力自检。App 位于后台、设备锁定、屏幕关闭、Activity 不存在或窗口失焦时，这些操作返回 HTTP `409`：

```json
{
  "requestId": "dev-...",
  "error": {
    "code": "app_view_unavailable",
    "message": "设备已锁定，当前操作需要可见且可交互的 App 页面",
    "details": {
      "requiresForegroundView": true,
      "available": false,
      "reason": "device_locked",
      "activityAttached": true,
      "activityResumed": false,
      "windowFocused": false,
      "screenInteractive": false,
      "deviceLocked": true
    }
  }
}
```

`reason` 只允许 `foreground`、`device_locked`、`screen_off`、`app_backgrounded`、`activity_unavailable` 或 `window_not_focused`。`GET /dev/api/status` 始终可用，并通过 `appView` 返回同一状态模型。后台限制必须先于危险操作审批执行，避免为当前必然无法执行的 WebView 操作请求无效审批。

## 网页工作区

工作区至少包含：

- 顶部只保留项目、运行、保存、AI 开发和“更多”五个入口。移动端项目选择具有 `120px` 最小宽度，四个操作按钮保留固定可点击宽度；一行不足时允许响应式换行，由项目选择独占第一行，四个操作按钮均分第二行，禁止继续压缩任一入口。空间足够时仍保持单行，尽量把纵向视口留给项目树和代码。对话控制台、WebView JS 操作台、新建文件、重启、停止、校验、文件 Diff、删除文件和数据清理统一收纳到“更多”下拉菜单。
- 项目入口与“更多”都使用 IDEA 风格的锚点下拉菜单，按触发按钮的实时视口位置展开，不使用整页选择弹窗或固定坐标。项目菜单聚合新建项目、复制当前项目、项目设置和删除项目，列表可按项目名、ID 或版本搜索；网页只在当前 Developer Gateway 源的 `localStorage` 记忆最近项目 ID。重新打开时仅在该项目仍存在时自动选择；不存在或没有记录时打开项目选择器，不回退到 App 活动项目或列表首项。新建联机项目默认显示模式为 `multi_screen`（多人多屏）。
- 复制项目以当前项目为来源，新项目名称和 ID 均可修改；源码、清单和公开资源进入副本，项目根目录的 `data/`、`cache/`、`.playmesh/` 不复制。`author` 发布者元数据使用当前 App 用户昵称；普通项目设置不允许修改稳定 `id`、`author` 和 `lastModifiedAt`。复制操作通过创建新项目提供变更 ID 的正式入口。删除项目会删除源码、运行数据、缓存和本地历史，必须在项目未运行时二次确认。
- IDEA 风格项目文件树和 `main.json` 原文只读查看区；项目设置提供可视化清单编辑和可增删的标签输入。设置页同时可视化编辑同级 `capabilities.json`，全部取消时删除该可选文件。源码工作区在新建项目和现有项目设置中都提供“Web Runtime 多线程”；新建默认关闭，现有项目缺少配置时也显示关闭。每次保存都以界面当前值更新 `config.webRuntime.multithreading`；当 `config` 及 `webRuntime` 为对象时保留其中其他不透明字段，无法合并的旧值由最新标准对象结构替换。
- 能力选项必须由 `GET /dev/api/capabilities` 返回的统一插件注册表动态生成，展示中文名、用途、`apiVersion`、方法、事件以及 App/HTML 是否已适配，不在网页中硬编码传感器列表。
- “更多 → 能力测试”始终展示全平台注册表，不按当前项目的 `capabilities.json` 过滤。`GET /dev/api/capability-tests` 读取插件自检清单；`POST` 省略 `codes` 或传空数组时测试全部插件，也可指定 code，并用 `timeoutMs`（250～10000）控制单项创建等待时间。一键自检只用默认参数调用真实 `create({})`，成功后立即 `dispose()`；创建或释放失败即报告失败，不调用独立硬件探测接口。工作区持续调用并回显插件版本、状态和耗时，直到用户手动关闭测试窗口。
- 新建项目弹窗与项目设置都必须提供标签和能力编辑。新建请求的 `tags` 写入 `main.json.tags`；`requiredCapabilities` 写入主画面 `required`，单屏多人的 `controllerRequiredCapabilities` 写入控制器 `controllerRequired`，任一非空时创建 `capabilities.json`。
- 编辑器文件标签栏右侧提供“复制文件”操作，复制 CodeMirror 中当前显示的完整文本（包括尚未保存的编辑），便于直接发送给 AI；图片和二进制文件禁用该操作。手机端按钮缩写为“复制”并固定保留在编辑视图内。
- 在项目树点击文本、图片或其他文档后，工作区必须自动切到编辑区；文本文件同时聚焦编辑器。
- 项目树目录右键菜单支持新建文件、新建文件夹、删除文件夹和向当前目录多选上传文件，也支持把本机文件直接拖到根节点、文件夹或文件节点上传；拖到文件节点时使用该文件所在目录。文件右键支持删除。空文件夹必须保留并参与 SSE 同步，上传单文件上限为 2 MiB。
- 项目根目录、文件夹和文件右键均可打开本地历史。本地历史只保存一份初始基线和每个时间操作的变更后快照；上一操作的变更后快照即下一操作的变更前版本。每次文件或目录变更更新当前快照，连续活动在 5 分钟滚动窗口内合并为一个时间操作，最多保留最近 100 个操作。清理最老操作时必须先将其快照提升为新基线。
- 本地历史存储在当前游戏包根目录的 `cache/developer/local-history/`，与 `app/`、`data/` 同级。快照只包含 `main.json`、可选 `capabilities.json`、可选 `icon.png` 与 `app/`，不复制 `data/` 或 `cache/`；普通项目树和文件 API 不展示或修改 `data/cache`。CLI 本地开发副本中的 `playmesh/` 不属于安装内容或历史快照。清理游戏缓存会同时清除本地历史。
- 本地历史按时间操作展示资源新增、修改、删除、文本前后内容、增删行数与二进制大小变化。文本文件使用左右双栏 Diff，左栏可切换该操作的变更前或变更后版本，右栏始终是当前工作区；用户既可以只把某一个差异块应用并保存到当前文件，也可以用整次恢复全量替换选中文件、文件夹或整个工作区。恢复前必须自动生成独立且不参与后续合并的历史操作；恢复整个工作区时继续保留平台管理的当前 `main.json`。
- HTML/CSS/JavaScript 编辑区。编辑器提供 HTML 标签/属性、CSS 属性/值、JavaScript 和 `playmesh` SDK 方法补全；可用 `Ctrl+Space` 或 `Alt+/` 主动触发。
- 开始、重启与停止操作；由 App 启动当前游戏，不在工作区嵌入主页面预览。重启只作用于当前 App 中运行的该项目实例，并保留已有联机码和分享链接；停止会关闭会话并返回游戏库。
- WebView JS 操作台复用 JavaScript CodeMirror 编辑器，执行按钮调用 `POST /dev/api/projects/{projectId}/webview/javascript`，下方原样显示结构化求值结果或错误。最近 30 次代码、返回和时间仅按项目保存在当前页面内存，可在本次会话重新载入；刷新或关闭页面后丢弃，既不写浏览器持久存储，也不是游戏 Bucket 或项目历史。
- 游戏运行状态、分享二维码和可复制链接。普通多人多屏与单机分享加载显式声明的
  `entries.game`，单屏多人分享加载同样显式声明的 `entries.controller`；清单入口
  始终相对于物理 `app/`，缺失不回退，单机分享不加入 Session、不创建玩家且不建立
  WebSocket。
- 运行状态使用 `run.status` SSE 即时同步；内置 WebView 从游戏页返回后必须重新确认当前状态，不能继续显示已经退出的游戏仍在运行。
- 由工作区启动的游戏在菜单中提供按需开启的调试日志面板。日志由当前页面的 `playmesh-app.js` 拦截，只包含当前终端的 `console` 输出，不通过 Game SDK、Session 或游戏网关转发其他设备日志；普通浏览器也可使用自身开发者工具查看本机 Console。
- App 不依赖日志面板是否打开，始终在内存中缓存最近 500 条本机 WebView 日志。工作区与游戏内日志层均提供一键复制最近日志。非流式 AI 可通过 `GET /dev/api/logs?limit=50` 按时间顺序读取最近最多 50 条，无需消费 SSE。
- SDK API、角色语义、参数、返回值、错误和数据类型 Schema 面板。
- 纯聊天 AI 提示词固定导出为 UTF-8 BOM TXT，并按当前 `main.json.modes/displayModes` 只包含相关 SDK 函数契约、拓扑、强制文件和源码。能力上下文只附带当前 `capabilities.json.required` 已勾选能力的完整插件声明，不暴露未勾选的平台注册能力；普通多屏不得混入控制器，单机不得混入 Authority，单屏多人必须包含控制器与 Authority 数据链。项目校验结果不混入提示词，校验弹窗可独立复制包含诊断码、路径行列、消息和修复建议的详情。
- 主工作区的“AI”按钮直接进入统一 AI 开发页。API 接口、鉴权和 AI 可用性文档作为只读项与公共、游戏模式、显示模式模板位于同一棵树中；公共分类额外提供“自定义想法”，用户填写的玩法、视觉和交互要求同时加入对话与 Agent 最终提示词。模板支持独立保存覆盖、恢复系统默认；醒目的“获取项目提示词”集中提供两类最终文本的切换、复制和 TXT 下载。“复制全平台能力”会单独调用平台注册表 API 并复制全部完整声明。切换到 Agent 提示词时会枚举当前设备的 HTTP Base URL，用户应选择电脑端 AI 能访问的局域网地址；Agent 文本不内嵌全平台注册表，而是写入带所选 Base URL 的全量能力注册表 API 与 GET/POST 能力测试 API，供 Agent 按需读取和执行。
- 事件流、结构化错误、权限、连接状态和 Console 日志。
- 单机、普通多屏和单屏多人所需的 SDK、角色和数据流契约。
- 游戏包校验和开发副本临时加载。
- 保存、运行、重新加载和清理临时项目。
- 完整接口文档入口和 API 调试入口。

开发者网页本身也应通过 SDK/开发者通道 API 与 App/Go Core 通讯，不让页面直接猜测内部 WebSocket 帧格式。

文件 Diff 和本地历史使用 Git 风格左右双栏。AI 多文件修改改用对话控制台的结构化 `file-changes/preview/apply`，按 `baseRevisions` 原子应用；旧快速操作文本与对应预览面板不再保留。二进制、目录、过大或被截断的内容不开放块级应用，只提供元数据和原有整次恢复能力。

`validateProject()` 与 `projects.validate` Operation 必须保留，既有 AI 提示、本地运行和
安装包导出的校验要求不变。只有“导出 → 上传到发布源”不得调用项目校验，它保存当前编辑
内容后直接进入宽松包的多源上传流程。

## 机器可读接口文档

网页开发者通道必须暴露完整接口文档，目标使用者包括网页工作区、外部脚本和 AI。接口文档不是只给人看的 Markdown，而是可直接被程序读取的正式契约。

至少提供：

```text
/dev/docs                 人类可读 API 文档
/dev/openapi.json         HTTP API 的 OpenAPI 文档
/dev/schemas/             请求、响应、事件和错误 JSON Schema
/dev/sdk-manifest.json    Game SDK API、版本、权限和约束
/dev/examples/            可直接执行的接口请求示例
```

文档必须覆盖项目、文件、游戏包、校验、运行、SDK、事件、日志、错误、权限、重试和幂等规则。每个接口至少提供请求、响应、成功示例、失败示例和权限要求，并与实现同步校验。

## AI 直接调用流程

第四阶段不为某一个 AI 编写专用 Agent。AI 通过接口文档自行发现能力，并使用持久开发者工作区 token 调用 API：

```text
AI 获取 /dev/openapi.json、/dev/sdk-manifest.json 和 JSON Schema
  -> 读取当前项目和 main.json
  -> 调用项目、文件、校验和运行 API
  -> 读取结构化日志和错误
  -> 修改代码并重新运行
  -> 读取运行状态、SSE 和 Console 日志定位问题
```

AI 应优先使用高层开发者 API，例如“创建项目”“修改文件”“校验项目”“运行项目”和“读取事件”，而不是自行构造 Go Core WS 消息。所有 API 返回稳定的 `requestId`、成功结果或结构化错误。

清单和能力声明使用专用高层接口：`GET/PUT /dev/api/projects/{projectId}/manifest` 读取或修改 `main.json`（请求中的 `id` 必须与当前项目一致），`GET/PUT /dev/api/projects/{projectId}/capabilities` 读取或修改可选能力声明，`GET /dev/api/capabilities` 读取统一能力注册表，`GET/POST /dev/api/capability-tests` 读取或执行平台注册表驱动的能力自检。普通文件写接口继续禁止修改 `main.json`，从而保证稳定 ID 和完整清单校验。

项目级管理使用 `POST /dev/api/projects/{projectId}/copy` 和 `DELETE /dev/api/projects/{projectId}`。复制请求必须提供新的唯一 ID 与名称，发布者取当前 App 用户昵称，并排除源项目的运行数据、缓存和本地历史；删除接口拒绝删除正在启动或运行的项目。两项操作都由 Developer Project Catalog 执行，网页不得直接操作目录。

项目运行生命周期使用四个正式接口：`GET /dev/api/projects/{projectId}/run` 读取当前状态，`POST /run` 开始，`POST /run/restart` 刷新当前运行内容，`POST /run/stop` 停止并关闭当前游戏会话。首次启动会先移除旧游戏路由再创建新的游戏 WebView；刷新只重建当前 WebView 内容并保留现有会话。没有对应运行实例时，刷新和停止返回结构化错误。AI 在非流式调用中应优先轮询 `GET /dev/api/projects/{projectId}/run` 获取状态，并使用 `GET /dev/api/logs?limit=50` 读取诊断日志；SSE 仍用于浏览器工作区的实时体验。

运行控制面统一使用 `projectId + runId`，但资源来源必须保持三种互斥语义，不能按同一 game ID 相互回退：内置源码工作区的 `POST /run` 在服务端重新校验已经原子保存到受管 `packages/{projectId}/` 的项目，并直接以其中的 `app/` 作为实时资源；GDevelop 的 `/preview` 接收完整临时 ZIP，校验后从隔离临时目录运行；外部 CLI/Cocos 先通过 `/development/package` 上传只用于固定清单与能力声明的临时基础包，再由 `/development` 绑定带凭据和有效期的反向代理资源。三者共用状态、停止、重启和 WebView JavaScript 调试链路，但临时资源永不读取或覆盖同 ID 的正式项目。

### 外部 CLI 开发资源会话

外部工程仍由 App 创建和持有正式游戏运行实例，但游戏资源可以临时改由 CLI 代理提供。会话接口为 `GET`、`POST`、`DELETE /dev/api/projects/{projectId}/development`：

- `POST /development/package` 接收并校验临时基础 ZIP，返回一次性 `packageId`；`POST /development` 启动或替换当前项目的开发资源会话，请求体只允许 `resourceBaseUrl`、`credential`、`expiresAt` 和 `packageId`。该操作需要 `runtime.run` 权限、前台工作区视图，风险等级为中且非幂等，成功返回 `202`。
- `GET` 返回会话状态；活动时包含 `active`、`projectId`、`resourceBaseUrl`、`expiresAt` 和 `run`，永不回传 `credential`。
- `DELETE` 停止开发资源会话并结束其临时运行实例；该操作风险等级为中且非幂等。开始普通正式运行、删除项目、关闭开发者模式或退出 App 时同样清除内存会话。

`resourceBaseUrl` 必须是带显式端口的 HTTP 根地址，不允许 HTTPS、用户名密码、非根路径、查询或 fragment。地址中的主机必须与当前请求来源地址一致；仅当两端都为 loopback 时允许回环地址。`credential` 必须匹配 `[A-Za-z0-9_-]{32,128}`。`expiresAt` 是 UTC Unix 毫秒时间戳，必须晚于当前时间且不超过 24 小时；CLI 默认生成 32 字节随机数的无填充 Base64URL 凭据，并创建 12 小时会话。

开发资源路由保持正式运行的 URL 契约：外层物理 `app/` 映射到 Web 根路径 `/`，`/playmesh/**` 与 `/bucket/**` 继续由 App 提供，其余 HTTP 和 WebSocket 请求按原始路径、查询与请求子协议转发到 CLI。用户的 `/app/**` 请求同样按普通原始路径处理，对应物理 `app/app/**`，不会别名到外层 `app/**`；Vite 等开发服务器的模块、资源和 HMR 地址按项目实际路径使用。

CLI 代理监听局域网地址和随机端口，把上游固定到启动时解析出的单一地址并禁用系统代理。App 到 CLI 的每个资源请求都带 `X-Playmesh-Development-Credential`；CLI 使用常量时间比较验证它，在转发到实际开发服务器前删除该头。过期或无效凭据返回 `401`，App 侧已过期资源请求返回 `410`。代理只接受 `GET`、`HEAD` 以及以 `GET` 发起的 WebSocket Upgrade，拒绝 `/playmesh`、`/bucket`、反斜线、目录穿越及编码绕过。App 对普通响应进行流式转发，并透明桥接 WebSocket Upgrade，因而开发服务器的 HMR 不需要定制协议。

持久开发者工作区 token 与上述临时资源凭据是两套身份：前者用于调用 Developer API，后者仅用于一次 App → CLI 资源链路，只保存在内存中，不进入项目清单、日志或返回体。

运行中游戏的顶层 WebView 通过 `POST /dev/api/projects/{projectId}/webview/javascript` 接收非空 `source` 并返回脚本最后一个表达式的 JSON 可序列化求值结果。链路固定为 `Developer Gateway -> DeveloperRunController -> GamePage -> LocalGameWebView/WindowsLocalGameWebView`；移动端使用 `runJavaScriptReturningResult`，Windows 使用 WebView2 `executeScript`。执行前必须同时确认当前活动状态为 `running`、活动项目 ID 与路径 `projectId` 完全一致、该项目仍持有当前 WebView 执行器；不能用其他项目 ID 命中后台页面或旧 WebView。没有匹配的当前 WebView 时返回 404，脚本执行异常返回 `422 javascript_execution_failed`。该接口是 `risk=high`、`dangerous=true`，并进入 Chat/Agent 操作目录；任何带 `X-Playmesh-AI-Channel` 的调用都必须先取得开发者批准。

开发者工作区提供“清理游戏数据”高风险操作，对应 `DELETE /dev/api/projects/{projectId}/data`。接口只删除当前项目的 `data/`，保留 `cache/`、源码与开发历史；游戏处于 `starting` 或 `running` 时返回 `409 game_running`，必须退出游戏后再调用，避免内存中的旧数据被 App 最终写回。

文件编辑能力的权威实现位于 App 游戏库，不属于网页开发者后台的独立实现。网页工作区如需创建文件、保存文件或应用 AI 修改，应调用 App 提供的文件操作 API，复用路径校验、Diff、原子提交和项目级本地历史；网页端不得绕过接口直接访问游戏目录。编辑器内尚未保存的即时撤销/前进由 CodeMirror 自身管理，不提供独立服务端单文件撤销接口。

机器文档必须准确区分三类页面角色：创建并运行会话的 App 主机固定为 Authority Client；单屏多人 App 主机不属于 `players`，普通多屏 App 主机可同时作为 Player，所有加入端都只是 Player。不得通过玩家数组首位、进入顺序或首个输入者推断 Authority。Authority 处理器必须使用 `context.senderPlayerId` 和 `context.members[].id`，不得使用不存在的 `playerId` 字段；主机页面也要接收状态时，目标还必须包含 `context.session.authorityClientId`。Go Core 只转发消息，游戏规则和结果验证由游戏自己的 Authority 逻辑完成。

新建联机项目时，网页开发者工作区必须提供默认代码框架，而不是要求 AI 从空目录开始理解路由。框架至少包含：

- `app/index.html`：主游戏画面模板。
- `app/controller/index.html`：控制器画面模板；具体是否使用由游戏模式决定。
- `app/static/js/player/index.js`：玩家端 SDK 接入和状态订阅模板。
- `app/static/js/service/index.js`：权威 `onAction` 处理模板。
- `app/static/js/shared/types.js`：动作、状态和事件结构模板。
- `main.json`：包含 `displayModes`、玩家人数、`entries.game`、`entries.controller` 和 `authority.entry`。

模板的 SDK 区域负责 WS、身份注入、动作转发和目标分发。默认模板为清单显式写入的
`entries.game` 页面预先引入 service，并在初始化时根据
`playmesh.main.session.isAuthority()` 决定是否注册
`playmesh.main.authority.onService`；为显式 `entries.controller` 页面注册
`playmesh.main.game.onMessage`。AI 只需填写中文 TODO 标记的玩家 UI、权威规则和
共享纯数据。工作区应在文件旁显示每个文件属于“玩家运行层”“权威处理层”还是
“共享数据层”，并将完整调用链和接口 Schema 暴露给 AI。

开发者工作区必须遵守安装库边界：项目发布结构是 `main.json + 可选 icon.png +
可选 capabilities.json + app/`，运行时数据写入同级 `data/`；当前项目的物理 `app/`
映射到 Web 根路径 `/`，平台 `playmesh-library/public/` 映射到 `/playmesh/**`，
Bucket 映射到 `/bucket/**`。`/playmesh` 和 `/bucket` 是仅有的平台保留顶层命名
空间，物理 `app/` 下不得以任意大小写创建这两个根目录。用户首段 `app` 合法：
物理 `app/app/**` 映射到 `/app/**`，且不会把它别名到外层 `app/**`。
预览、文件 API 和 AI 工具都不得以相对路径跨出 `app/`，也不得直接读取 `data/`、
其他项目或 App 私有文件。

接口文档还必须声明每个操作的权限、风险等级、是否幂等、重试规则和是否需要用户确认，方便 AI 在调用前判断。

## AI 调用安全边界

- AI 只能访问持久开发者工作区 token 授权的项目、开发运行状态、事件和文档资源。
- AI 不能读取 App 账号 token、用户私有资料、其他项目或任意文件。
- AI 不能执行任意系统命令；运行操作只能使用预定义的项目构建、预览和测试接口。
- 删除项目、覆盖文件、复制外部资源和停止会话等操作应支持确认或明确的操作参数。
- 所有 AI 请求记录 `requestId`、token 短标识、项目 ID、接口名和结果，不记录完整 token。

## SDK 与 AI 文档能力

网页工作区和机器文档必须完整说明：

- `playmesh.main.*` 游戏域、`playmesh.app.*` 终端域、根 `playmesh.ready` 聚合就绪
  语义、当前玩家、会话快照和三类页面角色。根 `playmesh.ready` 是唯一根级聚合入口，
  只复用 `main.ready` 初始化链并返回 `{ main, app }`；`main.ready` 内部先等待
  `app.ready`。
- `submitAction -> AuthorityContext -> AuthorityResult -> onMessage` 的完整权威数据流。
- 生命周期、主机存储、FPS 上报、浏览器昵称和错误处理。
- 每个方法的签名、参数、返回值、可用环境、角色限制、失败行为和取消订阅方式。
- `main.json`、Player、SessionSnapshot、AuthorityContext、AuthorityResult、LifecycleEvent 和校验报告的 JSON Schema。
- Developer API 的鉴权、路径、请求体、响应体、修订冲突、风险、幂等与重试规则。
- 单机、普通多屏和单屏多人各自所需的 SDK 方法、角色语义与页面拓扑。

工作区项目与用户导入项目使用同一正式已安装资源流程。底层 WS 帧不作为游戏作者或
AI 的开发接口。

## AI 开发入口

后续 AI 开发接入本工作区，AI 必须在同一项目沙箱和 SDK 边界内工作：

- 读取 `main.json`、项目文件和 SDK 文档。
- 根据开发者需求生成或修改游戏代码。
- 通过工作区运行游戏并读取结构化错误。
- 调用项目校验接口并读取结构化文件行列诊断。
- 运行项目后读取运行状态、SSE 和统一 Console 日志。
- 不能访问 App 账号 token、用户私有文件、其他项目或任意系统命令。
- 生成代码必须遵循中文注释规范和游戏包目录规范。

推荐 AI 任务上下文至少包含：

```text
当前游戏包路径
main.json 内容
支持的 displayModes
当前页面角色
可用 SDK API
当前 capabilities.json.required；对话为已勾选能力完整声明，Agent 为全量注册表与测试 API
当前运行角色与项目校验报告
最近一次结构化错误
```

## Token 和网络安全

- 开发者模式默认关闭。
- token 使用高强度随机值，不使用连续 ID、昵称、游戏 ID 或简单时间戳。
- “制作游戏”页允许输入 8 至 128 个字符的自定义 token；首次留空时生成 32 字节高强度随机值，后续留空复用已保存 token。
- 开发者端口、token 和工作区路径持久化到 `playmesh-library/developer/settings.json`，默认端口为 `16666`。该文件属于敏感开发配置，不得加入游戏包、日志或 AI 项目源码。
- App 关闭、重启或用户关闭开发者模式时只停止 Gateway 监听，不删除持久 token 和工作区路径。
- 重新开启开发者模式时恢复同一端口、token 和路径；在设备局域网 IP 未变化时，完整工作区链接保持不变，其他设备可立即重连。
- 用户修改 token 并成功重新开启后覆盖持久配置，旧 token 立即失效；工作区路径保持稳定。
- Gateway 绑定 `0.0.0.0` 以覆盖当前设备全部 IPv4 接口；App 只生成局域网地址。设备存在公网直连接口时必须依赖系统防火墙或网络边界阻止外部访问，后续如需更细粒度限制再增加接口白名单。
- 所有工作区请求都检查 token、来源会话和开发者模式状态。
- 关闭开发者模式或 App 进程退出时现有工作区连接断开；Android 仅切换后台、Activity 回收或锁屏不关闭 Gateway，重新开启后使用持久链接重新连接。Go Core 生命周期不改变开发者工作区身份。
- 日志不记录完整 token，只记录 token 哈希或短标识。

联机游戏分享链接和二维码使用另一类会话 token：关闭分享面板、浏览器玩家刷新和 App 刷新游戏都不撤销；离开游戏、会话结束、App/Core 重启后失效。同一会话重新展示分享信息或刷新游戏时复用原 token，退出后创建的新会话不能复用旧链接或二维码。联机浏览器刷新会读取 `localStorage` 中由 SDK 管理的玩家 ID 和昵称重新加入；运行中的旧连接掉线后可用同 ID 恢复，在线同 ID 的后续连接会被拒绝。单机分享使用独立随机访问 token，只加载显式 `entries.game` 声明解析出的页面及其 HTTP 资源/存储；缺失时直接拒绝，不调用 Core 加入接口。其 Console 只保留在当前浏览器。

开发运行时调用 `playmesh.main.storage` 必须写入当前 Authority 主机的 `packages/{gameId}/data/`：JSON 写入 `data/json`，`upload(file)` 写入 `data/data` 并返回 `/bucket/...`。浏览器开发者工作区不能把游戏 Bucket 保存在浏览器 `localStorage`，其他加入端也不能建立独立副本；只有 `data/data` 通过不可枚举的 Bucket URL 映射，JSON 始终私有。FPS 只能读取当前客户端通过 `playmesh.app.performance.reportFrame()` 上报的数据，不能用工作区自己的 RAF 估算游戏 FPS；`playmesh.main.performance` 不存在。

## 上传后的文件整理

应用游戏库可以直接导入完整 HTML 小游戏 ZIP：有 `main.json` 的包走严格 Playmesh
包导入；没有 `main.json`、但包含 HTML 入口的普通网页 ZIP 进入转换表单，用户确认
游戏信息和入口后迁入物理 `app/`，再复用标准校验与原子安装。转换保留原相对路径、
根 `/assets/**`、外部 URL、未知路由和二进制引用，不做白名单 URL 重写。开发者也
可以在工作区文件树目标目录选择“上传文件”，或把文件直接拖到树的根节点、文件夹或
文件节点继续整理。只有扩展名为 `.zip` 的文件显示“解压 ZIP 到这里”，服务端也拒绝
对其他扩展名执行解压。文件或文件夹平时只显示“复制”和“剪切”；选择复制后，目标
文件夹显示“粘贴到这里”，选择剪切后才显示“移动到这里”。操作时可以修改目标名称。

文件操作统一调用 `POST /dev/api/projects/{projectId}/file-operations`：`operation` 为 `copy`、`move` 或 `extract`，同时传入 `source`、`destination` 和 `clientId`。操作受项目沙箱、路径规范和本地历史保护；不会覆盖同名目标，不能移动必需根目录 `app`，不能修改 `main.json`。ZIP 解压拒绝目录穿越、符号链接、同名项和超限内容，当前限制为总量 64 MiB、最多 2048 个文件、单文件 2 MiB。整理完成后必须执行项目校验。

## 编辑器外部依赖与代码补全

开发者工作区自身使用的前端第三方依赖统一放在 `assets/playmesh-library/public/developer/editor/`，通过该目录内的 `package.json` 与锁文件管理；不得把编辑器依赖散落到游戏模板或 Dart 网关。Flutter 资源清单只声明实际使用的依赖子目录。目前 CodeMirror 核心、语言模式、提示插件、括号插件和 MergeView 均从 `editor/node_modules/codemirror/` 加载；MergeView 的文本差异计算使用同目录锁定的 `diff-match-patch`。

游戏项目自己的浏览器依赖仍属于游戏源码：开发者可上传普通 JS/CSS/字体/图片或 ZIP，在 `app/` 内解压、移动和复制后使用根 URL（例如 `/static/vendor/example.js`）或相对路径引用。平台不会执行项目级 npm 安装，也不会允许依赖越过项目沙箱。

编辑器补全由 CodeMirror hint 插件提供。HTML 注入标签与属性提示，CSS 注入属性和值提示；JavaScript 补全不再维护第二份硬编码 API，而是从当前 Dart 注册表组装的 `playmesh-main.d.ts` 和 `playmesh-app.d.ts` 读取标记。旧 Game 类型文件不兼容、不保留。Game SDK `4.1.0` 与 App SDK `3.4.0` 的运行文件、内置工作区补全、AI 项目提示词和 CLI/IDEA 类型提示均来自 `lib/core/game_sdk/features/` 的同一注册表；`sdk-src/*.ts` 只是正式构建生成的可审阅中间产物。AI 项目提示词嵌入两份完整 `.d.ts`，并明确以其方法、参数、返回值、类型、版本与中文 JSDoc 为唯一接口事实源。运行时以 `/playmesh/sdk/v1/playmesh-main.js` 和平台预先注入的 `/playmesh/sdk/v1/playmesh-app.js` 为权威 URL；旧 `/playmesh/sdk/v1/playmesh.js` 不兼容、不保留。运行前严格要求清单声明受支持的精确版本：Game SDK 只接受 `4.1.0`；App SDK `3.2.0`/`3.3.0`/`3.4.0` 均解析到当前 `3.4.0` bundle。响应内容由 Dart 注册表即时组装；Game SDK 只公开 `playmesh.main.*` 游戏域，App SDK 只公开 `playmesh.app.*` 终端域，唯一根例外 `playmesh.ready` 复用 `main.ready` 初始化链并返回 `{ main, app }`，而 `main.ready` 内部先等待 `app.ready`。普通浏览器中的 App SDK 负责网页覆盖层，原生终端能力 `isAvailable()` 为 `false`。

> **AI 上下文最小披露原则：提示词只暴露游戏代码可调用的公开 SDK、当前项目声明与完成任务所必需的约束。回环代理、内部路由、中转鉴权、密钥协商和加密通道等平台实现不得进入游戏 AI 上下文。**

## 第四阶段完成标准

- App 首页“制作游戏”页可以开启和关闭开发者模式，并选择“源代码开发”或“可视化开发”。
- 开发者 Gateway 默认固定端口为 `16666`，可在“制作游戏”页修改，且不会重启动态端口的 Go Core。
- “制作游戏”页会恢复上次保存的合法端口、token 和工作区路径。
- token 可以自定义；首次留空时安全随机生成，后续留空时复用。
- App 能展示持久工作区的局域网地址、token 和二维码。
- 浏览器能进入工作区并加载项目文件。
- AI 能读取完整 SDK Manifest、OpenAPI、核心 JSON Schema、角色语义和当前项目源码。
- 工作区能创建合法的单机、普通多屏和单屏多人项目，并对修改结果执行结构化校验。
- 能从工作区请求 App 启动主游戏页，并按单机、普通多屏或单屏多人类型提供正确入口的二维码和链接。
- AI 能依据文档完成项目创建、文件修改、校验、运行和日志诊断闭环，不需要理解内部 Bridge 或 WebSocket 帧。
- App 关闭或开发者模式关闭期间地址不可访问；App 重启或重新开启后同一地址恢复服务。
- AI 接入点、项目沙箱和权限边界有文档和测试。
- “制作游戏”页和游戏分享层中的所有链接均可长按或拖选复制。
