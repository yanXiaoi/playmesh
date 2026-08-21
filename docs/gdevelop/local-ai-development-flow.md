# GDevelop 5 本地 AI 开发流设计

## 结论

Playmesh 的可视化开发入口以开源 GDevelop 5 Web IDE 为编辑内核，但不代理、伪装或兼容
GDevelop 官方 Generation API。Playmesh AI v4 只负责把经过校验和用户审批的工具调用转交给
当前 Web IDE，再由 Web IDE 在当前页面的活动 `gdProject` 上调用 GDevelop 官方
`EditorFunctions`。

AI 修改与用户在编辑器里直接修改具有相同的内存语义：函数返回后，编辑器按官方回调更新
界面和 dirty 状态；何时保存由用户通过 GDevelop 的正常保存流程决定。AI 链路不保存工程，
不写 `current` 或历史，不创建工程 revision，不生成提交证据，也不替用户撤销修改。

App 不包含 LLM 推理客户端，也不保存模型密钥。模型推理由用户选择的 Chat 或 Agent 承担，
不能把外部推理能力描述为 App 内置模型。

## 目标与非目标

目标：

- 保持 GDevelop 官方工程格式，AI 修改后的工程可以继续由官方 GDevelop 打开和导出。
- Chat 与 Agent 使用同一份版本化工具 Schema、审批、排队和执行语义。
- 复用 GDevelop 已验证的对象、场景、行为、变量、资源和事件编辑函数，不另造工程模型。
- 所有 Web IDE 源码改动进入 Playmesh overlay，并由版本锁定的裁剪脚本自动注入。
- AI 生成的多人项目只写官方 GDevelop Multiplayer 行为与事件语义；Playmesh 兼容只发生
  在运行时。

非目标：

- 不调用或复刻 GDevelop 的账号、Credits、云存档、素材、模板和二次生成服务。
- 不允许 AI 执行任意 JavaScript、访问任意 URL、直接读写 IndexedDB 或绕过工具注册表。
- 不为 AI 建立工程保存、历史快照、`current`、revision、提交证据、浏览器 pending journal、
  启动恢复、纠错回合或工程克隆提交链。
- 不兼容 v1 的 `baseRevision`、`baseProjectContentHash`、`event-payload`、`correction`、
  `backend_committed` 或 recovery 协议。
- 不向 GDevelop 工程写入 `playmesh.main.*`。工程迁移到官方导出环境后，必须自动使用
  官方多人运行层。

GDevelop 普通保存、普通项目历史和用户主动恢复仍是独立功能。它们由 GDevelop 的正常编辑
流程触发，不是 AI 调用协议的一部分。

## 可复用实现

Playmesh 侧只复用编辑器无关的公共底层，不让 GDevelop controller/DTO 与源码工作区耦合：

- `lib/core/developer/developer_ai_prompt_templates.dart`：提示词清单、locale 与用户覆盖。
- `lib/core/developer/foundation/developer_ai_approval.dart`：审批领域模型；GDevelop 使用自己的
  tool subject 与 session controller。
- Developer Gateway 的鉴权、中间件、事件中心和操作注册公共层；GDevelop AI 路由集中在
  `operations/gdevelop/gdevelop_ai_operation.dart`，不复用源码文件操作 DTO。
- `assets/playmesh-library/public/developer/workspace.js` 只作为同源 API、安全边界和交互语义
  的参考实现；GDevelop 使用独立的 `PlaymeshAi` overlay。

GDevelop 侧复用固定版本源码中的：

- `newIDE/app/src/EditorFunctions/index.js` 及 `EditorFunctionCallRunner`。
- `SimplifiedProject` 和 `ExtensionSummary` 上下文模型。
- `ApplyEventsChanges` 的反序列化、校验和变更应用逻辑。
- 官方对象、扩展、资源和事件修改后的编辑器通知回调。

不复用 `Generation.js` 和 `AskAiEditorContainer`。它们与 GDevelop 账号、Credits、云端版本、
素材和二次生成服务绑定。Playmesh 使用独立的轻量 `PlaymeshAiEditorContainer`，并维护唯一的
本地 Tool Schema，不重新开放已经由
`assets/playmesh-library/public/GDevelop/playmesh/scripts/apply-source-policy.mjs` 隐藏的
官方 Ask AI。

## v4 架构

```text
用户选择的 Chat / Agent
  -> Developer Gateway：鉴权、Schema、审批、排队、writer lease、状态转发
  -> 当前 GDevelop Web IDE 会话
  -> PlaymeshAiExecutor
  -> GDevelop 官方 EditorFunctions（传入同一个活动 gdProject）
  -> 官方编辑器通知回调与 dirty 状态
  -> 用户按 GDevelop 正常流程自行保存
```

Developer Gateway 只保存当前进程内的 session、turn、call、审批状态、调用输入、执行结果和
writer lease。它不是工程数据的第二所有者，也不能越过 Web IDE 直接修改活动对象。编辑器
关闭、会话 ID 不匹配或执行超时时明确失败，不能假装成功。

### Chat 模式

1. Web IDE 生成包含脱敏项目摘要和工具目录的提示词。
2. 用户把提示词交给模型，再把模型返回的 JSON 工具调用粘贴到控制台。
3. 浏览器先清空旧输入，再读取本次粘贴内容；输入框保留本次实际执行的 JSON，复制返回
   状态不会清空它。
4. 粘贴内容严格使用根 `{echo,calls}`；单个和批量调用都只有一个根级 `echo`，调用项内
   不允许携带 `echo`。
5. 浏览器按唯一 Tool Schema 校验完整调用。`add_scene_events` 必须在调用同级携带完整
   `eventPayload`；其他工具禁止携带它。
6. 需要审批的调用先弹出不可忽略的审批对话框。批准后，当前 Web IDE 串行执行工具。

### Agent 模式

1. Web IDE 建立短期内存 `editorSessionId`，用于会话和调用寻址。外部 Agent 使用现有
   Developer Gateway 根 Token；浏览器内 Web IDE 使用现有 Developer cookie。这里不签发
   第二套 capability principal。
2. Agent 携带 `X-Playmesh-AI-Channel: agent` 提交结构化调用。Gateway 校验工具名、参数、
   可选输入和幂等身份，再创建 turn/call。
3. 当前 Web IDE 拉取已批准调用，在同一个活动 `gdProject` 上执行并回传业务结果。
4. Agent 按 call 状态读取结果。失败即报告，不自动重试写工具，也不把失败包装成工程回退。

Chat/Agent 对话只存在于当前内存会话，不持久化 transcript。Gateway 使用当前 session 已上传
的有界 ProjectContext；context 在进入 prompt 前执行大小、深度和敏感字段限制。

## 调用和执行协议

Editor session wire 协议为 `4.0.0`。Tool Contract 的协议版本和工具版本由唯一文件
`assets/playmesh-library/public/GDevelop/playmesh/runtime/ai/tools.json` 发布，客户端必须
精确匹配，不能降级到旧 editor-session wire。

当前 Tool Contract 为破坏性的 `4.0.0`。GDevelop 5.6.276 源码 ZIP 发布
`EditorFunctions` 实现和 `AI_ORCHESTRATOR_TOOLS_VERSION = 'v12'`，但不发布服务端交给 AI 的
输入 JSON Schema。因此 `tools.json` 不是从官方 ZIP 自动生成的“官方 Schema”，而是针对固定
5.6.276/v12 源码维护的兼容快照。clean-replay 会直接读取锁定源码，核对 v12 常量、17 个官方
函数名、`modifiesProject` 以及实现实际通过 `SafeExtractor` 消费的字段。门禁还会分别冻结参数的
完整嵌套路径（含数组 `items`）、类型、必填列表和枚举；字段放错层级、类型或必填/枚举漂移、
多出字段都会阻断构建。这些参数定义是 Playmesh 对锁定源码的对齐快照，不表示官方 ZIP 发布了
完整 JSON Schema。

`implementation: official_editor_function` 只用于官方函数名与参数面完全一致的工具，调用参数
原样交给官方 runner，不合并隐藏参数。`implementation: playmesh_wrapper` 明确表示本地 facade，
不得冒充官方完整接口。旧的资源/对象子集别名和 `delete_object`、`remove_behavior`、
`delete_scene` 已移除；删除能力由完整官方 change 函数的 `delete_this_*` 字段提供，整个函数按
其最危险语义审批。场景对象组直接使用官方字段
`changed_groups[].objects_to_add: string[]` 与 `objects_to_remove: string[]`，不翻译成员结构。
Playmesh Tool Contract `4.0.0` 与官方 runner generation `v12` 是两个独立版本域。

### 调用信封

Chat 粘贴内容只接受严格根对象；即使只有一个调用也必须放入 `calls` 数组：

```json
{
  "echo": 1,
  "calls": [
    {
      "name": "change_object_properties_effects",
      "arguments": {
        "scene_name": "Game",
        "object_name": "Player",
        "changed_properties": [
          {"property_name": "name", "new_value": "Hero"}
        ]
      }
    }
  ]
}
```

`echo` 是整个本次提交的唯一编号，单个或批量提交都只有一个；调用项不得携带 `echo`。
Web IDE 使用它创建 turn，再为 `calls` 中的项目生成内部 call。Gateway 内部普通工具入队
请求至少包含：

```json
{
  "turnId": "turn_...",
  "callId": "call_...",
  "idempotencyKey": "idem_...",
  "toolName": "change_object_properties_effects",
  "arguments": {
    "scene_name": "Game",
    "object_name": "Player",
    "changed_properties": [
      {"property_name": "name", "new_value": "Hero"}
    ]
  }
}
```

事件工具把完整输入与调用一起锁定：

```json
{
  "turnId": "turn_...",
  "callId": "call_...",
  "idempotencyKey": "idem_...",
  "toolName": "add_scene_events",
  "arguments": {
    "scene_name": "Current Scene",
    "events_description": "Add the requested standard events",
    "extension_names_list": ""
  },
  "input": {
    "eventPayload": {
      "schemaVersion": "1.0.0",
      "sceneName": "Current Scene",
      "changes": []
    }
  }
}
```

示例只展示字段位置；真实 `changes` 不能为空。`input.eventPayload` 在入队时完成校验，参与
幂等指纹，并在审批前锁定。审批后没有补交、替换或纠错入口。非事件工具携带 `input` 会被
拒绝。

### 状态、串行和幂等

- Gateway 按 `gameId` 维护唯一修改型 writer lease；同一时间最多有一个修改工具运行。
- 只读调用可并行，但每个 call 仍有唯一状态和有界超时。
- `idempotencyKey` 与完整调用内容绑定；同键同内容复用同一 call，同键不同内容明确拒绝。
- 审批、取消和超时必须发生在修改函数进入非取消阶段之前。官方修改函数开始后不能伪装
  已取消。
- 修改函数返回或抛出时，Web IDE 立即通知官方编辑器刷新和 dirty 状态；该通知不等待
  execution HTTP 成功。
- Web IDE 在回传前缓存规范化执行结果，缓存键为 `gameId + sessionId + callId`。响应丢失时
  只重发完全相同的结果，绝不再次执行函数。
- 页面或 session 更换会取消旧的尚未执行调用；已经进入修改函数或正在重发终态结果的调用
  不能被重新 lease 或重复执行。

### 执行结果

Web IDE 回传体只允许：

```json
{
  "success": true,
  "output": {}
}
```

失败时可额外携带字符串 `errorCode` 和 `errorMessage`。`output` 是 Web IDE 官方函数或 wrapper
产生的业务结果；Gateway 不添加工程 before/after、revision、hash、history transaction 或
commit evidence。循环引用、不可序列化 getter 等后处理错误会转换为一个可重放的失败结果，
不能在修改已经发生后重新调用函数。

Chat 复制给模型的返回状态使用 `playmesh.gdevelop.ai.return-status.v3`，并在
`schemaVersion` 同级完整回显本次提交的根 `echo`：

```json
{
  "schemaVersion": "playmesh.gdevelop.ai.return-status.v3",
  "echo": 1,
  "latestTurn": {
    "calls": []
  }
}
```

`latestTurn.calls` 和 `failure` 不再携带 echo。Agent 返回状态保持
`playmesh.gdevelop.ai.return-status.v1`，且不包含 echo。

## 工具边界

唯一工具合约由 `GET /dev/api/gdevelop/ai/tools` 和上述 `tools.json` 提供。公开能力由固定
GDevelop 版本的 EditorFunctions 与少量本地 wrapper 组成；工具名、参数 Schema、危险等级、
是否修改工程和 execution kind 全部来自该合约。客户端不得维护第二份工具列表，也不得提供
任意 JavaScript、任意网络访问或已删除工具的兼容入口。

工具 wrapper 必须继续使用同一个活动 `gdProject`：

- 事件修改使用官方 `applyEventsChanges`，完成后调用官方场景事件外部修改回调。
- 对象修改和扩展安装按官方顺序调用对应通知回调。
- 资源导入的临时 Blob URL 由页面级 registry 管理到资源不再需要为止，不能在官方保存序列化
  读取前提前撤销。
- wrapper 不得返回新的 `createdProject` 替换活动工程。

能力搜索读取编辑器已经合并的官方目录和 Playmesh 本地扩展目录，保持大小写不敏感的连续
子串匹配、精确类别过滤和原有分页语义。本地扩展的详情与安装继续通过同源固定目录读取，
官方扩展的详情与制品下载仍走 App 目录接口；搜索结果不得据此猜测或拼接未验证的稳定 ID。

`add_scene_events` 的 `GDevelopEventPayload 1.0.0` 只接受官方 `AiGeneratedEventChange` DTO，
不接受裸 `EventsList` 或自造 placement。浏览器在调用前验证外层字段、sceneName、体积、深度、
生成事件 JSON、对象/行为/资源引用以及敏感内容，然后把 `payload.changes` 交给官方事件应用
函数。校验失败终止该 call；不存在“先写一部分再纠错”或自动再试。

Agent 资源导入可使用当前 session 的一次性内存资源暂存路由。它只为当前工具调用提供字节，
不写 GDevelop 工程历史或 App CAS；资源读取后仍由官方资源 wrapper 加入活动 `gdProject`。
该路由对远程和回环 Agent 使用相同的 Bearer、gameId、editorSessionId 与前台会话边界，
不再额外要求请求来源是回环地址。

## 审批与用户控制

审批复用 Developer Gateway 的统一 approval 模型。需要审批的工具在参数和事件输入全部锁定
后才创建请求，弹窗至少展示工具、风险、受影响对象、参数摘要；事件工具额外展示有界的场景
名和 change 数量/摘要。弹窗不能因点击遮罩或 Escape 被忽略，四种决策分别为本次允许、项目
允许、始终允许和拒绝。

审批解决的是用户对修改行为的授权，不是工程提交。批准不会保存工程，拒绝也不会修改工程。
AI 修改完成后，是否保留、继续编辑或通过 GDevelop 正常方式保存，由用户在编辑器里决定。

Editor session `4.0.0` 另外提供仅属于当前 WebIDE session 的 `approvalMode`：

- `request_approval`（请求审批）是每个新 session 的默认值；需要审批的危险调用继续进入请求
  审批流程。
- `always_allow`（始终允许）立即放行当前 session 内所有正在等待审批的调用，并让该 session
  后续危险调用直接获批。它不等同于逐工具授权，不写项目、历史、配置或授权文件。
- 同一个 session 重新 attach 时保留当前模式；显式关闭 session，或 Developer Mode 进程/
  Gateway 重启导致 session 重建时，一律恢复 `request_approval`。
- 从 `always_allow` 切回 `request_approval` 只约束之后创建的危险调用；已经获批、排队、执行中
  或完成的调用不回滚、不取消，也不重新进入审批。
- 既有按 `scopeKind + scopeId + operationId` 保存的项目/工具授权仍然有效；即使 session 模式为
  `request_approval`，命中已有授权的调用也按原语义获批。
- 只有当前 WebIDE 的用户控制面可以修改 `approvalMode`。Chat 与外部 Agent 共用结果语义，
  但外部 Agent 无权调用设置接口或通过工具参数提升自己的审批模式。
- 编辑器 lease 的首次申请还必须携带 App 在 GDevelop 启动链接中签发的独立、内存态
  bootstrap capability；它先出现在 App 生成的启动 URL 中，bootstrap 重定向消费后只保留在
  HttpOnly acquire Cookie，申请成功后立即轮换。Developer Bearer、AI channel 请求头或普通
  index GET 都不能签发或替代该能力，因此外部 Agent 也不能借通用审批接口批准自己的
  GDevelop 调用。
- 首次启动 URL 消费后，Windows WebView2 与 Flutter WebView 的宿主刷新统一加载无 query、
  无 fragment 的 workspace URL，并依赖已有 HttpOnly Cookie 恢复；任何平台都不得重放已经
  轮换的 `editorBootstrap`。平台层只实现 `load(Uri)`，稳定刷新地址由共享宿主代码生成。

## Gateway v4 路由职责

- `GET /dev/api/gdevelop/ai/tools`：返回唯一工具合约。
- editor-session：创建、读取、更新 locale/context 和 session-scoped `approvalMode`、关闭当前
  内存会话；设置模式的入口只接受 WebIDE 用户身份，不接受外部 Agent 身份。
- turn/call：创建 turn、入队 call、增量查询、批准后的 lease、取消和 execution 回传。
- session resource staging：为 Agent 资源工具提供一次上传、一次读取的有界内存字节。
- scoped events：只发送最小状态唤醒事件；call 增量查询仍是状态事实源。
- prompt/template：生成 Chat/Agent 提示词及管理用户模板覆盖。

这些路由不提供 AI 工程 `current`、工程快照、事件 payload 补交、correction、commit 或
recovery。Gateway 重启后旧内存 AI 会话失效；Web IDE 可以建立新会话，但不能恢复或重放旧
修改调用。

## 多人项目的可迁移约束

AI 只能创建官方 `Multiplayer::MultiplayerObjectBehavior` 和官方 GDevelop 事件语义。
Playmesh 的多人兼容层只替换运行时，不改变编辑器公开调用语义，也不把 Playmesh 专属 API
写进工程。因此：

- 在 Playmesh 运行时，官方 Multiplayer 调用由兼容层转发到 Playmesh SDK。
- 把同一工程迁入官方 GDevelop 并导出其他平台时，不携带 Playmesh 运行时替换，自动回到
  官方多人运行时。

这一约束必须由项目序列化测试和官方导出回归样例验证，不能只靠提示词约定。

## 测试要求

- Tool Schema：唯一合约、版本、数量、参数、未知/已删除工具、超限输入和执行元数据测试。
- context：官方摘要/场景/能力存在性、大小/深度和 Token/URL/Bridge 拒绝。
- 调用：输入在审批前锁定、幂等指纹、单 writer lease、超时和取消边界。
- 审批：弹窗可见性、四种决策、双击保护、项目/工具隔离、撤销与损坏授权 fail-closed；
  `request_approval -> always_allow` 立即释放当前 pending 和后续危险调用，
  `always_allow -> request_approval` 不回滚已排队调用，reattach 保留，close/Developer Mode
  重启恢复默认值，且外部 Agent 不能改设置。
- live project：官方函数收到当前页面同一个 `gdProject`；没有 clone、serializer transaction、
  history、reload、pending journal 或 recovery 路径。
- wrapper：事件、对象、扩展和资源修改分别触发正确的官方回调；dirty 通知在 HTTP 回传前
  恰好发生一次。
- 事件：完整 `GDevelopEventPayload 1.0.0` 与 call 同时入队、其他工具禁止 input、审批展示
  有界摘要、失败不自动纠错或重试。
- 结果：先缓存再回传、响应丢失只重发、不可序列化输出转换为固定失败、同 call 不重复执行。
- UI：粘贴前清空旧输入，执行后保留本次输入，复制返回状态不清空输入。
- 安全：任意 JS、外部 URL、直接 IndexedDB 和跨项目调用均被拒绝。
- 可迁移：生成工程不含 `playmesh.main.*`，官方 Multiplayer 行为保持原格式。
- 上游升级：`apply-source-policy.mjs` 在文件 Blob 或唯一源片段变化时立即停止。

## 风险与决策记录

- 官方 AI 与官方商业服务深度绑定，因此只复用开源编辑器工具和工程语义。
- Gateway 负责协调而不拥有工程内容，避免 App 历史与 Web IDE 内存工程形成两个写入真源。
- 直接修改 live project 意味着函数进入修改阶段后不能安全取消；实现通过前置审批、单 writer
  lease、非取消边界和结果幂等重发控制风险。
- 失败后不自动修改第二次。模型或用户必须读取当前实际工程状态，再决定新的独立调用。
- 移除 Playmesh AI overlay 和脚本注入即可恢复无 AI 的裁剪版 Web IDE；工程 JSON 与官方
  格式保持一致，不需要迁移用户工程。
