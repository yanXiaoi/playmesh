# AgentAI 使用方法

AgentAI 是 Playmesh 面向具备本地 HTTP 工具调用能力的 AI Agent 的游戏开发方式。
Agent 获得当前项目生成的完整提示词后，可以直接调用 Developer Gateway，完成按需
读取、原子修改、校验、运行和日志诊断，不需要开发者在每一轮手工搬运 JSON。

AgentAI 操作的仍是 Playmesh 游戏库中的真实项目，并与网页工作区共享校验器、运行时、
审批、本地历史和日志。它不是另一套 AI 专用工程格式。

## 开始前准备

1. 从 Playmesh App 首页进入“制作游戏”，开启开发者模式并展开“源代码开发”，同时保持 App 和 Developer Gateway 运行。
2. 在 App 内或电脑浏览器中打开“源代码开发”工作区。
3. 创建游戏项目，或选择需要修改的已有项目。
4. 点击工作区顶部的“AI”，填写公共“自定义想法”。
5. 点击“获取项目提示词”，切换到“Agent 提示词”。
6. 选择 Agent 实际能够访问的“连接地址”，复制完整提示词或下载 TXT。

如果 Agent 与 App 在同一台主机且共享网络环境，可以使用本机地址。Agent 运行在容器、
虚拟机或另一台电脑时，`127.0.0.1` 往往只指向 Agent 自己，应选择 App 展示的局域网
地址，并确保两端网络和防火墙允许访问。

项目模式、显示模式、能力声明、Developer Gateway 地址或 token 发生变化后，应重新
生成 Agent 提示词。

## 启动 Agent 任务

将完整 Agent 提示词交给支持工具调用的 Agent，然后描述目标和验收条件。例如：

```text
请直接完成当前 Playmesh 游戏的回合系统和结算页面。保留现有视觉风格，
先读取必要文件，使用原子变更接口修改，随后执行校验、重启游戏并检查最近日志。
```

Agent 提示词已经包含当前项目上下文、真实 Developer Operation 目录、SDK 类型声明、
选定的 Base URL 与 Bearer token。Agent 应：

1. 只按任务需要读取项目树中的文件。
2. 修改前读取文件 revision。
3. 多文件修改优先预览并原子应用。
4. 通过专用 API 修改 `main.json` 和 `capabilities.json`。
5. 完成后实际校验，修复全部 `error`。
6. 启动或重启项目，轮询运行状态并读取最近日志。

Agent 的每个请求都必须携带：

```http
Authorization: Bearer <提示词中的 developer token>
X-Playmesh-AI-Channel: agent
```

不应删除 Agent 通道标识来绕过审批，也不应猜测提示词和 Operation 目录中不存在的
接口。Developer Gateway 不提供任意系统命令执行能力；Agent 只能在当前 Playmesh
项目和已注册操作的边界内工作。

## 观察执行过程

Agent 可以直接完成大部分闭环，但开发者仍应保持工作区可见，用于：

- 查看文件变更、Diff 和本地历史；
- 响应危险操作审批；
- 观察校验、运行状态和 Console 日志；
- 在真实设备上试玩触控、方向、多人连接和平台能力。

读取、写入、校验和日志等后台接口可以持续工作；启动、重启、WebView JavaScript 和
平台能力自检等需要真实页面的操作，要求 App 位于前台、设备已解锁且窗口可交互。

## 审批与安全

标记为 `dangerous=true` 的请求会暂停，并通过工作区请求开发者审批。可以允许一次、
对此游戏或项目允许、始终允许，或拒绝。30 秒内未处理会超时；Agent 应保留原始任务
上下文，等待你处理后再安全重试。

Agent 提示词包含持久 Developer Gateway token，应按敏感凭证管理：

- 只发送给可信 Agent，不要发布到聊天截图、日志、Issue 或代码仓库。
- 不要把工作区完整链接或 Agent 提示词转发给无关人员。
- 使用结束后关闭开发者模式，可立即停止 Gateway 对外提供服务。
- 怀疑 token 泄露时，在 App 首页“制作游戏”页关闭开发者模式、更换 token，再重新开启并生成提示词。

Agent 不能通过 Gateway 读取 App 账号 token、用户私有资料、其他项目或任意系统文件。
不要授权它使用其他本地工具绕过 Playmesh 项目沙箱。

## 常见问题

- **无法连接 Base URL**：确认开发者模式已开启；检查所选地址是否能从 Agent 所在环境
  访问。容器或另一台设备通常应使用局域网地址，而不是 `127.0.0.1`。
- **返回 `401`**：提示词中的 token 已失效或请求未携带正确 Bearer token，重新生成
  Agent 提示词。
- **返回 `403 ai_operation_rejected`**：危险操作被拒绝；检查目标后重新发起，不要
  绕过审批。
- **返回 `408 ai_approval_timeout`**：工作区未在时限内处理审批；打开工作区后重试。
- **返回 `409 app_view_unavailable`**：操作需要可见 App 页面；解锁设备并让 App
  回到前台后重试。
- **文件 revision 冲突**：Agent 应重新读取文件与 revision，再重新生成变更预览，
  不能强行覆盖。

## 完成检查

- Agent 实际执行了项目校验，且没有 `error`。
- 游戏已在真实 WebView 中启动或重启。
- Agent 读取并检查了本次运行的状态和最近日志。
- 开发者已试玩关键流程，尤其是多人拓扑和硬件能力。
- 工作区 Diff 与本地历史中的变更范围符合任务目标。
- 最终回复没有泄露 token、完整工作区链接或私有路径。

相关文档：

- [AI 游戏开发总览](ai-development.md)
- [ChatAI 使用方法](chat-ai-development.md)
- [网页开发者通道](web-dev-channel.md)
- [游戏开发指南](development-guide.md)
- [开发者工作区开发约定](../platform/developer-workspace-development.md)
