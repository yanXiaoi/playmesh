# 游戏开发指南

## 开发模型

Playmesh 游戏是由 App 托管的 HTML/CSS/JavaScript 应用。Flutter 负责游戏容器、平台交互和联机链路，Go Core 负责权威会话与消息路由，游戏只通过 Game SDK 访问这些能力。

```text
游戏页面
  -> /playmesh/sdk/v1/playmesh.js
  -> App 宿主或局域网浏览器入口
  -> Go Core 会话
  -> Authority Runtime
```

局域网 App、公共中转 App 和局域网浏览器使用同一套 SDK 语义；链路选择、加载来源和传输安全由平台处理。游戏代码不能直接访问 Bridge、Core 地址、分享参数、内部 token 或任意文件系统，也不能按玩家的加入方式分叉会话协议。

## IDEA 与 CLI 开发

Playmesh CLI 允许在 IDEA 中编辑本地副本、在目标 Windows 或 Android App 中运行，同一套命令和目录结构跨平台使用。先在 App 设置中开启开发者模式并复制完整工作区链接，然后执行：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli create
# 或使用 playmesh-cli get <project-id> 拉取既有项目
playmesh-cli dev
```

`get` 拉取包内现有的 `main.json`、可选 `capabilities.json`、已有 `app/` 文件，并把目标 App 构建时生成的两套 SDK 与 `.d.ts` 放入 `playmesh/sdk/`。这是损坏项目自救通道，不执行 Manifest、能力或入口语义校验；只要 `main.json` 仍有有效 `id`，即使缺少 `app/` 也能拉回已有内容。项目根的 `app/` 与 `playmesh/` 直接镜像运行时 `/app/...` 与 `/playmesh/...` 两个 URL 空间，IDEA 能解析 HTML、JavaScript、CSS 中的绝对引用。`playmesh/` 只属于本地开发副本，不会出现在 App 安装目录或上传包中。

`playmesh-cli create` 从统一能力注册表读取与网页 Dev Tool 相同的新建选项，调用现有 Developer API 创建项目后下载到当前空目录。`playmesh-cli push` 直接把本地 `app/` 作为发布包内容上传；`playmesh-cli dev` 在提交后切换 App 运行项目并跟随日志；`playmesh-cli sdk` 只更新开发副本到目标 App 的最新版，不用于下载历史静态文件。`push/dev` 每次都从本地 SDK 文件读取版本，覆盖 `main.json.sdkVersion/appSdkVersion` 后再打包。已安装旧游戏不依赖 CLI 文件：App 运行时按清单版本从 Dart 注册表选择兼容发行版。完整命令、目录和安全边界见 `dev-cli/README.md`。

## 开发者工作区对话控制台

Playmesh 不提供独立的 App 文件编辑器。电脑浏览器与 App 内置 WebView 均打开同一个开发者工作区。纯聊天 AI 输出一个 JSON 指令对象或数组，用户只需粘贴到“对话控制台”；控制台在上方接收指令，在下方返回状态码、请求 ID、修订号和响应体。

每条指令使用 `method`、同源 `/dev/api/**` `path` 和可选 JSON `body`。默认提示词只内嵌操作目录、项目/文件读取、创建或完整替换文件、精确替换/插入、批量文件变更和校验等基础指令；完整目录通过 `GET /dev/api/operations?target=chat` 获取。旧分段文本快速操作协议已经删除，不再兼容。

`POST /dev/api/projects/{projectId}/file-changes/preview` 接受 `create`、`replace`、`replace_text`、`insert_before`、`insert_after` 结构化变更，返回结果和 `baseRevisions`；`apply` 端点校验同一批修订后原子写入。所有路径相对于项目根，源码通常使用 `app/...`；不能访问 `data/`、`cache/`、其他游戏、App 私有目录或系统路径。每次确认的修改进入项目级本地历史，并通过 SSE 同步到所有已打开工作区。

对话控制台自动携带 `X-Playmesh-AI-Channel: chat`；Agent 必须携带值为 `agent` 的同一请求头。注册表中 `dangerous=true` 的接口在所有 AI 通道上先暂停，通过 SSE 向工作区展示“允许一次 / 此游戏或项目允许 / 始终允许 / 拒绝”。30 秒未决定时原请求返回 `408 ai_approval_timeout`，拒绝返回 `403 ai_operation_rejected`。

当前项目运行后，“更多 → WebView JS 操作台”可复用 JavaScript CodeMirror 编辑器，在当前游戏的顶层 WebView 文档中执行代码，并在下方展示 `resultType`、返回值、运行实例和请求 ID。成功结果与执行错误按项目保存在浏览器本地历史中，可由“历史记录”重新载入。对应接口为 `POST /dev/api/projects/{projectId}/webview/javascript`，请求体是 `{"source":"document.title"}`；它声明为高风险 `dangerous=true` 并同时暴露给 Chat 和 Agent，因此 AI 调用必须先走上述 SSE 审批，开发者从操作台手动执行则不附加 AI 通道头。

工作区还支持在项目树中右键新建或删除文件与文件夹，并将本地文件上传到指定目录。也可以把文件拖到根节点、文件夹或某个文件上；拖到文件时上传到其所在目录。只有 `.zip` 文件提供解压入口，剪切后目标目录才显示“移动到这里”。当前编辑缓冲区尚未保存内容的撤销与重做由 CodeMirror 管理；服务端不提供独立的单文件撤销接口。

代码编辑器会按文件类型提供 HTML、CSS 和 JavaScript 补全，并在 JavaScript 上下文中注入完整 `playmesh` SDK 方法树。输入 `<`、CSS 的 `:` 或 JavaScript 的 `.` 会触发相关提示，也可以随时按 `Ctrl+Space` 或 `Alt+/`。编辑器自身的第三方依赖集中在 `public/developer/editor/`；游戏需要的外部浏览器依赖应上传或解压到项目 `app/` 内，再从游戏代码引用。

本地历史位于 `packages/{gameId}/cache/developer/local-history/`，采用初始基线加逐时间操作的变更后快照。连续编辑按 5 分钟滚动窗口合并，工作区可按文件、文件夹或整个项目查看 Diff，并将指定范围恢复为某次操作的变更前或变更后状态。恢复整个项目时 `main.json` 始终由平台保留。

新建项目可选择单机或联机，项目 ID 输入框旁可一键生成符合反向域名格式的随机 ID。单机骨架使用 `modes: ["solo"]`、`displayModes: ["multi_screen"]` 和玩家 `1/1`，不生成控制器与 Authority 入口；联机骨架根据显示模式生成普通多屏或单屏多人结构。AI 修改后先调用 `/dev/api/projects/{projectId}/validate`，只有不存在 `error` 诊断时才能运行。已运行项目可通过工作区“重启”按钮或 `POST /dev/api/projects/{projectId}/run/restart` 重载游戏运行时，并保留当前分享信息。

需要重置调试存档时，先退出正在运行的游戏，再使用工作区“清理游戏数据”按钮。该操作只删除当前项目的 `data/`，不会清理 `cache/`、项目源码或开发历史。

浏览器工作区继续使用 SSE 接收实时事件；不方便维护流式连接的 API Agent 可调用 `GET /dev/api/logs?limit=50` 获取最近最多 50 条运行日志，并调用 `GET /dev/api/projects/{projectId}/run` 轮询运行状态。日志接口接受可选的 `projectId` 和 `runId` 查询参数，仅返回指定运行实例；每条日志包含稳定的 `eventId`，可用于合并缓存回放与 SSE 时去重。底层内存缓存最多保留 500 条且不写磁盘。

API Agent 的最小上下文入口是 `/dev/api/ai-context`，其中列出持久工作区 token 的全部接口、鉴权、SDK Manifest、OpenAPI 和 Schema。主工作区点击“AI”直接进入统一页面，接口文档作为只读项与提示模板同页展示。纯聊天 AI 使用 `/dev/api/projects/{projectId}/chat-prompt.txt`，其能力上下文只包含当前项目已勾选能力的完整声明；可直接调用接口的 Agent 使用 `/dev/api/projects/{projectId}/agent-prompt.txt`，不内嵌全量能力声明，而是明确提供 `GET /dev/api/capabilities` 全量注册表 API 与 `GET/POST /dev/api/capability-tests` 测试 API。`GET /dev/api/status` 的 `baseUrls` 枚举当前设备可用的 HTTP 地址；Agent 端点接受可选 `baseUrl` 查询参数，但只允许使用该枚举中的地址。平台按当前 `main.json.modes/displayModes` 只拼接相关 SDK、角色语义、强制文件和当前项目源码；公共“自定义想法”同时合入两类文本，Agent 文本额外包含所选 Gateway 地址、Bearer token 与项目文件、校验、运行/重启、日志轮询和可选 SSE 接口。两份最终文件固定为 UTF-8 BOM TXT，并都在醒目的“获取项目提示词”入口中复制或下载；工作区还可通过“复制全平台能力”独立调用注册表 API，复制与项目勾选无关的全部完整声明。手机端应为 Agent 选择电脑端 AI 能访问的局域网 Base URL。模板覆盖保存在 `playmesh-library/developer/ai-prompts/`；项目本体统一保存在 `playmesh-library/packages/{gameId}/`。平台不内置游戏 Demo。

> **AI 上下文最小披露原则：面向游戏开发 AI 的提示词，只提供完成当前任务所必需、可由游戏代码调用或必须遵守的公开契约。凡属回环代理、内部路由、中转鉴权、密钥协商、加密通道等平台实现，均不得进入提示词；此类信息只保留在平台架构与维护文档中。**

## 运行模式

`main.json.modes` 声明单机或多人能力：

- `solo`：不需要多人会话。
- `multiplayer`：需要 `authority.entry`，规则由 Authority Runtime 执行。

`main.json.displayModes` 声明页面拓扑：

- `multi_screen`：所有设备加载 `entries.game`，未声明时为 `app/index.html`。创建会话的 App 主机固定为 Authority Client，并可同时作为 Player；不得从首位玩家或加入顺序推断 Authority。
- `single_screen_multiplayer`：主机加载 `entries.game` 作为公共显示端与 Authority Client；所有玩家加载 `entries.controller`，未声明时为 `app/controller/index.html`，主机不计入 `players`。

游戏必须且只能声明一种显示模式。平台根据该 `displayMode` 决定页面入口，游戏不能根据二维码自行决定入口。

## 推荐目录分层

```text
{gameId}/
  main.json
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

开发者工作区的项目根对应 `packages/{gameId}/`，主页面路径由 `entries.game` 决定，默认 `app/index.html`。WebView 只映射其中的 `app/` 公开目录；`data/` 和 `cache/` 由平台管理，不显示在普通项目树中，也不参与静态映射。App 安装目录只保存正式发布内容和平台管理数据；CLI 本地的 `playmesh/` 只是 `/playmesh/` 公共 URL 空间的开发镜像，永不上传或安装。

| 层 | 允许职责 | 禁止职责 |
|---|---|---|
| 玩家运行层 | 渲染 UI、采集输入、提交动作、展示权威消息 | 决定最终分数和胜负、伪造玩家身份、直接连接 Core |
| 权威处理层 | 验证动作、维护状态、生成题目、计分、定向或广播结果 | 操作 DOM、读取按钮、依赖页面临时变量、创建 WebSocket |
| 共享数据层 | 类型、常量、序列化结构、纯函数 | 保存会话状态、发送消息、执行权限判断 |

`authority.entry` 是权威代码的清单入口。当前 v1 运行方式仍要求主机页面引入对应脚本，并只在 `playmesh.session.isAuthority()` 为 `true` 时调用 `playmesh.authority.onService()`；控制器页面不得注册权威服务。

## SDK 初始化

所有页面先引入公共 SDK，再等待 `playmesh.ready`：

```html
<script src="/playmesh/sdk/v1/playmesh.js"></script>
<script type="module" src="/app/static/js/player/index.js"></script>
```

```js
await playmesh.ready;

const session = playmesh.session.getCurrent();
const player = playmesh.player.getCurrent();
```

游戏只显式引入 `playmesh.js`。Playmesh App 会自动在它之前注入本机桥接 `playmesh-app.js`，普通浏览器不会加载该文件；两种环境都可通过 `playmesh.app.isAvailable()` 做能力判断。主机 SDK 负责会话、联机和游戏存储，本机 App SDK 只负责 App 持久化身份与已声明的硬件能力；Console 由当前页面的宿主在本设备捕获，游戏不得手动设置玩家 ID。

大屏公共显示端的 `player` 为 `null`。页面必须允许该值为空，不能把 Authority 自动加入玩家集合。

## 游戏业务国际化

Playmesh 的 App 词典只翻译平台自己的覆盖层，不会提供给游戏。游戏在
`await playmesh.ready` 后调用同步只读 `playmesh.runtime.getLocale()`，取得当前
实际显示端的 locale，并使用游戏包内自己的语言资源渲染业务界面：

```js
await playmesh.ready;
const locale = playmesh.runtime.getLocale();
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
await playmesh.game.submitAction({
  type: "answer.submit",
  questionId,
  answer,
});
```

Authority 处理器接收动作和可信上下文，并返回一个结果或结果数组：

```js
playmesh.authority.onService(async (action, context) => {
  // context.senderPlayerId、context.session、context.members 由平台提供。
  const nextState = reduceGameState(action, context);
  return {
    targetPlayerIds: context.members.map((player) => player.id),
    message: { type: "state.updated", state: nextState },
  };
});
```

玩家页面通过 `playmesh.game.onMessage()` 接收 Authority 已路由的消息。不要依赖客户端提交的玩家 ID、分数、答案或时间作为最终依据。

需要发送 `Uint8Array`、高频状态或自定义序列化数据时使用 `playmesh.binary`，不要把字节编码进 JSON。只有 Authority 创建/关闭 Channel，其他成员凭 Channel ID 加入；Authority 固定目标为 `playmesh.binary.authorityPlayerId`。可靠单发使用 `send(id, data)`，一个上行帧多发使用 `send([id...], data)`，快捷广播使用 `send(data)`；只关心最新未发状态时使用同名重载 `sendLatest(id 或 id[], data)` 或 `sendLatest(data)`。广播只发给 Channel 中除发送者外的当前在线成员，所有投递都由同一个 `onMessage` 接收。`mode: "authority"` 的 `onForward` 上下文始终给出 `targetPlayerIds` 数组，可原样通过、替换或拒绝；已经开始执行的旧、新审核都会继续且各自结果生效。`mode: "relay"` 直接转发。

大屏游戏不在公共显示端提供“开始游戏”动作。每位控制器玩家提交准备状态，人数满足 `players.min` 且全员准备后，由 Authority 时钟自动倒计时并开始。回合推进也应由 Authority 时钟完成，不能依赖显示页面的定时器。

## 生命周期

```js
playmesh.lifecycle.onPause(() => stopAnimation());
playmesh.lifecycle.onResume(() => resumeAnimation());
playmesh.lifecycle.onExit(() => {
  stopTimers();
});
```

退出回调有有限等待时间，关键状态应在发生变化时保存。刷新游戏会通知旧页面退出、完成存储落盘并重建 WebView 和游戏业务状态，但不会重置当前 Core 会话；会话 ID、联机码、玩家连接、分享网关和本局 token 均保留。离开游戏才关闭会话并使 token 失效。

## 持久化数据

```js
const save = playmesh.storage.getBucket("save_v1");
const score = await save.getData("high_score");
await save.setData("high_score", Math.max(score ?? 0, currentScore));

const imageUrl = await save.upload(imageFile);
preview.src = imageUrl;
```

- Bucket 名称匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- key 只允许字母、数字、点、下划线和连字符，长度为 1 至 128。
- 平台只自动绑定当前 `gameId`，不创建 `{userId}` 目录。用户维度由游戏在 key 或 JSON 内容中设计。
- 所有客户端读写 Authority 主机的同一份 Bucket。浏览器 `localStorage` 由 SDK 保存 `playmesh.player-id.v1` 和昵称偏好，以便刷新后使用同一玩家 ID 重连；不得保存玩家凭证或 Bucket。
- 浏览器昵称采集、修改和普通浏览器游戏侧边栏由 SDK 统一提供。侧边栏包含继续、刷新、日志、性能、全屏、信息和退出；分享链接、游戏 URL 和游戏代码都不得携带或自行缓存昵称，游戏也不应重复制作工具入口或昵称控件。
- 使用 `session.onPlayerJoin`、`session.onPlayerLeave` 和 `session.onPlayerReconnect` 处理首次连接、掉线和同 ID 重连。不要用昵称推断玩家身份。
- Bucket 不提供 `flush()`。App 会按时间窗口或脏写阈值批量落盘，并在 WebView 重启、退出或会话关闭前等待最终写入完成。
- JSON 值存放在私有 `data/json`；`upload(file)` 使用原始文件流写入 `data/data`，返回运行时 `/bucket/...` 地址。游戏不得猜测宿主文件路径、枚举目录或用 `/bucket` 读取 JSON 存档。

## FPS 上报

FPS 是可选能力，SDK 不启动独立 RAF 推测游戏帧率。游戏只在真实视觉帧完成后上报：

```js
function render(timestamp) {
  drawGame();
  playmesh.performance.reportFrame(timestamp);
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
- `entries.game` 解析出的 HTML 存在；大屏模式同时存在 `entries.controller` 解析出的 HTML。
- 多人游戏声明合法的 `authority.entry`。
- 需要设备能力时存在合法的 `capabilities.json`，能力 code 来自统一注册表；未声明或当前不可用时主流程仍可运行。
- SDK 从 `/playmesh/sdk/v1/playmesh.js` 引入，没有跨目录相对路径。
- 页面没有直接 WebSocket、Core 地址、原生 Bridge 或私有 `data/json` URL；运行时文件只使用 `upload(file)` 返回的 `/bucket/...` 地址。
- Authority 与玩家层职责分离，大屏公共显示端不进入玩家集合。
- 存储只通过 `playmesh.storage`，FPS 只在真实渲染完成处上报。
