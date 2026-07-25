# 开发者工作区开发约定

本约定适用于 Developer Gateway、Developer Operation、网页工作区、AI 对话控制台、
Agent API、项目文件与本地历史。游戏作者使用说明见
[网页开发者通道](../game/web-dev-channel.md)。

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
- SDK 补全来自注册表组装的 `.d.ts`。
- 文件状态和运行状态通过正式 API 与 SSE 同步。
- 响应式布局必须同时保留项目、运行、保存、AI 和更多操作的可达性。
- 第三方编辑器依赖由独立 `package.json` 和锁文件管理，不混入游戏模板。

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
