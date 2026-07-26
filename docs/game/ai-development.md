# AI 游戏开发

Playmesh 支持两类 AI 工作流：

- **对话 AI**：读取完整项目提示词，返回可粘贴到工作区“对话控制台”的 JSON 指令。
- **API Agent**：持有用户选择的 Developer Gateway Base URL 和 token，直接调用
  Developer Operation API 完成读取、修改、校验、运行和日志诊断。

两种方式都操作统一游戏库中的真实项目，不使用额外的 AI 项目格式、测试服务器或
模拟 SDK。

## 准备工作

1. 在 Playmesh App 设置中开启开发者模式。
2. 复制完整工作区链接，或直接在 App 内打开工作区。
3. 创建项目或选择已有项目。
4. 打开工作区“AI”页面，填写公共“自定义想法”。
5. 根据 AI 类型获取“对话提示词”或“Agent 提示词”。

项目提示词会按当前 `modes`、`displayModes`、页面角色和能力声明，只加入完成任务
需要的公开契约与源码。

## 对话 AI 工作流

```text
获取项目对话提示词
  -> 发送给对话 AI
  -> AI 返回一个 JSON 指令对象或数组
  -> 粘贴到工作区“对话控制台”
  -> 预览和执行
  -> 校验项目
  -> 运行并查看日志
  -> 把错误和相关源码继续交给 AI
```

对话控制台指令包含：

```json
{
  "method": "GET",
  "path": "/dev/api/projects/com.example.game/file?path=app/index.html"
}
```

修改多个文件时优先使用：

```text
POST /dev/api/projects/{projectId}/file-changes/preview
POST /dev/api/projects/{projectId}/file-changes/apply
```

`apply` 必须提交预览返回的 `baseRevisions`，避免覆盖用户或另一个工作区刚完成的修改。

## Agent 工作流

Agent 提示词生成时必须选择 Agent 所在电脑能够访问的局域网 Base URL。Agent 使用：

```http
Authorization: Bearer <developer-token>
X-Playmesh-AI-Channel: agent
```

推荐闭环：

1. 读取 `/dev/api/operations?target=agent` 和项目文件。
2. 读取 Game SDK 声明、当前 Manifest 和能力注册表。
3. 使用结构化文件变更接口预览并原子提交。
4. 调用项目校验接口，修复全部 `error` 诊断。
5. 请求 App 启动或重启项目。
6. 轮询运行状态并读取最近日志；需要实时体验时再消费 SSE。
7. 结合 `requestId`、`projectId`、`runId` 和 `eventId` 定位本次运行。

Agent 不应自行拼接未记录的 API，也不能直接访问游戏目录、Core 或系统命令。

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
- 游戏仍需先等待 `playmesh.ready`，不能因为由 AI 生成就绕过 Player/Authority 分层。

## 最小披露原则

游戏开发 AI 只需要知道：

- 可调用的 Game SDK / App Bridge SDK；
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
- 游戏只访问 `/app`、`/playmesh` 和 SDK 返回的 `/bucket`。
- 多人最终结果由 Authority 决定。
- 页面不会根据加入链路分叉协议。
- 能力先声明、再确认、再创建，并在退出时释放。
- 日志中没有完整 token、凭证或私有路径。
- 修改已进入项目本地历史，可以从工作区审阅和恢复。

更多说明：

- [游戏开发指南](development-guide.md)
- [网页开发者通道](web-dev-channel.md)
- [Game SDK / App Bridge SDK](sdk-v1.md)
- [游戏包与 main.json](package-format.md)
