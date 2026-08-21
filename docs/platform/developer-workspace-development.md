# 开发者工作区开发约定

开发者入口的共享/独立分层见
`docs/platform/developer-foundation-architecture.md`；GDevelop 完整工程与资源历史合同见
`docs/gdevelop/history-development.md`。

本约定适用于 Developer Gateway、Developer Operation、网页工作区、AI 对话控制台、
Agent API、项目文件与本地历史。游戏作者使用说明见
[网页开发者通道](../game/web-dev-channel.md)。

当前未发布 Developer API / OpenAPI 版本为 `4.3.0`。开发资源会话与外部工程接入变更见
[Playmesh 4.0.0 版本日志](../version/4.0.0.md)；此前统一能力实现见
[Playmesh 3.0.0 本地功能实现说明](../implementation/playmesh-3.0.0-local-implementation.md)。

## 架构

```text
Developer Web Gateway
  -> 请求级中间件
  -> Developer Operation Registry
  -> 操作级中间件 / AI 审批
  -> Resource Operation
  -> Catalog / Run Controller / Capability Service / Package Service
  -> 标准响应、SSE 与本地历史
```

`developer_web_gateway_io.dart` 只负责：

- Gateway 启动和关闭；
- 持久工作区身份对应的监听；
- 公共静态资源；
- 请求级中间件；
- Operation 注册和分发；
- 组合所需平台服务。

业务接口不能在 Gateway 中重新增加 `/dev/api/**` 条件分支。

## Operation Definition 是事实源

每个资源操作位于：

```text
lib/core/developer/operations/{domain}/
```

同一操作文件维护：

- method、path 和稳定 operation ID；
- 摘要与说明；
- path/query 参数；
- request Schema 与示例；
- 成功状态和额外错误响应；
- permission、risk、idempotent、dangerous；
- Chat/Agent 可用性；
- 是否要求前台可交互 View；
- 实际处理逻辑。

注册表从 `definitions` 自动建立路由。OpenAPI、完整操作目录、Chat/Agent 指令和
响应元数据也从同一定义生成，禁止维护静态第二份 OpenAPI。

## 当前完整 Operation 注册表

下表记录 Developer API `4.3.0` 当前注册内容。箭头右侧是稳定 operation ID；运行时
真正用于路由的是“HTTP method + path 模板”，operation ID 用于响应头、OpenAPI、
操作目录、审批和诊断，不参与路径命中。

| 域 | 当前注册操作 |
| --- | --- |
| 状态、UI 与 SDK | `GET /dev/api/status` → `workspace.status`<br>`GET /dev/api/localization` → `workspace.localization`<br>`PUT /dev/api/localization` → `workspace.localization_update`<br>`GET /dev/api/qr.svg` → `workspace.qr`<br>`GET /dev/api/sdk` → `sdk.read_bundle` |
| 文档与 Schema | `GET /dev/docs` → `docs.human`<br>`GET /dev/openapi.json` → `docs.openapi`<br>`GET /dev/sdk-manifest.json` → `docs.sdk_manifest`<br>`GET /dev/schemas/developer-session.json` → `docs.session_schema`<br>`GET /dev/schemas/project-validation.json` → `docs.validation_schema`<br>`GET /dev/schemas/sdk-v1.json` → `docs.sdk_schema`<br>`GET /dev/schemas/game-manifest.json` → `docs.manifest_schema`<br>`GET /dev/schemas/game-capabilities.json` → `docs.capabilities_schema`<br>`GET /dev/examples/list-projects.json` → `docs.example_projects`<br>`GET /dev/examples/validate-project.json` → `docs.example_validation` |
| 项目 | `GET /dev/api/projects` → `projects.list`<br>`POST /dev/api/projects` → `projects.create`<br>`DELETE /dev/api/projects/{projectId}` → `projects.delete`<br>`POST /dev/api/projects/{projectId}/copy` → `projects.copy`<br>`GET /dev/api/projects/{projectId}/validate` → `projects.validate`<br>`DELETE /dev/api/projects/{projectId}/data` → `projects.clear_data` |
| 清单与能力声明 | `GET /dev/api/projects/{projectId}/manifest` → `manifest.read`<br>`PUT /dev/api/projects/{projectId}/manifest` → `manifest.update`<br>`GET /dev/api/projects/{projectId}/capabilities` → `project_capabilities.read`<br>`PUT /dev/api/projects/{projectId}/capabilities` → `project_capabilities.update` |
| 文件与目录 | `GET /dev/api/projects/{projectId}/files` → `files.list`<br>`GET /dev/api/projects/{projectId}/file` → `files.read`<br>`PUT /dev/api/projects/{projectId}/file` → `files.write`<br>`PATCH /dev/api/projects/{projectId}/file` → `files.patch`<br>`DELETE /dev/api/projects/{projectId}/file` → `files.delete`<br>`GET /dev/api/projects/{projectId}/asset` → `files.read_asset`<br>`GET /dev/api/projects/{projectId}/diff` → `files.diff`<br>`POST /dev/api/projects/{projectId}/directory` → `directories.create`<br>`DELETE /dev/api/projects/{projectId}/directory` → `directories.delete`<br>`POST /dev/api/projects/{projectId}/file-operations` → `files.manage` |
| 批量变更与历史 | `POST /dev/api/projects/{projectId}/file-changes/preview` → `file_changes.preview`<br>`POST /dev/api/projects/{projectId}/file-changes/apply` → `file_changes.apply`<br>`GET /dev/api/projects/{projectId}/local-history` → `history.list`<br>`GET /dev/api/projects/{projectId}/local-history/diff` → `history.diff`<br>`POST /dev/api/projects/{projectId}/local-history/restore` → `history.restore` |
| 包与发布 | `POST /dev/api/packages/import` → `packages.import`<br>`GET /dev/api/projects/{projectId}/package` → `packages.export_project`<br>`GET /dev/api/projects/{projectId}/package-exports` → `package_exports.options`<br>`POST /dev/api/projects/{projectId}/package-exports` → `package_exports.create`<br>`GET /dev/api/projects/{projectId}/package-exports/{exportId}` → `package_exports.download`<br>`DELETE /dev/api/projects/{projectId}/package-exports/{exportId}` → `package_exports.release`<br>`GET /dev/api/projects/{projectId}/publish` → `projects.publish_sources`<br>`POST /dev/api/projects/{projectId}/publish` → `projects.publish` |
| 运行时 | `GET /dev/api/run` → `runtime.active`<br>`GET /dev/api/projects/{projectId}/run` → `runtime.status`<br>`POST /dev/api/projects/{projectId}/run` → `runtime.start`<br>`POST /dev/api/projects/{projectId}/run/restart` → `runtime.restart`<br>`POST /dev/api/projects/{projectId}/run/stop` → `runtime.stop`<br>`GET /dev/api/projects/{projectId}/development` → `runtime.development.status`<br>`POST /dev/api/projects/{projectId}/development` → `runtime.development.start`<br>`DELETE /dev/api/projects/{projectId}/development` → `runtime.development.stop`<br>`POST /dev/api/projects/{projectId}/webview/javascript` → `runtime.webview.execute_javascript`<br>`GET /dev/api/events` → `events.subscribe`<br>`GET /dev/api/logs` → `runtime.logs` |
| 平台能力 | `GET /dev/api/capabilities` → `capabilities.list`<br>`GET /dev/api/capability-tests` → `capability_tests.list`<br>`POST /dev/api/capability-tests` → `capability_tests.run`<br>`POST /dev/api/capability-tests/instances` → `capability_tests.instances.create`<br>`POST /dev/api/capability-tests/instances/{instanceId}/invoke` → `capability_tests.instances.invoke`<br>`DELETE /dev/api/capability-tests/instances/{instanceId}` → `capability_tests.instances.dispose` |
| AI 与提示词 | `GET /dev/api/operations` → `operations.list`<br>`GET /dev/api/ai-context` → `operations.context`<br>`GET /dev/api/projects/{projectId}/chat-prompt.txt` → `prompts.project.chat`<br>`GET /dev/api/projects/{projectId}/agent-prompt.txt` → `prompts.project.agent`<br>`GET /dev/api/ai-prompt-templates` → `prompts.templates.list`<br>`PUT /dev/api/ai-prompt-templates/{templateId}` → `prompts.templates.save`<br>`DELETE /dev/api/ai-prompt-templates/{templateId}` → `prompts.templates.reset`<br>`GET /dev/api/ai-approvals` → `ai_approvals.list`<br>`POST /dev/api/ai-approvals/{approvalId}` → `ai_approvals.decide` |

AI 提示词的 locale 与 App 使用同一个事实源。模板正文位于
`assets/playmesh-library/public/developer/prompts/{locale}/`，文件映射只在同目录
`manifest.json` 声明；启用语言、默认语言和 fallback 读取全局
`assets/playmesh-localization/manifest.json`。生成器固定文案来自对应 locale 的
`app.json` 中 `developer.prompt.runtime.*`，工作区调用模板和项目提示词接口时只传当前
BCP 47 locale。模板列表、读取、保存、恢复和项目导出使用同一 locale 解析流程；非默认
语言的用户覆盖按 locale 隔离。不得在提示词目录增加第二份 App 文案、语言清单或 fallback，
也不得在 Dart/JavaScript 中按语言分支。完整撰写要求见[工程开发规范](../06-engineering-standards.md#文档撰写规则)。

`GET /dev/{workspacePath}/workspace`、同会话下的
`GET /dev/{workspacePath}/gdevelop/**` 和 `/playmesh/**` 静态资源由 Gateway 外壳处理，
不是 Operation。它们不能被复制进上表或 `/dev/api/operations` 冒充业务 API。
GDevelop 路由只读取本机 `playmesh-library/GDevelop/official/` 中已经安装且准备完成的
Web IDE；缺少 `index.html` 时不生成可视化工作区链接，也不回退到 GDevelop 在线服务。

### 开发资源会话

`POST /dev/api/projects/{projectId}/development` 接收
`resourceBaseUrl + credential + expiresAt`，把当前项目临时切换到 CLI 本地开发资源，
并返回真实 App 运行的 `runId`。`resourceBaseUrl` 必须是带端口的 HTTP 根地址且属于
当前请求来源；credential 为 32–128 位一次性 URL-safe 值，`expiresAt` 使用 Unix
毫秒且最多在未来 24 小时。会话只保存在内存，不写入项目、安装包或开发者配置。

CLI 在调用该接口前，已把 JavaScript、TypeScript、Cocos 或未来引擎的开发源归一为
公共 `development.Mapping`。Developer Gateway 只消费上述三个会话字段，
不会接收 Adapter ID，也不得加入 Cocos 或其他引擎分支；引擎侧来源、路径、headers
和生命周期始终留在 CLI 的 `adapter.Adapter` / `development.Source` 边界。

开发态仍复用 GamePage、WebView、Game/App SDK、权限、存储和多人 Authority。
`/playmesh/**`、`/bucket/**` 由 App 本地处理，其他 GET、HEAD 和 WebSocket 请求才
转发到固定开发源。重复开发启动、正式 `run/restart`、DELETE 和 Gateway 关闭必须按
`runId` 串行：替换前先关闭旧页面、资源网关及现有 WebSocket；停止失败保留会话供
重试；到期后状态查询返回 `active: false` 并触发清理。DELETE 只撤销临时开发运行，
不覆盖正式物理 `app/`，也不删除 `data/`、`cache/`。

## 完整注册流程

新增 API 必须走完以下链路：

1. 在 `lib/core/developer/operations/{domain}/` 创建或扩展一个
   `_DeveloperHttpOperation`。
2. 在 `definitions` 中定义 `DeveloperOperationDefinition`。至少提供全局稳定
   `id`、`method`、`path` 和 `summary`；再按实际行为填写 `permission`、`risk`、
   `idempotent`、`dangerous`、`requiresForegroundView`、参数、请求 Schema 和响应。
3. 在同一类的 `handle()` 实现业务。一个类包含多个 method/path 时，进入 handler
   后应按 `definition.id` 或已经匹配的 `request.method` 做明确分支，不重新解析整条
   URL。
4. 在 `developer_web_gateway_io.dart` 增加对应 `part`，并把 Operation 实例加入唯一
   `_developerOperationRegistry` 列表。只有存在于该列表中的 definition 才能执行。
5. 不手写 OpenAPI 或 AI 操作目录。注册成功后，`definitions` 自动投影到
   `/dev/openapi.json`、`/dev/api/operations`、Chat/Agent 文档以及
   `X-Playmesh-Operation-ID`。
6. 如属公开契约变化，升级 `_DeveloperOperationRegistry.catalogVersion`，更新调用方、
   版本日志和接口测试。

注册完成的最低判断为：

```text
Operation 文件已实现，但没有 part
  => 编译单元不可见，未注册

有 part，但实例不在 _developerOperationRegistry
  => 不会进入 definitions，不会路由，也不会出现在 OpenAPI

实例已注册，但 method/path 不等于实际请求
  => match == null，最终返回 404 route_not_found

method/path 命中
  => 选择列表顺序中的第一个匹配 definition
```

当前注册器不会用 operation ID 代替 method/path 路由，也不应依赖后注册项覆盖前项。
新增 definition 必须保证同一 method/path 唯一，并用契约测试比较 Operation Catalog
与 OpenAPI 集合。

## 完整 HTTP 调用链与精确判断

### 1. 工作区网页发起请求

内置工作区普通操作统一通过 `api(path, options)` 调用 `fetch`，合并 Developer
鉴权头和 `Content-Type: application/json`。对话控制台只允许：

```text
method 属于 GET / POST / PUT / PATCH / DELETE
且 URL.origin == location.origin
且 URL.pathname.startsWith("/dev/api/")
```

满足时才发起请求，并添加 `X-Playmesh-AI-Channel: chat`。Agent 使用同一 HTTP API，
只把 channel 标为 `agent`。

### 2. 请求级中间件

Gateway 为每个请求生成 `requestId`，设置 `X-Request-ID`、`no-referrer` 和
`nosniff`，然后按“错误包装 → Token 鉴权 → 路由”的顺序执行。

鉴权的实际放行条件是三选一：

```text
constantTimeEquals(Bearer token, gateway.token)
或 constantTimeEquals(query["token"], gateway.token)
或 constantTimeEquals(cookie["playmesh_developer_token"], gateway.token)
```

三项都不相等时返回 `401 unauthorized`。只有
`request.method == "GET"` 且 `request.uri.path.startsWith("/playmesh/developer/")`
的开发者静态资源跳过 Token；业务 API 不跳过。

### 3. Gateway 外壳路由

`_dispatch()` 依次判断：

```text
GET 且 path.startsWith("/playmesh/developer/")
  => 开发者公共静态资源

GET 且 path == session.workspacePath
  => 设置 HttpOnly/Strict token cookie，返回工作区 HTML

GET 且 path.startsWith(session.gdevelopWorkspacePath)
  => 从本机已安装目录安全返回 GDevelop Web IDE 文件

GET 且 path.startsWith("/playmesh/")
  => 其他 Playmesh 公共资源

否则
  => _developerOperationRegistry.dispatch()
```

前面三项均不满足，且 Operation Registry 返回 `false`，才返回
`404 route_not_found`。

### 4. Operation Registry 匹配

注册器按注册顺序遍历每个 Operation 的每个 definition。一个 definition 只有同时满足
以下条件才命中：

```text
definition.method.toUpperCase() == request.method.toUpperCase()
且 template.pathSegments.length == actual.pathSegments.length
且每一个普通模板段 == 对应实际段
```

`{projectId}`、`{templateId}` 等 `{name}` 段匹配任意单个已由 URI 解析的 path segment，
并写入 `pathParameters[name]`。Query 不参与 path 匹配，由 handler 从
`request.uri.queryParameters` 读取。命中后立即停止搜索，并设置：

```http
X-Playmesh-Operation-ID: <definition.id>
```

### 5. 操作级中间件

执行顺序固定为前台检查，再做 AI 审批：

```text
operation.requiresForegroundView == false
  => 直接进入下一步

operation.requiresForegroundView == true
且 gateway.viewAvailability().available == false
  => 409 app_view_unavailable，不进入审批
```

AI 审批条件为：

```text
operation.dangerous == true
且 X-Playmesh-AI-Channel 去空白后非空
  => 请求 approvalBroker

approved => 执行 handler
rejected => 403 ai_operation_rejected
timeout  => 408 ai_approval_timeout
```

`dangerous == false` 或没有 AI channel 时直接进入 handler。`chatEnabled`、
`agentEnabled` 和 `chatBootstrap` 只控制操作目录投影；`permission` 当前也是
OpenAPI/目录/审计元数据，不是另一套角色鉴权。实际网络门禁是 Developer Token，
实际运行门禁是上述前台检查和 AI 危险操作审批。以后若实现权限主体，必须新增统一
中间件，不能在单个 handler 中比较 `permission`。

### 6. Handler、响应与错误

中间件全部调用 `next()` 后才执行：

```text
matched.operation.handle(
  gateway,
  request,
  requestId,
  matched.definition,
  matched.pathParameters
)
```

Handler 负责参数、资源归属、revision 和业务状态判断，并通过统一 `_json/_error`
返回。请求级错误中间件把常见异常稳定映射为：

| 异常 | HTTP / code |
| --- | --- |
| `FormatException` | `400 invalid_request` |
| `StateError` | `404 not_found` |
| `DeveloperViewUnavailable` | `409 app_view_unavailable` |
| `DeveloperCapabilityUnavailable` | `409 capability_unavailable` |
| `DeveloperRevisionConflict` | `409 revision_conflict` |
| `DeveloperProjectValidationFailure` | `422 package_validation_failed` |
| 其他异常 | `500 internal_error` |

SSE、文本、SVG、二进制和额外业务错误可以由对应 Operation 返回其已声明响应，但仍须
保留 request ID 和 Operation ID。

## 新增操作

1. 选择已有资源域；确有新职责时再建立新目录。
2. 定义稳定 operation ID、method 和 path。
3. 补齐请求 Schema、示例、权限、风险、幂等和错误状态。
4. 在同一 Resource Operation 实现 handler。
5. 只注入该操作需要的平台服务；不要从 UI 或全局状态绕过正式服务。
6. 把 Resource Operation 注册到唯一操作列表。
7. 确认操作目录、OpenAPI 和 `X-Playmesh-Operation-ID` 自动出现。
8. 增加成功、错误、鉴权、审批和契约一致性验证。
9. 如属公开契约变化，升级 Developer API 并更新版本日志。

## 中间件边界

公共行为由中间件统一实现：

- 请求 ID 和标准错误；
- Developer token 鉴权；
- Operation 元数据响应头；
- 公共 OpenAPI 响应；
- AI 危险操作审批；
- 前台 View 可用性检查。

Handler 不应复制鉴权、危险操作判断或标准错误包装。

检查顺序必须避免无意义审批。例如需要可见 WebView 的操作，在 App 后台或锁屏时应先
返回 `409 app_view_unavailable`，不应先请求用户批准一个必然无法执行的操作。

## Chat 与 Agent

Chat 和 Agent 使用同一 Operation：

```http
X-Playmesh-AI-Channel: chat
X-Playmesh-AI-Channel: agent
```

- Chat 控制台只负责把 JSON 指令转换为同源 HTTP 请求和展示结构化响应。
- Agent 根据操作目录和 OpenAPI 自行发现能力。
- 不为某个 AI 厂商维护专用项目接口或独立文件协议。
- `dangerous=true` 的 AI 请求统一进入审批 Broker。
- 审批范围必须绑定操作、项目或游戏，不能用模糊全局布尔值放行所有请求。
- 日志不记录完整 token。

## 项目和文件边界

- 项目根固定为 `playmesh-library/packages/{gameId}/`。
- 普通文件 API 不能访问 `data/`、`cache/`、其他项目或系统路径。
- `main.json` 和能力声明优先使用高层结构化接口。
- 写入必须校验 revision；批量修改使用 preview/apply 和 `baseRevisions`。
- 多文件提交应原子完成，失败不留下半个版本。
- 保存、上传、移动、删除、整包发布和恢复进入同一项目本地历史。
- 运行、发布和正式导入保持严格校验；发现和项目拉取可提供明确的宽松自救通道。
- `requestId`、`projectId`、`runId`、`eventId` 用于跨接口和日志定位。

## 本地历史

历史位于：

```text
packages/{gameId}/cache/developer/local-history/
```

约定：

- 一份 baseline，加每次时间操作的 after snapshot；
- 连续变更按固定滚动窗口合并；
- 淘汰最旧操作前先提升 baseline；
- 不保存或恢复 `data/`、`cache/` 自身；
- 整包发布与项目恢复遵循同一历史链；
- 恢复动作本身生成独立历史操作；
- CodeMirror 只负责尚未保存缓冲区的即时撤销与重做。

## 网页前端

工作区前端位于：

```text
assets/playmesh-library/public/developer/
```

规则：

- 不在 Dart Gateway 内嵌 HTML、CSS、模板或编辑器资源。
- 不硬编码 Developer API、能力列表或 SDK 方法树。
- API 来自 Operation Catalog/OpenAPI。
- 能力选项来自平台注册表。
- 项目创建/修改弹窗的能力多选项只按描述符的 `supportedPlatforms` 渲染
  `WINDOWS`、`ANDROID`、`HTML` 支持徽标；列表中没有的平台视为不支持，不再渲染
  “不支持”徽标，也不读取旧的双布尔字段。
- SDK 补全来自注册表组装的 `.d.ts`。
- 能力测试参数只按 `CapabilityDescriptor.optionsSchema` 和
  `methods[].argumentsSchema` 递归渲染表单，不要求开发者手写 JSON，也不按能力
  code 编写专用页面。
- 文件状态和运行状态通过正式 API 与 SSE 同步。
- 响应式布局必须同时保留项目、运行、保存、AI 和更多操作的可达性。
- 第三方编辑器依赖由独立 `package.json` 和锁文件管理，不混入游戏模板。

### 定义驱动的能力测试

工作区“更多 → 平台能力测试”的一键自检使用默认参数调用真实 `create({})`，成功后
立即 `dispose()`；创建或释放失败即报告自检失败，不维护独立探测接口。交互测试允许
开发者按描述符传入参数并调用方法。完整调用链为：

```text
GET /dev/api/capability-tests
  -> 返回 descriptor + testable + platformAvailable
  -> Workspace 选择 descriptor
  -> optionsSchema 递归生成测试实例参数表单

POST /dev/api/capability-tests
  -> 对选中插件调用 plugin.create({})
  -> 成功后立即 instance.dispose()
  -> 创建或释放失败时返回 failed

POST /dev/api/capability-tests/instances
  body.code == descriptor.code
  -> registry.plugin(code)
  -> plugin == null 时 400 invalid_request
  -> registry.isPluginAvailable(plugin) == false 时 409 capability_unavailable
  -> plugin.create(options)
  -> 订阅 instance.events
  -> 返回 instanceId

POST /dev/api/capability-tests/instances/{instanceId}/invoke
  body.method == descriptor.methods 中某一项的 name
  -> 不相等时 400 invalid_request
  -> argumentsSchema 递归生成的方法表单提供 arguments
  -> instance.invoke(method, arguments)
  -> result 原样进入 JSON 回显

instance.events 发出 event.name
  -> event.name 在 descriptor.events 中时
     通过 SSE capability.test.event 实时回显
  -> 未声明事件通过 capability.test.error 报告，不伪装成已声明事件

DELETE /dev/api/capability-tests/instances/{instanceId}
  -> 先取消事件订阅
  -> instance.dispose()
  -> 重复释放返回 disposed=false
```

参数表单统一支持对象、数组、枚举、布尔、数字、整数和字符串；对象按
`properties/required` 展开，可选字段可决定是否传入，数组按 `items` 增删项目。
参数区不提供原始 JSON 输入；右侧 JSON 只回显实例创建、方法调用、返回值、错误和
持续事件。

只要定义声明了事件，界面就显示“持续回调”。若方法列表存在精确名称 `start` 和
`stop`，启动与停止按钮分别调用这两个方法，并使用各自 `argumentsSchema` 的表单
参数；没有对应方法时，创建实例即开始接收事件，停止时释放实例。这个规则只依赖
定义结构，不判断能力 code。切换能力、关闭弹窗或关闭 Gateway 都必须释放活动实例。

API 路径、事件类型和 JSON 正文是机器协议，不做国际化；标题、按钮和状态解释使用
App 统一的 `workspace.*` 词条。

### 导出与多源发布

Workspace 顶部保留既有 `#publish` 与移动端 `#publishFromMenu` DOM ID，但用户可见名称为
“导出”。打开后先显示三个可键盘操作的同级选项；选项只显示动作名称，不重复陈述下游
保存或校验流程：

- “导出源码”先保存当前未保存文本，再请求
  `GET /dev/api/projects/{projectId}/package`。这是既有 `packages.export_project`
  Operation，继续使用 `GamePackageTransferService` 的宽松导出，用于正常备份，也允许取回
  待修复项目；不得为这一 UI 新增第二个 Operation 或改变 CLI 依赖的宽松语义。
- “安装包导出”进入独立的 `package_exports.*` Operation：用户只选择一个
  `android-arm64`、`android-x86_64` 或 `windows-x64` 目标。导出设置区提供可搜索的
  当前可用中转服务器列表，并保留“不内置”和“使用自定义地址”两种选择；选择已配置服务器时，
  工作区将其 Catalog 地址与读取 Token 组合为 Runtime publicURL。重新下载 Runtime 是目标
  底包维护动作，不属于游戏导出设置。
- “上传到发布源”进入原有发布源候选、校验、提交、状态与失败重试界面。

安装包 Runtime 不得进入主 App 的 Flutter assets。固定安装位置是
`<playmesh-library>/runtime/packages/` 下的 `playmesh-runtime-arm.apk`、
`playmesh-runtime-x86.apk` 与 `playmesh-runtime-win.zip`；`installed` 只表示对应文件存在，
因此测试期可以手工复制。文件不存在或用户选择重新下载时，服务必须按
`assets/app/App.json` 的 `export` 源依次读取 Runtime `update.json`，再按目标选择下载线路，
流式下载并只以声明的 SHA-256 验证，成功后原子替换固定文件。已存在且未要求重新下载时
直接复用，不访问远端；重新下载失败必须保留旧文件。

`resources/runtime/update.json` 对每个目标只声明一次平台级 SHA-256，再列出共享该摘要的
下载线路，不能在每条线路内重复或覆盖摘要：

```json
{
  "sha256": "<64 位小写 SHA-256>",
  "downloads": [
    { "name": "GitHub", "url": "https://..." },
    { "name": "临时源", "url": "http://..." }
  ]
}
```

三份底包发布后填写实际 URL。清单层不限制 URL 协议、凭据或 Fragment；HTTP/HTTPS 请求
自动跟随最多 5 次重定向且不复查跳转目标。空 URL 不得在界面中误报为可下载，无法请求的
地址在实际下载时失败。无论选择哪条线路，最终文件都必须通过该目标唯一的 SHA-256 校验。

安装包创建请求正文固定为
`{target, refreshRuntime, relayServer}`，不接受额外字段。`relayServer` 只能是一个
`http`/`https` URL 或 `null`，由导出服务写入 Runtime 游戏载荷（Android 与 Windows 均为
平台 Runtime 公钥封装的 PME1 加密）；游戏项目不能自行携带
Runtime 私有配置覆盖它。客户端可用 `X-Playmesh-Package-Export-Request-ID` 关联
`package_export.progress` SSE；事件按 `projectId + requestId + target` 隔离，阶段覆盖
准备、Runtime 检查/真实下载字节/校验、游戏包构建、原生导出以及唯一完成或失败终态。

生成物通过 `package_exports.download` 流式交付并通过 `package_exports.release` 释放。
源码包与安装包必须共用同一个 `saveOrDownloadExport`：普通浏览器直接使用同源
`<a download>`，App WebView 只把白名单同源 URL、文件名、MIME 与精确长度交给既有
`__playmeshSaveBlobDownload` 原生保存桥；网页不得读取完整 Blob 或 ArrayBuffer。

源码包下载名必须复用 `gamePackageFileName` / `gamePackageShareFileName` 的单一规则，保持为
`{游戏名称}-v{版本}.zip`；浏览器从 `/package` 的 UTF-8 `Content-Disposition` 取得名称，
WebView 宿主从既有项目列表读取同一名称与版本后调用同一 Dart helper，不得回退为项目 ID
命名或在 JavaScript 中复制文件名清洗算法。

点击“导出源码”后必须先渲染可见的“处理中”状态并禁止重复触发，再保存未提交文本和交接
下载。普通浏览器在提交标准下载请求后显示等待浏览器接管的状态；WebView 使用同一状态覆盖
消息交给原生宿主前的空窗，随后由系统保存器或分享界面提供原生反馈。网页不得为显示进度而
把完整项目包读取成 Blob，也不得伪造无法从标准下载链获知的字节进度或完成状态。

导出产物是 Playmesh 项目包：可解析时规范化的 `main.json`（待修复时保留原文件）、
可选 `icon.png`、可选
`capabilities.json` 与 `app/`；`data/`、`cache/`、`.playmesh/` 和其他私有文件不得进入。
它不等同于外部 TypeScript、Cocos 等工具的原始工程。普通浏览器使用同源
`<a download>`，不先读取完整 Blob；App WebView 只把同源且精确匹配项目包路由的 URL
交给原生宿主。源码工作区与 GDevelop 共用既有 `__playmeshSaveBlobDownload` 兼容钩子、
消息通道、系统选择/分享界面、Bearer 下载、分块写盘和清理函数；钩子只在输入适配层区分
Blob 与白名单项目包 URL。宿主复用当前 Developer Token 流式写入系统保存目标。该直连
消息不得接受外部 Origin、查询参数、fragment、其他 Developer 路由或越界项目 ID；项目包
本身不得 POST 到需要 GDevelop editor lease 的 `/dev/api/gdevelop/native-file-saves`，
也不得先读入 WebView Blob 再二次暂存。`/package` 在 ZIP 生成后声明精确
`Content-Length`，共用下载函数必须核对完整接收并在取消或失败时清理半成品。

`/package` 不做完整语义校验是已知且保留的修复能力；UI 与文档不得把宽松导出结果描述为
项目已通过校验。重新导入、安装和“上传到发布源”仍执行严格校验。

发布必须使用正式 Operation，不在 Workspace JavaScript 中直接拼 Catalog 请求：

```text
GET  /dev/api/projects/{projectId}/publish
POST /dev/api/projects/{projectId}/publish
```

- GET 只返回启用、支持用户上传且配置上传密钥的候选源。
- 候选响应只暴露 `id/name/protocolVersion/maxUploadBytes`；Host、读取 Token 和
  上传密钥均不得返回前端。
- POST body 只允许 `sourceIds`，额外字段拒绝。
- 服务端重新保存并完整校验项目；校验失败时不准备或导出 ZIP。
- 同一次发布只导出一个 ZIP，按源独立上传并经安全 SSE 更新状态。
- 部分成功保留成功结果，重试只接受上次失败的源。
- 30 秒超时、有限错误体、凭据脱敏和临时文件 finally 清理属于服务端不变量。
- 根 `icon.png` 由项目包携带；项目设置保存时由当前表单字段重新构造
  `main.json`，不会展开原对象。任何表单未定义的额外字段都按普通未知字段静默忽略，
  不建立识别、校验、告警或兼容分支。平台能力只编辑同级 `capabilities.json`。

### 本地化、主题与输入

Workspace 是 App 内置界面，所有可见文案只来自 App 语言包中的 `workspace.*`：

```text
assets/playmesh-localization/manifest.json
assets/playmesh-localization/locales/{locale}/app.json
```

Flutter Host 使用 `PlaymeshLocalizationCatalog` 和当前 `PlaymeshUiController` 解析 App
消息，再通过同源、已鉴权的桥接端点投影给 Workspace：

```text
GET /dev/api/localization
PUT /dev/api/localization  {"localeId":"en-US"}
PUT /dev/api/localization  {"themeMode":"dark"}
PUT /dev/api/localization  {"localeId":null,"themeMode":"system"}
```

`localeId: null` 表示恢复跟随 App/系统。快照包含 `formatVersion`、当前
locale/mode、默认语言、可选语言、`themeMode`、实际显示 App 的
`effectiveTheme`、`allowThemeSwitch` 和已解析的 `workspace.*` messages。PUT 可只更新
语言、只更新主题或同时更新二者，并且必须更新同一个 App UI Controller；Workspace
不能维护私有语言或主题状态。App 设置页切换语言/主题后，已打开的 Workspace 也必须
刷新。前端
`workspace-localization.js` 只持有 key、参数和最小协议错误码，不得包含可见 fallback、
按语言 ID 分支、独立字典、`developer.json` 或 `/playmesh/localization/**` 路由。静态
文本、动态状态、title、placeholder 和 aria-label 都通过桥接消息解析。

只有固定 UI 外壳能定义 `workspace.*` 词条。项目名、游戏名、游戏源名称、发布者、
昵称、标签、文件名、日志以及未知或开发者自定义的 API 文本必须原样渲染；需要放进
固定句式时，只能作为不变插值参数传入，不能再把动态值当作 key 或翻译源。平台内置
能力、提示模板、校验诊断和本地历史通过显式 code/ID 白名单映射固定词条；诊断与历史
API 同时保留原始 `message`/`summary`，并提供 `messageArguments`/`hintArguments`
或 `summaryArguments`。未知 code/ID 必须回退原文，路径、错误详情等参数始终原样插值。

Workspace 自有视觉规则统一保存在 `workspace.css`，页面只加载这一份平台自有样式表，
不得再层叠加载 `workspace-v1.css`、`validation.css`、`clear-game-data.css` 等第二套
覆写源。CodeMirror 自带样式仍作为第三方编辑器依赖独立加载。颜色、表面、焦点、
状态、圆角和交互命中区由文件顶部唯一的 `:root` 令牌组定义；组件规则只负责布局，
不得重新建立私有主题令牌。图标由本地打包的 `workspace-icons.js` 创建为内联 SVG；
不得重新引入外部 SVG sprite 的 `<use href>`，避免 WebView 资源错误事件把
`SVGAnimatedString` 错当成失败 URL。

项目入口、文件树和工具栏共享同一图标工厂。文件树至少区分目录、CSS、JavaScript、
图片、文本、压缩包、`main.json` 与未知文件；移动端固定呈现“项目 / 运行 / 保存 /
AI / 更多”，导出位于“更多”；桌面端同时显示图标与文字并直接显示“导出”。AI 是工具栏
唯一的强强调操作。

主题仍支持 `system/light/dark`，但选择只保存在 App UI 偏好中；Workspace 不得使用
`localStorage` 或浏览器 `matchMedia` 建立第二套主题状态。Gateway 在返回工作区 HTML
时把 App 快照中的 `effectiveTheme` 注入 CSS 前的首帧引导，避免闪烁；异步刷新仍以
`/dev/api/localization` 为事实源。二维码保持白底。普通组件圆角不超过 8px，不使用
渐变、光晕、装饰阴影或 `transition: all`。`prefers-reduced-motion` 下禁用非必要动画。

按钮、链接、输入、选择框、文本域和文件树摘要的命中区至少为 `44 × 44px`。原生
checkbox/radio 可保持紧凑视觉尺寸，但包裹它的 `label` 必须承担至少 44px 的点击区。
项目、文件、历史、诊断、能力、发布结果和 diff 等可能超过 50 项的列表项必须使用
`content-visibility: auto` 与稳定的 `contain-intrinsic-size`，或在数据层分批渲染；
日志仍按既有上限裁剪，不能为虚拟化而改写日志文本。

所有工具、项目/文件菜单、对话框和发布源多选必须可用键盘完成。菜单打开聚焦首项，
Escape 关闭最上层，关闭后恢复触发控件。每个 `.modal` 都走同一焦点生命周期：打开
聚焦 `data-initial-focus` 或首个可用控件，Tab/Shift+Tab 与方向键留在最上层弹窗，
嵌套弹窗按栈恢复，关闭后回到原触发控件。AI 审批弹窗同样保持焦点陷阱，但 Escape
只能被拦截，不能关闭、拒绝或以其他方式绕过审批。方向键、Enter/Space 与 Android TV
遥控器等价，不能把 hover、右键或拖拽作为唯一入口。新增交互时必须保留既有 DOM ID、
字段和 Developer API 业务语义；视觉或可访问性调整不得建立第二套操作路径。

## Android 后台

开发者模式的 Android Foreground Service 可以保持 Gateway、CPU 和 Wi-Fi，但不能让
依赖 Activity/View 的操作在后台假装成功。

Operation Definition 必须准确声明是否需要前台 View。状态模型至少区分：

- `foreground`
- `device_locked`
- `screen_off`
- `app_backgrounded`
- `activity_unavailable`
- `window_not_focused`

项目文件、校验、状态和日志等后台安全接口应继续工作；启动、重启、能力自检和
WebView JavaScript 等 View 操作在不可用时返回结构化 `409`。

## 安全

- 开发者模式默认关闭。
- Gateway token 使用高强度随机值或受长度约束的用户值。
- Gateway 的所有响应设置 `Referrer-Policy: no-referrer` 与
  `X-Content-Type-Options: nosniff`，避免工作区 URL 查询参数中的 token 经 Referrer
  或错误 MIME 嗅探泄露。
- token、端口和工作区路径属于敏感开发配置，不进入游戏包或 AI 项目源码。
- Gateway 绑定局域网接口时，设置页只展示可用局域网地址。
- AI 无权执行任意系统命令、读取其他项目或访问 App 私有资料。
- WebView JavaScript 属于高风险操作，必须绑定当前运行项目和当前执行器实例。
- 删除项目、删除文件和其他不可恢复操作必须声明危险性并提供人工确认。

## 验证清单

- Gateway 入口没有手写 `/dev/api/**` 旁路。
- Operation Catalog 与 OpenAPI 的 method/path 集合一致。
- 每个响应包含正确 Operation ID 和 request ID。
- 鉴权、风险、幂等和前台要求来自定义而不是 Handler 私有判断。
- AI 危险操作可以允许、拒绝和超时，且批准范围正确。
- revision 冲突不会覆盖较新的文件。
- 批量修改和整包发布失败时保持原项目。
- 路径穿越、内部目录和跨项目访问被拒绝。
- 本地历史、SSE、日志和运行状态保持同一项目/运行实例归属。
- Android 后台安全接口可用，View 操作返回准确的结构化错误。
- 新接口已评估 Developer API 版本并记录验证边界。
- 发布候选响应不包含 Host、读取 Token 或上传密钥。
- 导出选择弹层、发布源弹层和移动端菜单都可全键盘操作，关闭后恢复到实际触发控件。
- 浏览器导出走标准下载；WebView 直连保存只接受当前网关的项目包路径、携带当前会话
  Token、流式写入并在取消或失败时清理半成品，不经 GDevelop Blob 暂存。
- `/package` 继续允许待修复项目宽松导出，且产物排除 `data/`、`cache/`、`.playmesh/`；
  重新导入与上传发布源仍严格校验。
- 校验失败不打包，部分失败可以只重试失败源，所有路径清理临时 ZIP。
- 项目设置保存只投影当前表单字段；任意额外 `main.json` 字段静默忽略，且不存在
  字段专用识别、删除、告警或兼容逻辑。
- 两个启用语言的 Developer 词典 key 集一致，清单 fallback 无环。
- Workspace 语言与主题快照来自同一 App UI Controller，HTML 首帧不读取浏览器私有
  主题偏好。
- HTML、静态资源、API、错误响应和 SSE 均带 `no-referrer` 与 `nosniff`。
- system/light/dark、reduced motion、320px、平板、桌面和 TV 视口无溢出。
- 平台自有样式只加载 `workspace.css`；所有交互命中区达到 44px，长列表启用跳过渲染
  或分批渲染。
- 导出选择弹层、发布源弹层、项目菜单、文件树、更多菜单和 AI 审批可全键盘操作并恢复焦点；AI 审批
  不允许通过 Escape 绕过。
