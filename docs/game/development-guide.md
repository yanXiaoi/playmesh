# 游戏开发指南

## 开发模型

Playmesh 游戏是由 App 托管的 HTML/CSS/JavaScript 应用。Flutter 负责游戏容器、平台交互和联机链路，Go Core 负责权威会话与消息路由，游戏只通过 Game SDK 与 App SDK 访问这些能力。

```text
游戏页面
  -> /playmesh/sdk/v1/playmesh-main.js
  -> App 宿主或局域网浏览器入口
  -> Go Core 会话
  -> Authority Runtime
```

局域网 App、公共中转 App 和局域网浏览器使用同一套 SDK 语义；链路选择、加载来源和传输安全由平台处理。游戏代码不能直接访问 Bridge、Core 地址、分享参数、内部 token 或任意文件系统，也不能按玩家的加入方式分叉会话协议。

## IDEA 与 CLI 开发

Playmesh CLI 允许在 IDEA 中编辑本地副本、在目标 Windows 或 Android App 中运行，同一套命令和目录结构跨平台使用。先从 App 首页进入“制作游戏”，开启开发者模式，展开“源代码开发”并复制完整工作区链接，然后执行：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli init
# 或使用 playmesh-cli get <project-id> 拉取既有项目
npm run dev
```

目标 token 由 Windows DPAPI、macOS Keychain 或 Linux Secret Service 保护，不写入
项目或 `playmesh-cli.json`。CLI 2.0 不迁移旧版明文目标配置，遇到旧格式时必须重新
执行 `playmesh-cli to`。

CLI 2.0 的 `init` 统一承担项目创建：无平台参数时用数字选择 JavaScript 或
TypeScript，并生成根 `package.json`、`src/`、`jsconfig.json/tsconfig.json`、
`playmesh-cli.json`、隔离的 `playmesh/package` 与 `playmesh/sdk`。IDEA 可直接运行
npm `dev` 脚本，把本地开发 Web 根通过受控代理交给真实 App，并持续输出日志。
JavaScript 直接提供 `src/`；TypeScript 启动时先构建一次，并在源码变化后的资源
请求上重新构建。TypeScript 首次运行前需要 `npm install`。

`get` 是 JavaScript 已有项目和损坏项目的拉取通道；在空目录中固定生成 JavaScript
2.0 工程。App 只保存编译后的发布 JavaScript，不能还原 TypeScript 类型或 Cocos
工程，所以这两类项目必须从源码版本库恢复。`get` 只允许在空目录执行，不更新现有
工程。`run` 由适配器完成正式构建、完整上传和启动，但不附加日志；`logs` 只跟随
当前日志；`dev` 使用本地开发资源代理运行并跟随日志，只有目标 App 尚无当前项目时
才上传最小基础包。
`update` 更新 SDK 后按 `integration.type` 刷新语言或 Cocos 适配器。项目创建、正式
发布运行和集成更新分别只通过 `init`、`run` 与 `update`，不保留并行旧入口。

CLI 2.0 与本次 App 资源协议构成同步破坏性更新，不兼容根目录直接包含
`main.json`、`app/`、`playmesh/sdk/` 的 1.x CLI 布局。`playmesh-cli.json` 默认使用
`integration.outputDirectory: "."` 和 `integration.entry: "index.html"`：前者
相对于外层物理 `packageRoot/app/`，后者相对于同一个 Web 根。用户首段 `app` 不做
特殊处理，例如 `integration.entry: "app/index.html"` 对应物理
`packageRoot/app/app/index.html` 和运行时 `/app/index.html`；只有 `playmesh`、
`bucket` 是平台保留首段。

`playmesh-cli init cocos` 可在 Cocos Creator 3.x 中创建隔离发布目录、类型入口和
项目级扩展。扩展选择浏览器预览地址的优先级固定为 Playmesh `dev` 消息显式参数、
`PLAYMESH_DEV_SERVER_URL` 环境变量、
`playmesh-cli.json.integration.developmentServerUrl` 配置项。Creator 3.8 的公开
扩展 API 没有稳定且有文档支持的当前预览 URL 查询接口；没有消息参数时必须设置
环境变量或配置项。自动化契约测试已覆盖这三个来源及其优先级，但当前环境尚未在真实
Cocos Creator Editor 中验收菜单调用和预览生命周期。

已安装游戏不依赖 CLI 工程文件；App 会严格校验清单版本，只接受 Game SDK `4.1.0`，
并接受 App SDK `3.2.0` 或 `3.3.0`。兼容的 `3.2.0` 请求解析到当前 `3.3.0` bundle。完整命令、迁移边界与 Cocos
集成见
[`dev-cli/README.md`](../../dev-cli/README.md)。

## 开发者工作区对话控制台

Playmesh 不提供独立的 App 文件编辑器。电脑浏览器与 App 内置 WebView 均打开同一个开发者工作区。纯聊天 AI 输出一个 JSON 指令对象或数组，用户只需粘贴到“对话控制台”；控制台在上方接收指令，在下方返回状态码、请求 ID、修订号和响应体。

每条指令使用 `method`、同源 `/dev/api/**` `path` 和可选 JSON `body`。默认提示词只内嵌操作目录、项目/文件读取、创建或完整替换文件、精确替换/插入、批量文件变更和校验等基础指令；完整目录通过 `GET /dev/api/operations?target=chat` 获取。旧分段文本快速操作协议已经删除，不再兼容。

`POST /dev/api/projects/{projectId}/file-changes/preview` 接受 `create`、`replace`、`replace_text`、`insert_before`、`insert_after` 结构化变更，返回结果和 `baseRevisions`；`apply` 端点校验同一批修订后原子写入。所有路径相对于项目根，源码通常使用 `app/...`；不能访问 `data/`、`cache/`、其他游戏、App 私有目录或系统路径。每次确认的修改进入项目级本地历史，并通过 SSE 同步到所有已打开工作区。

对话控制台自动携带 `X-Playmesh-AI-Channel: chat`；Agent 必须携带值为 `agent` 的同一请求头。注册表中 `dangerous=true` 的接口在所有 AI 通道上先暂停，通过 SSE 向工作区展示“允许一次 / 此游戏或项目允许 / 始终允许 / 拒绝”。30 秒未决定时原请求返回 `408 ai_approval_timeout`，拒绝返回 `403 ai_operation_rejected`。

当前项目运行后，“更多 → WebView JS 操作台”可复用 JavaScript CodeMirror 编辑器，在当前游戏的顶层 WebView 文档中执行代码，并在下方展示 `resultType`、返回值、运行实例和请求 ID。成功结果与执行错误仅按项目保存在当前页面会话内存中，可由“历史记录”在本次会话重新载入；刷新或关闭页面后丢弃。对应接口为 `POST /dev/api/projects/{projectId}/webview/javascript`，请求体是 `{"source":"document.title"}`；它声明为高风险 `dangerous=true` 并同时暴露给 Chat 和 Agent，因此 AI 调用必须先走上述 SSE 审批，开发者从操作台手动执行则不附加 AI 通道头。

工作区还支持在项目树中右键新建或删除文件与文件夹，并将本地文件上传到指定目录。也可以把文件拖到根节点、文件夹或某个文件上；拖到文件时上传到其所在目录。只有 `.zip` 文件提供解压入口，剪切后目标目录才显示“移动到这里”。当前编辑缓冲区尚未保存内容的撤销与重做由 CodeMirror 管理；服务端不提供独立的单文件撤销接口。

代码编辑器会按文件类型提供 HTML、CSS 和 JavaScript 补全，并在 JavaScript 上下文中注入完整 `playmesh` SDK 方法树。输入 `<`、CSS 的 `:` 或 JavaScript 的 `.` 会触发相关提示，也可以随时按 `Ctrl+Space` 或 `Alt+/`。编辑器自身的第三方依赖集中在 `public/developer/editor/`；游戏需要的外部浏览器依赖应上传或解压到项目 `app/` 内，再从游戏代码引用。

本地历史位于 `packages/{gameId}/cache/developer/local-history/`，采用初始基线加逐时间操作的变更后快照。连续编辑按 5 分钟滚动窗口合并，工作区可按文件、文件夹或整个项目查看 Diff，并将指定范围恢复为某次操作的变更前或变更后状态。恢复整个项目时 `main.json` 始终由平台保留。

新建项目可选择单机或联机。源码工作区的“新建项目”和 Developer CLI 的 `init` 要求项目 ID 直接满足 Android applicationId 规则：至少两个点分段，每段以 ASCII 字母开头，其余只能使用 ASCII 字母、数字或下划线，最长 64 个字符；输入框旁可一键生成符合该规则的随机 ID。该限制只作用于这两个新建入口，复制、导入、GDevelop 和旧项目仍沿用既有 gameId 兼容规则。单机骨架使用 `modes: ["solo"]`、`displayModes: ["multi_screen"]` 和玩家 `1/1`，不生成控制器与 Authority 入口；联机骨架根据显示模式生成普通多屏或单屏多人结构。AI 修改后先调用 `/dev/api/projects/{projectId}/validate`，只有不存在 `error` 诊断时才能运行。已运行项目可通过工作区“重启”按钮或 `POST /dev/api/projects/{projectId}/run/restart` 重载游戏运行时，并保留当前分享信息。

需要重置调试存档时，先退出正在运行的游戏，再使用工作区“清理游戏数据”按钮。该操作只删除当前项目的 `data/`，不会清理 `cache/`、项目源码或开发历史。

浏览器工作区继续使用 SSE 接收实时事件；不方便维护流式连接的 API Agent 可调用 `GET /dev/api/logs?limit=50` 获取最近最多 50 条运行日志，并调用 `GET /dev/api/projects/{projectId}/run` 轮询运行状态。日志接口接受可选的 `projectId` 和 `runId` 查询参数，仅返回指定运行实例；每条日志包含稳定的 `eventId`，可用于合并缓存回放与 SSE 时去重。底层内存缓存最多保留 500 条且不写磁盘。

API Agent 的最小上下文入口是 `/dev/api/ai-context`，其中列出持久工作区 token 的全部接口、鉴权、SDK Manifest、OpenAPI 和 Schema。主工作区点击“AI”直接进入统一页面，接口文档作为只读项与提示模板同页展示。纯聊天 AI 使用 `/dev/api/projects/{projectId}/chat-prompt.txt`，其能力上下文只包含当前项目已勾选能力的完整声明；可直接调用接口的 Agent 使用 `/dev/api/projects/{projectId}/agent-prompt.txt`，不内嵌全量能力声明，而是明确提供 `GET /dev/api/capabilities` 全量注册表 API 与 `GET/POST /dev/api/capability-tests` 测试 API。`GET /dev/api/status` 的 `baseUrls` 枚举当前设备可用的 HTTP 地址；Agent 端点接受可选 `baseUrl` 查询参数，但只允许使用该枚举中的地址。平台按当前 `main.json.modes/displayModes` 只拼接相关 SDK、角色语义、强制文件和当前项目源码；公共“自定义想法”同时合入两类文本，Agent 文本额外包含所选 Gateway 地址、Bearer token 与项目文件、校验、运行/重启、日志轮询和可选 SSE 接口。两份最终文件固定为 UTF-8 BOM TXT，并都在醒目的“获取项目提示词”入口中复制或下载；工作区还可通过“复制全平台能力”独立调用注册表 API，复制与项目勾选无关的全部完整声明。手机端应为 Agent 选择电脑端 AI 能访问的局域网 Base URL。模板覆盖保存在 `playmesh-library/developer/ai-prompts/`；项目本体统一保存在 `playmesh-library/packages/{gameId}/`，使用正式已安装资源流程。

> **AI 上下文最小披露原则：面向游戏开发 AI 的提示词，只提供完成当前任务所必需、可由游戏代码调用或必须遵守的公开契约。凡属回环代理、内部路由、中转鉴权、密钥协商、加密通道等平台实现，均不得进入提示词；此类信息只保留在平台架构与维护文档中。**

## 运行模式

`main.json.modes` 声明单机或多人能力：

- `solo`：不需要多人会话。
- `multiplayer`：需要 `authority.entry`，规则由 Authority Runtime 执行。

`main.json.displayModes` 声明页面拓扑：

- `multi_screen`：所有设备加载显式声明的 `entries.game`。创建会话的 App 主机固定为
  Authority Client，并可同时作为 Player；不得从首位玩家或加入顺序推断 Authority。
- `single_screen_multiplayer`：主机加载显式声明的 `entries.game` 作为公共显示端与
  Authority Client；所有玩家加载同样显式声明的 `entries.controller`，主机不计入
  `players`。

游戏必须且只能声明一种显示模式。平台根据该 `displayMode` 决定页面入口，游戏不能根据二维码自行决定入口。

## 推荐目录分层

```text
{gameId}/
  main.json
  capabilities.json   # 可选能力声明
  icon.png            # 可选游戏图标
  app/
    index.html
    controller/index.html
    static/
      js/
        player/       页面展示、输入和 SDK 订阅
        service/      Authority 规则、校验和结算
        shared/       类型、常量和无副作用纯函数
      css/
      image/
  data/               本机运行时生成，不进入发布包
  cache/              平台缓存，不进入发布包
    developer/local-history/
```

开发者工作区的项目根对应 `packages/{gameId}/`，主页面路径由显式必填的
`entries.game` 决定。默认模板将其写为 `index.html`，并解析到物理
`app/index.html`。WebView 把物理 `app/` 直接映射
为运行时 `/`；`data/` 和 `cache/` 由平台管理，不显示在普通项目树中，也不参与静态
映射。CLI 本地 `playmesh/sdk/` 是开发工具与类型目录，永不上传；运行时
`/playmesh/**` 始终由 App 提供。

| 层 | 允许职责 | 禁止职责 |
|---|---|---|
| 玩家运行层 | 渲染 UI、采集输入、提交动作、展示权威消息 | 决定最终分数和胜负、伪造玩家身份、直接连接 Core |
| 权威处理层 | 验证动作、维护状态、生成题目、计分、定向或广播结果 | 操作 DOM、读取按钮、依赖页面临时变量、创建 WebSocket |
| 共享数据层 | 类型、常量、序列化结构、纯函数 | 保存会话状态、发送消息、执行权限判断 |

`authority.entry` 是权威代码的清单入口。当前运行方式仍要求主机页面引入该清单
声明解析出的脚本，并只在 `playmesh.main.session.isAuthority()` 为 `true` 时调用
`playmesh.main.authority.onService()`；控制器页面不得注册权威服务。入口始终相对
物理 `app/`，不得在代码中硬编码默认文件来覆盖清单。

## SDK 初始化

所有页面先引入公共 SDK，再等待 `playmesh.ready`：

```html
<script src="/playmesh/sdk/v1/playmesh-main.js"></script>
<script type="module" src="/static/js/player/index.js"></script>
```

```js
const ready = await playmesh.ready;

const session = playmesh.main.session.getCurrent();
const player = playmesh.main.player.getCurrent();
console.log(ready.main.sdkVersion, playmesh.app.runtime.getLocale());
```

游戏只显式引入 `playmesh-main.js`，平台会在 App WebView 和普通浏览器中先注入
`playmesh-app.js`。Game SDK `4.1.0` 在 `playmesh.main.*` 提供所有平台一致的游戏
声明、会话、玩家、角色、联机、生命周期和 Authority 主机存储 API；App SDK
`3.3.0` 在 `playmesh.app.*` 只提供当前终端的平台环境、身份、设备能力、权限、
输入、性能、当前设备存储、本机 Console 日志、locale、外部 HTTP(S) 链接打开和覆盖层。面向游戏代码的唯一全局对象是
`window.playmesh`，其根级公开成员严格只有 `ready`、`main` 与 `app`；
`window.playmeshApp` 与公开 `__*` 内部桥接均不存在。`playmesh.main.ready` 内部先
等待 `playmesh.app.ready`，再完成 Game 域初始化；根 `playmesh.ready` 是唯一例外，
只复用 `main.ready` 初始化链并返回 `{ main, app }`。旧 `playmesh.js` 和其他 `playmesh.<旧游戏域>` 根路径
均不兼容、不保留。普通浏览器的 `playmesh.app.isAvailable()` 为 `false`，但统一
网页覆盖层仍可使用。性能浮层唯一由 App SDK 创建，Game SDK 不创建浏览器性能
panel。App SDK 不复制游戏状态，游戏也不得手动设置玩家 ID。

需要从用户点击等真实操作打开外部网页时，使用
`playmesh.app.resource.openExternal(url)`。App WebView 会交给系统默认浏览器，普通
浏览器会新开窗口；只接受 `http:`/`https:`。SDK 不提供任意本地文件打开接口：网页
`File`/`Blob` 没有可交给外部浏览器的本机路径，游戏也不能借此访问宿主文件系统。

大屏公共显示端的 `player` 为 `null`。页面必须允许该值为空，不能把 Authority 自动加入玩家集合。

## 游戏业务国际化

Playmesh 的 App 词典只翻译平台自己的覆盖层，不会提供给游戏。游戏在
`await playmesh.ready` 后调用同步只读 `playmesh.app.runtime.getLocale()`，取得当前
实际显示端的 locale，并使用游戏包内自己的语言资源渲染业务界面：

```js
await playmesh.ready;
const locale = playmesh.app.runtime.getLocale();
renderGameMessages(locale);
```

App WebView 返回本机 App locale；远程加入设备不会继承 Authority 主机语言。普通
浏览器直接读取 `navigator.languages`、`navigator.language` 中第一个合法系统
locale，失败回退 `zh`；该返回值不受 Playmesh 覆盖层支持语言限制。SDK 不向
游戏公开 `app.json` 或 messages，Playmesh 也不会自动翻译游戏 DOM、资源、标签、
用户内容或日志。

## 多人动作与 Authority

玩家页面只提交业务动作：

```js
await playmesh.main.game.submitAction({
  type: "answer.submit",
  questionId,
  answer,
});
```

Authority 处理器接收动作和可信上下文，并返回一个结果或结果数组：

```js
playmesh.main.authority.onService(async (action, context) => {
  // context.senderPlayerId、context.session、context.members 由平台提供。
  const nextState = reduceGameState(action, context);
  return {
    targetPlayerIds: context.members.map((player) => player.id),
    message: { type: "state.updated", state: nextState },
  };
});
```

玩家页面通过 `playmesh.main.game.onMessage()` 接收 Authority 已路由的消息。不要依赖客户端提交的玩家 ID、分数、答案或时间作为最终依据。

需要发送 `Uint8Array`、高频状态或自定义序列化数据时使用
`playmesh.main.binary`，不要把字节编码进 JSON。只有 Authority 创建/关闭 Channel，
其他成员凭 Channel ID 加入；Authority 固定目标为
`playmesh.main.binary.authorityPlayerId`。可靠单发使用 `send(id, data)`，一个上行
帧多发使用 `send([id...], data)`，快捷广播使用 `send(data)`；只关心最新未发状态时
使用同名重载 `sendLatest(id 或 id[], data)` 或 `sendLatest(data)`。广播只发给
Channel 中除发送者外的当前在线成员，所有投递都由同一个 `onMessage` 接收。
`mode: "authority"` 的 `onForward` 上下文始终给出 `targetPlayerIds` 数组，可原样
通过、替换或拒绝；已经开始执行的旧、新审核都会继续且各自结果生效。
`mode: "relay"` 直接转发。

需要让任意客户端按精确路径向 Authority 请求并等待一个返回值时，使用
`playmesh.main.rpc`。这不是 Main Bucket 的客户端直连入口；Authority handler 仍须根据
可信 `context.senderPlayerId` 做业务审计：

```js
if (playmesh.main.session.isAuthority()) {
  playmesh.main.rpc.onRequest("/profile/load", async (request, context) => {
    const profile = await loadProfileFor(context.senderPlayerId, request.slot);
    return {
      profile,
      portrait: profilePortraitBlob, // Blob/File/ArrayBuffer/Uint8Array 均可
    };
  });
}

const result = await playmesh.main.rpc.request(
  "/profile/load",
  { slot: "slot1" },
  { timeoutMs: 10000 },
);
```

- 客户端调用始终异步；Authority handler 可以同步返回，也可以返回 Promise。
- 传输使用会话认证的内部二进制 RPC 帧，不把图片或文件转成 JSON/Base64。支持 JSON
  兼容值、`Blob`、`File`、`ArrayBuffer` 和 `Uint8Array`；函数、DOM 对象、循环引用及
  自定义类实例不能跨设备传递。
- 只有 Authority 可以注册 `onRequest`；Core 后台也只会把请求路由给固定 Authority，
  并拒绝非 Authority 伪造结果。客户端超时不会取消已经开始执行的 handler。
- 单个编码后 payload 受 Binary WS 4 MiB 帧上限约束，当前 SDK 为帧头和元数据预留
  64 KiB；大文件应继续使用游戏自己的受控文件流程，而不是把 RPC 当文件服务器。

大屏游戏不在公共显示端提供“开始游戏”动作。每位控制器玩家提交准备状态，人数满足 `players.min` 且全员准备后，由 Authority 时钟自动倒计时并开始。回合推进也应由 Authority 时钟完成，不能依赖显示页面的定时器。

## 生命周期

```js
playmesh.main.lifecycle.onPause(() => stopAnimation());
playmesh.main.lifecycle.onResume(() => resumeAnimation());
playmesh.main.lifecycle.onExit(() => {
  stopTimers();
});
```

退出回调有有限等待时间，关键状态应在发生变化时保存。刷新游戏会通知旧页面退出、完成存储落盘并重建 WebView 和游戏业务状态，但不会重置当前 Core 会话；会话 ID、联机码、玩家连接、分享网关和本局 token 均保留。离开游戏才关闭会话并使 token 失效。

## 持久化数据

需要由 Authority 持有游戏数据时，使用 Main Bucket：

```js
const save = playmesh.main.storage.getBucket("save_v1");
const score = await save.getData("high_score");
await save.setData("high_score", Math.max(score ?? 0, currentScore));

const imageUrl = await save.upload(imageFile);
preview.src = imageUrl;
```

- Bucket 名称匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- key 只允许字母、数字、点、下划线和连字符，长度为 1 至 128。
- 普通游戏继续使用异步 `getData/setData/removeData/clearData`。仅 GDevelop 等必须维持同步
  上层语义的运行时适配器使用 `getDataSync/setDataSync`；同步调用会阻塞页面，失败时直接
  抛错，不能作为普通存档 API。
- 平台只自动绑定当前 `gameId`，不创建 `{userId}` 目录。用户维度由游戏在 key 或 JSON 内容中设计。
- 只有 Authority 页面可以读写 Main Bucket；分享浏览器、远程 App 和其他非 Authority
  玩家即使持有有效会话 Cookie 或分享令牌，宿主后台也会拒绝。玩家需要的数据必须由
  Authority 通过正常游戏消息投影，不能把 Main Bucket 当作客户端直连数据库。
- 浏览器 `localStorage` 由 SDK 保存 `playmesh.player-id.v1` 和昵称偏好，以便刷新后使用同一玩家 ID 重连；不得保存玩家凭证或 Main Bucket。
- 浏览器昵称采集、修改和普通浏览器居中游戏菜单由 SDK 统一提供。菜单包含继续、刷新、日志、性能、全屏、信息和退出；分享链接、游戏 URL 和游戏代码都不得携带或自行缓存昵称，游戏也不应重复制作工具入口或昵称控件。
- 使用 `session.onPlayerJoin`、`session.onPlayerLeave` 和 `session.onPlayerReconnect` 处理首次连接、掉线和同 ID 重连。不要用昵称推断玩家身份。
- Bucket 不提供 `flush()`。App 会按时间窗口或脏写阈值批量落盘，并在 WebView 重启、退出或会话关闭前等待最终写入完成。
- JSON 值存放在私有 `data/json`，完整 Bucket root 上限为 10 MiB；异步与同步 JSON 操作
  统一由 SDK 通过同源 HTTP `GET/PUT/DELETE` 访问，不存在 Session WS fallback。
  `upload(file)` 仍使用独立原始文件流 `POST` 写入 `data/data`，返回运行时
  `/bucket/...` 地址。游戏不得猜测宿主文件路径、枚举目录或自行调用内部 JSON 路由。

只需保存在玩家当前设备、且不希望其他玩家通过游戏会话访问的数据，使用 App Bucket：

```js
const localSave = playmesh.app.storage.getBucket("player_save");
const settings = await localSave.getData("settings");
await localSave.setData("settings", {
  sensitivity: settings?.sensitivity ?? 1,
});
```

- App Bucket 的名称和 key 规则与 Main Bucket 相同；名称匹配
  `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`，key 匹配
  `^[A-Za-z0-9._-]{1,128}$`。
- App WebView 只写入当前设备的
  `playmesh-library/data/{游戏名称}/{gameId}/{bucket名称}.json`。该目录不是 Authority
  主机的共享 Bucket，也不会经由 Session 暴露给其他玩家；游戏名称文件段由宿主安全
  处理，游戏不能传入、猜测或枚举文件路径。
- 普通浏览器以 Bucket 名称本身作为 `localStorage` key；同源浏览器存储仍受浏览器清理、
  隐私模式和配额影响。
- App Bucket 支持异步 `getData/setData/removeData/clearData`，并兼容提供与 Main Bucket
  同名的同步 JSON 方法 `getDataSync/setDataSync`。同步逻辑 Bucket 名可为 1～4096 UTF-8
  字节；原生 App 仍只读写当前设备目录，普通浏览器读写当前源 `localStorage`。它不支持
  `upload()` 或默认跨设备恢复。不要存放凭证、令牌等敏感认证数据。

## FPS 上报

FPS 是可选能力，SDK 不启动独立 RAF 推测游戏帧率。游戏只在真实视觉帧完成后上报：

```js
function render(timestamp) {
  drawGame();
  playmesh.app.performance.reportFrame(timestamp);
  requestAnimationFrame(render);
}
requestAnimationFrame(render);
```

Canvas/WebGL 游戏应在实际绘制或提交完成后调用。非逐帧渲染游戏可以不接入，宿主显示 `-- FPS`。

## 平台能力插件

需要 WebView 敏感权限或 Playmesh 多平台适配能力时，在 `main.json` 同级创建可选
`capabilities.json`。`required` 声明主画面能力；单屏多人使用
`controllerRequired` 独立声明控制器能力，其他模式禁止该字段。`main.json` 没有
`permissions` 字段，也不要在代码里自行维护能力名称清单；开发者工作区在新建项目和
“项目设置”中都从平台注册表为两个角色分别生成选项。`GET /dev/api/capabilities`
返回每个插件的 code、`apiVersion`、方法、事件和平台状态。

```json
{
  "required": [
    "media.camera",
    "media.microphone",
    "device.vibration"
  ]
}
```

主 SDK 会在 App 和普通浏览器每次进入游戏时展示本次所需能力，不保存确认结果。
用户拒绝则退出；当前环境不支持的能力显示“本平台暂不支持”，但用户同意后仍可
进入，游戏必须保留降级路径。

```js
const stream = await navigator.mediaDevices.getUserMedia({
  video: true,
  audio: true,
});
```

摄像头、麦克风采集和 MIDI 声明后直接使用 `getUserMedia()` 或
`requestMIDIAccess({sysex:true})`；未声明时 App WebView 拒绝对应权限回调。
`media.microphone@1.1.0` 还可通过能力实例调用
`toText({localeId, listenFor, pauseFor})`，并监听 `textOnSoundLevelChange` 与
`textOnResult`。加速度计、陀螺仪和设备方向直接使用标准 Web API，不写
`capabilities.json`。文件上传使用 `<input type="file">` 让用户当次主动选择文件，
同样不声明能力，也不能静默读取文件系统。

震动是多平台原生适配插件，通过 App SDK 主动调用：

```js
if (playmesh.app.capabilities.getAvailable().includes('device.vibration')) {
  const vibration = await playmesh.app.capabilities.create(
    'device.vibration',
    {},
  );
  await vibration.invoke('vibrate', {
    pattern: [0, 100, 50, 200],
    intensities: [0, 128, 0, 255],
  });
  await vibration.invoke('cancel', {});
  await vibration.dispose();
}
```

## 开发检查清单

- `main.json.id` 与包目录名一致，版本使用 `MAJOR.MINOR.PATCH`。
- 每次准备发布游戏内容时，按 `PATCH` 修复、`MINOR` 兼容新增、`MAJOR` 不兼容变更升级 `main.json.version`；内置工作区同步维护 SDK 字段，CLI 则在发布前按本地生成文件自动覆盖 `sdkVersion/appSdkVersion`。工作区通过“项目设置”或 manifest API 修改清单，普通文件接口仍只读，项目 `id` 永远不能修改。
- `orientation` 明确为 `landscape` 或 `portrait`。
- `entries.game` 已显式声明且解析出的 HTML 存在；单屏多人同时显式声明
  `entries.controller`，且解析出的 HTML 存在。
- 包根 `icon.png` 可选；存在时必须通过平台的 PNG、大小和尺寸校验。
- 入口路径相对于外层物理 `app/`，不含反斜杠、编码路径、Fragment、`.`/`..`
  或保留一级目录 `playmesh`/`bucket`。HTML 游戏和控制器入口可在 `.html` 后追加
  非空查询串；查询串不参与文件存在性检查并在运行 URL 中保留。首段 `app` 合法并
  解析到物理 `app/app/`；Authority JavaScript 入口不能带查询串。
- HTML 查询参数只属于游戏页面的可见、自定义启动配置。App 身份、昵称、设备能力和
  Core 地址由页面内标准 App SDK 通过原生 Bridge 向 Dart 请求 `app.bootstrap`
  获得；不得用 URL 参数判断当前是否运行在 App 中或指定 App SDK 脚本地址。
- 本地开发与 App 运行不按关键词限制入口查询参数；go-server 云分发上传也不因
  外部 HTTP/WS、协议相对链接或动态 `Function` 构造拒绝包。`file:`、
  `javascript:`、可执行 HTML Data URL、`eval`、Service Worker 等其余启用的
  内容规则仍按服务端配置执行。
- 多人游戏显式声明合法且存在的 `authority.entry`。
- 需要设备能力时存在合法的 `capabilities.json`，能力 code 来自统一注册表；未声明或当前不可用时主流程仍可运行。
- 主 SDK 从 `/playmesh/sdk/v1/playmesh-main.js` 引入，没有跨目录相对路径；旧
  `playmesh.js` 不兼容。
- 页面没有直接 WebSocket、Core 地址、原生 Bridge 或私有 `data/json` URL；运行时文件只使用 `upload(file)` 返回的 `/bucket/...` 地址。
- Authority 与玩家层职责分离，大屏公共显示端不进入玩家集合。
- Authority 主机存储只通过 `playmesh.main.storage`，当前设备私有存储只通过
  `playmesh.app.storage`；FPS 只在真实渲染完成处通过
  `playmesh.app.performance` 上报；`playmesh.main.performance` 不存在。
