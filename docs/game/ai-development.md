# AI 游戏开发

Playmesh 把 AI 接入项目创建、代码修改、结构化校验、真实运行和日志诊断的完整流程。
平台不是提供一段与项目无关的通用提示词，而是根据当前游戏动态组装模式、显示拓扑、
页面角色、项目树、公开 SDK 类型声明、能力上下文和 Developer Operation 契约。

Playmesh 支持两类互补的 AI 工作流：

| 工作流 | 适合的 AI | 如何操作项目 | 开发者参与方式 |
| --- | --- | --- | --- |
| [ChatAI](chat-ai-development.md) | 普通文字对话 AI | 返回可粘贴到“对话控制台”的 JSON 指令 | 在 AI 与工作区之间传递指令和结构化结果 |
| [AgentAI](agent-ai-development.md) | 能调用本地 HTTP 工具的 Agent | 直接调用 Developer Gateway API | 监督执行、处理审批并在真实设备上验收 |

两种方式都操作统一游戏库中的真实项目，共用 SDK、校验器、运行时、审批、本地历史和
日志，不使用额外的 AI 项目格式、测试服务器或模拟 SDK。

## 准备工作

1. 在 Playmesh App 设置中开启开发者模式。
2. 复制完整工作区链接，或直接在 App 内打开工作区。
3. 创建项目或选择已有项目。
4. 打开工作区“AI”页面，填写公共“自定义想法”。
5. 根据 AI 类型获取“对话提示词”或“Agent 提示词”。

项目提示词会按当前 `modes`、`displayModes`、页面角色和能力声明，只加入完成任务
需要的公开契约与项目结构；项目文件内容由 AI 再按任务需要读取。

## 选择哪一种

- 只想使用现有聊天 AI、不愿授予本地连接能力时，选择
  [ChatAI 使用方法](chat-ai-development.md)。
- 希望 AI 自主读取文件、修改、校验并运行，且所用 Agent 能访问 Developer Gateway
  时，选择 [AgentAI 使用方法](agent-ai-development.md)。
- 可以先用 ChatAI 讨论玩法与结构，再把明确的实现目标交给 AgentAI；两者始终操作同一
  项目，不需要导入导出中间工程。

## 危险操作审批

Agent 和对话控制台都会携带 `X-Playmesh-AI-Channel`。操作定义中
`dangerous=true` 的请求会暂停，并通过工作区 SSE 请求用户选择：

- 允许一次；
- 对当前游戏或项目允许；
- 始终允许；
- 拒绝。

未批准前不能删除项目、删除文件或执行 WebView JavaScript。30 秒未处理返回
`408 ai_approval_timeout`，拒绝返回 `403 ai_operation_rejected`。

## 能力与 SDK

- 对话提示词只携带当前项目已声明能力的完整描述符。
- Agent 通过 `GET /dev/api/capabilities` 按需读取全平台注册表。
- 能力自检使用 `GET/POST /dev/api/capability-tests`。
- `.d.ts` 是公开 SDK 方法、参数、返回值和中文 JSDoc 的接口事实源。
- 非敏感权限和用户主动文件选择直接使用标准 Web API，不需要能力声明；WebView 敏感
  权限和 Playmesh 多平台适配能力才按需写入 `capabilities.json`。
- 游戏仍需先等待 `playmesh.ready`，不能因为由 AI 生成就绕过 Player/Authority 分层。

## 最小披露原则

游戏开发 AI 只需要知道：

- 可调用的 Game SDK / App SDK；
- 当前项目树、模式、角色和能力声明；项目文件内容通过 Developer API 按任务需要读取；
- Developer Operation API；
- 校验结果、运行状态和当前设备日志。

不得向游戏开发提示词加入：

- 回环代理和内部路由；
- Core 地址、凭证或帧格式；
- 中转鉴权、密钥协商和加密记录层；
- App 用户私有资料或其他游戏项目；
- 开发者 token 以外的任何平台密钥。

## 完成检查

- 项目校验不存在 `error`。
- 游戏只访问外层物理 `app/` 映射出的运行时根 `/`、平台 `/playmesh/**` 和 SDK
  返回的 `/bucket/**`。用户首段 `app` 合法：物理 `app/app/**` 映射为
  `/app/**`，只有 `playmesh`、`bucket` 是保留首段。
- 多人最终结果由 Authority 决定。
- 页面不会根据加入链路分叉协议。
- 能力先声明、再确认、再创建，并在退出时释放。
- 日志中没有完整 token、凭证或私有路径。
- 修改已进入项目本地历史，可以从工作区审阅和恢复。

更多说明：

- [ChatAI 使用方法](chat-ai-development.md)
- [AgentAI 使用方法](agent-ai-development.md)
- [游戏开发指南](development-guide.md)
- [网页开发者通道](web-dev-channel.md)
- [Game SDK / App SDK](sdk-v1.md)
- [游戏包与 main.json](package-format.md)
