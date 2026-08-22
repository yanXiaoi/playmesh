# GDevelop 开发总规范

本文是 Playmesh GDevelop 开发的最高优先级规范，统一约束 WebIDE、Gateway、App、预览、发布、
运行时替换、AI、工程存储和内核升级。其他 `docs/gdevelop/` 文档只补充领域合同和操作步骤；
与本文冲突时，一律以本文为准。

本文中的“必须”“不得”都是发布门禁。现有实现、旧测试或历史文档与本文不一致，表示实现
仍需整改，不构成例外，也不得通过修改文档为旧实现背书。确有新架构需要突破本文时，必须先
修改并评审本文，再修改业务代码和专项文档。

## 1. 核心原则

Playmesh 只替换 GDevelop 依赖的官方在线服务、宿主能力或最低外部 I/O 来源。官方代码拿到
数据后的编辑器、工程和运行时处理流程必须保持官方实现、官方调用顺序和官方结果语义。

```text
Playmesh 外部边界
  鉴权 / 审批 / 目录 / 下载 / 上传 / 哈希 / 宿主能力
    -> 明确交接点
GDevelop 官方处理链
  反序列化 / 工程写入 / 注册加载 / 生命周期 / 回调 / UI 状态 / 结果与错误
```

不得因为下载包、目录、网络、存储或宿主由 Playmesh 提供，就复制、改写、包裹或再次验证
官方后续处理。

## 2. Ownership 与事实源

| 责任 | Playmesh 可以拥有 | 必须由 GDevelop 官方拥有 |
| --- | --- | --- |
| 外部服务 | 同源 Gateway、目录解析、鉴权、审批、下载、上传、重试 | 服务响应之后的编辑器处理 |
| 制品安全 | 固定版本、来源身份、路径安全、大小和 SHA-256 | 反序列化、origin、项目插入和注册加载 |
| 编辑器调用 | 协议到官方参数的薄适配 | `EditorFunctions`、活动 `gdProject`、官方结果 |
| 生命周期 | 真实官方依赖的透传 | context、callbacks、options、refs、状态和清理顺序 |
| 预览 | 宿主鉴权和最低 launcher I/O | 新预览、热刷新、自动保存和预览状态选择 |
| 运行时 | 精确 backend/I/O seam 的私有实现 | 公开事件 API、状态机、对象行为和工程格式 |
| 工程存储 | Playmesh current/history/CAS 的物理存储合同 | 官方工程序列化、分片、重组和编辑器打开语义 |

既有唯一事实源必须复用：

- 官方版本、commit 和 Playmesh revision：`webide-lock.json`；
- Playmesh WebIDE 源码：`playmesh/overlays/`；
- 共享浏览器 canonical 源：`public/developer/`；
- 官方源码接线：`apply-source-policy.mjs`；
- AI 工具合同：`runtime/ai/tools.json`；
- 输出摘要：`source-policy-output-manifest.json`；
- 分发实体：`resources/GDevelop/update.json` 与对应固定 ZIP。

不得维护第二份工具清单、第二套工程模型、第二个扩展注册表或只能靠手工重现的补丁。

## 3. 外部边界与官方处理链

### 3.1 进入官方函数之前

Playmesh 只可在明确的外部边界完成：

- Developer Gateway 鉴权、当前会话和用户审批；
- 参数 Schema、路径、文件名、大小和来源身份校验；
- 目录解析、制品下载、上传、超时和有限重试；
- 固定版本、依赖闭包和内容 SHA-256 校验；
- 宿主 capability 协商及其输入白名单；
- 进入官方函数所必需、且官方没有提供的协议 DTO 映射。

这些工作必须在官方处理开始前完成。前置校验不得读取官方处理结果来推断是否需要运行另一套
实现，也不得预先修改项目来“帮助”后续官方函数成功。

### 3.2 明确交接

取得官方函数所需输入后，必须立即调用锁定上游的官方函数，并原样传入真实的：

- 活动 `gdProject` 或其他活动 libGD 对象；
- React context 中的真实 state/controller；
- 官方 callbacks、options、refs、locale 和用户手势；
- 官方函数要求的序列化对象、资源或事件 DTO；
- 官方当前组件树选择出的具体动作函数。

禁止传入假对象、空实现、no-op loader、只返回成功的占位函数或本地“看起来已完成”的状态
判断。当前组件拿不到真实依赖时，应修复组件接线，不得伪造依赖绕过类型和生命周期。

### 3.3 官方处理开始之后

官方函数及其调用链拥有唯一处理权。Playmesh 不得：

- 复制或重写官方反序列化、注册、加载、工程写入或通知逻辑；
- 在官方调用后追加存在性检查、补注册、修复、再次写入或状态推断；
- 在官方失败后 fallback 到 Playmesh 自定义实现；
- 同时调用官方和自有两个 delegate，再比较结果选择一个；
- 改写官方返回对象、成功/失败语义或部分成功语义；
- 删除或绕过官方函数内部已有的兼容性、安全或完整性校验。

“不得后置校验”只禁止 Playmesh 追加的校验。官方实现自身的校验、返回值判断和生命周期必须
原样保留。

### 3.4 错误边界

Playmesh 只能在它拥有的外部 I/O seam 处理该 seam 的错误。不得用一个 `catch` 包住下载和
整个官方生命周期，也不得把反序列化、注册、回调、预览或编辑器错误统一标记成网络/下载
失败。

官方函数返回失败结果时，必须保留并传递官方 `output`、`message`、错误类型和修改标志；
Gateway 不得把它们压缩为统一 `output: {}`。官方函数抛出异常时，应保持可诊断的错误链，
只能删除 Token、凭据、内部 URL 等敏感数据，不能删除业务原因。错误展示可以本地化，但
本地化文案不能替代结构化诊断。

清理资源的 `finally` 可以存在，但只能释放本层创建的临时对象，不能修改官方结果、掩盖原始
错误或触发第二次业务处理。

## 4. 官方源码修改规范

官方文件只允许薄接缝：

- import Playmesh-owned 组件、provider、router 或 adapter；
- 在官方已有生命周期中挂载、卸载或注册最低 I/O driver；
- 原样转发官方对象和回调；
- 在官方已经做出状态选择后，转发被选择的具体函数；
- 对明确不可用的在线入口，在其入口处显式禁用并给出稳定状态。

官方文件不得承载 HTTP、存储、审批、业务状态机、错误归类、迁移或协议重写。不得用全局
正则批量把一组官方域名改成无效地址；每个被替换或禁用的在线服务都必须有精确、可审计的
调用 seam。未迁移服务应在明确入口 fail closed，不能让它继续运行到随机网络错误。

所有官方变更必须：

1. 锁定官方路径和 Git Blob SHA-1，生成文件锁定原始 SHA-256；
2. 使用唯一前像精确替换，命中零次或多次都失败；
3. 在策略步骤中写明 ownership 和不能更薄的理由；
4. 把业务主体放在 overlay/canonical 源；
5. 用正向、负向合同证明只调用一个 delegate 且参数完整透传；
6. 在全新官方树上 clean replay，拒绝污染树和二次 patch。

禁止直接维护 checkout、build、prepared、安装目录或最终 ZIP 内的修改。

## 5. AI 工具规范

AI 工具是 Gateway 协议到官方编辑器函数的薄适配，不是第二套 GDevelop 编辑器实现。

- 工具名、Schema、危险等级、执行类型和官方映射只来自 `runtime/ai/tools.json`；
- Chat 和 Agent 使用同一合同、审批、幂等和 live-project 语义；
- 官方工具调用必须进入同一个活动 `gdProject`，不能使用 clone 或替代工程；
- `ensureExtensionInstalled` 等官方依赖必须使用真实官方 hook，不能替换成本地存在性判断；
- wrapper 只处理官方函数没有覆盖的 Playmesh 外部输入，之后立即交还官方函数；
- 官方失败结果和 `output.message` 必须回传，不能统一为 `editor_function_failed`；
- AI 修改只触发官方刷新和 dirty 回调，不保存、不写 history/current/revision，也不自动回滚；
- 修改开始后不得伪装取消；响应丢失只能重发已冻结结果，不能再次执行。

扩展安装的固定链路是：

```text
Playmesh 目录 / 下载 / 固定身份 / 哈希 / 审批
  -> serializedExtensions
  -> 官方 addSerializedExtensionsToProject(
       来自 EventsFunctionsExtensionsContext 的真实 EventsFunctionsExtensionsState,
       活动 project,
       serializedExtensions,
       官方要求的来源名称
     )
  -> 官方 onExtensionInstalled
```

不得复制其中的反序列化、origin、注册加载或通知，也不得在完成后追加“是否安装成功”检查。

事件载荷可以在进入官方函数前验证 Gateway 合同、场景身份、大小、深度和敏感字段。开始调用
官方事件应用函数后，不得用 Playmesh 总 catch 抹去异常，也不得在部分写入后返回没有官方
诊断的统一失败。

## 6. 预览、发布与运行时替换

预览/刷新工具只能调用 EditorTabsPane 按官方工具栏状态选择出的
`launchNewPreview` 或 `launchHotReloadPreview`。工具不得自行选择 launcher、保存、打包、重试、
检查预览状态或补刷新；鉴权与审批仍由既有 Gateway session 负责。

运行时替换只允许位于固定上游的最低 backend/I/O seam：

- 不改公开 GDevelop 事件、对象行为、消息/变量管理和工程可见格式；
- 不全局替换 `fetch`、`WebSocket`、`localStorage`、`Peer` 或公开 `gdjs` API；
- 普通官方导出保持官方字节和官方 backend；
- Playmesh 预览/发布在完整 file map 上做精确路径、前像和入口引用校验；
- 能力缺失或版本不匹配时失败关闭，不回退到官方云服务或未授权 transport；
- 私有 façade 只接受固定 operation/DTO，并在每次调用时重新做 scope 和 schema 校验。

外部 façade 可以把其自身 transport 错误映射为固定安全代码，但一旦把输入交给官方状态机，
官方状态机产生的结果和错误仍按第 3.4 节保留。

发布重试必须依据可证明的提交状态：writer 尚未产生正文时可经用户确认切换官方 BlobWriter；
结构化响应只有明确给出 `committed: false` 才允许自动重试。产生正文后的网络错误或 Abort 不能
证明服务端未提交，客户端必须停止自动重试并提示用户先检查本地游戏库。

## 7. 工程存储、导入与历史

Playmesh 可以拥有 current/history/CAS、原子目录替换、配额、资源 presence 和物理文件传输。
这些是宿主存储合同，不得成为替代官方编辑器处理的理由。

- WebIDE 中的拆分、重组、序列化和反序列化优先直接调用锁定上游官方实现；
- App 为只读列表、diff、CAS 或事务证据实现的等价算法只能服务宿主存储，不能回流为
  WebIDE 的第二套打开/保存实现；
- 自有 ZIP、资源、身份和路径处理必须在交接给官方 opener/serializer 前完成；
- 调用官方打开、恢复或替换工程后，不得再次校验或修补官方内存工程；
- 不得把官方打开失败登记成“下载成功但导入失败”之外的错误类型，更不能自动重新导入或
  创建第二份项目；
- History/current 不得改变官方 dirty、保存和用户决定是否保留修改的语义。

## 8. 鉴权、审批与安全

- Token 只出现在规定的 Gateway 鉴权位置，不进入项目、工具参数、日志或官方错误输出；
- 首次 workspace 链接中的 Developer Token 只用于 bootstrap；验证后必须设置 `HttpOnly`、
  `SameSite=Strict` Cookie，以 303 跳转到移除 query 的地址，并设置
  `Referrer-Policy: no-referrer`。跳转前 URL 仍可能进入导航历史，不得宣称 Token 从未进入 URL；
- Chat prompt 不含 Token。Agent prompt 使用持久根 Developer Token 时，必须明确它拥有完整
  Gateway 权限；审批只是 UX 确认，不是针对根 Token 持有者的权限边界；
- 关闭开发者模式必须关闭 Gateway 并清除内存 session/turn/call/对话状态，但不得暗示已自动
  轮换或删除持久 Token；
- 审批只授权行为，不代表保存、提交、历史快照或成功；
- 所有写工具在输入完整锁定后审批，审批后不得替换参数或事件载荷；
- 任意 JavaScript、任意 URL、任意网络、直接 IndexedDB 和跨项目访问必须拒绝；
- 私有 runtime façade 不是安全边界，宿主必须逐次验证当前 game/session/player scope；
- 错误诊断保留业务原因时仍须剔除凭据、内部地址和原始 transport handle。

## 9. 测试与发布门禁

每项变更至少证明：

1. 外部边界和官方交接点被明确列出；
2. 真实 context/callback/options 按对象身份透传；
3. 官方函数和生命周期回调按原顺序各调用一次；
4. 不存在假 context、空 loader、本地存在性替代或双 delegate；
5. 不存在官方调用后的 Playmesh 校验、补写、修复或 fallback；
6. 下载错误与官方处理错误不会互相误分类；
7. 官方失败 `output/message` 能穿过 WebIDE、Gateway 和 Chat/Agent 状态；
8. 真实 libGD/官方函数在一次性工程完成读、写、回读及官方刷新/dirty 证明；
9. 普通官方导出零 Playmesh 注入，Playmesh 预览/发布只在批准 seam 生效；
10. Flow、定向合同、源码策略、生产 build、包内审计和受影响宿主测试通过。

发布还必须满足：

- 所有输出摘要来自本轮全新干净树并已冻结；
- `source-policy-output-manifest.json` 没有 `pending`；
- strict clean replay、污染拒绝和二次重放拒绝通过；
- 最终 ZIP、SHA-256、精确大小、provenance 和 `update.json` 一致；
- WebIDE 下载线路只允许无凭据的绝对 HTTP 或 HTTPS URL；HTTP 是维护者明确接受的传输降级，
  SHA-256 只能证明下载内容匹配可信清单，不能在清单也经 HTTP 获取时证明发布者身份；
- 未执行项、已知不合规项和实机待验收项被明确披露。

`dev-package`、pending override、旧 receipt、历史测试结果或本地空下载 URL 验证都不是正式
发布证据。

## 10. 冲突处理与审计

发现文档或实现冲突时按以下顺序处理：

1. 以本文确定允许的 ownership 和调用边界；
2. 核对锁定上游的真实源码、类型和生命周期；
3. 将冲突登记为实现缺口，不得把旧行为解释成例外；
4. 先补能证明正确边界的失败测试，再修改 canonical 源或最小接线；
5. 规则变化同步专项规范，接线变化同步接线索引，交付变化同步版本摘要；
6. 从干净上游树重放并冻结新的输出摘要。

审计结论必须区分事实、推测和风险。没有源码证据时不能把“可能是官方不支持”写成结论；
发现错误被中间层抹去时，应先修复结果透传，再依据真实官方诊断判断业务原因。
