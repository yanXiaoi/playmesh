# 游戏开发指南

## 开发模型

Playmesh 游戏是由 App 托管的 HTML/CSS/JavaScript 应用。Flutter 负责游戏容器和平台交互，Go Core 负责局域网会话与消息路由，游戏通过 Game SDK 访问这些能力。

```text
游戏页面
  -> /playmesh/sdk/v1/playmesh.js
  -> Flutter WebView Bridge 或浏览器网关
  -> Go Core 会话
  -> Authority Runtime
```

游戏代码不能直接访问 Bridge、Core 地址、内部 token 或任意文件系统。

## IDEA 与 CLI 开发

Playmesh CLI 允许在 IDEA 中编辑本地副本、在目标 Windows 或 Android App 中运行，同一套命令和目录结构跨平台使用。先在 App 设置中开启开发者模式并复制完整工作区链接，然后执行：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli get <project-id>
playmesh-cli dev
```

`get` 拉取包内 `main.json`、`capabilities.json`、`app/`，并把目标 App 构建时生成的两套 SDK 与 `.d.ts` 放入 `playmesh/sdk/`。项目根的 `app/` 与 `playmesh/` 直接镜像运行时 `/app/...` 与 `/playmesh/...` 两个 URL 空间，IDEA 能解析 HTML、JavaScript、CSS 中的绝对引用。`playmesh/` 只属于本地开发副本，不会出现在 App 安装目录或上传包中。

`playmesh-cli push` 直接把本地 `app/` 作为发布包内容上传；`playmesh-cli dev` 在提交后切换 App 运行项目并跟随日志；`playmesh-cli sdk` 只更新 `playmesh/sdk/` 到目标 App 当前版本，不支持选择历史版本。`push/dev` 每次都从本地 SDK 文件读取版本，覆盖 `main.json.sdkVersion/appSdkVersion` 后再打包。完整命令、目录和安全边界见 `dev-cli/README.md`。

## 开发者工作区快速操作

Playmesh 不提供独立的 App 文件编辑器。电脑浏览器与 App 内置 WebView 均打开同一个开发者工作区，AI 可以生成分段文本供用户粘贴到工作区的快速操作面板。面板不执行自然语言命令，只解析以下固定操作：

```text
----create_file:static/js/shared/types.js
export const ActionTypes = {};
----end

----replace_file:index.html
<!doctype html>
<html>...</html>
----end

----insert_lines:static/js/service/index.js:20
// TODO：处理玩家动作
----end

----replace_lines:static/js/service/index.js:20-35
// TODO：替换指定范围
----end
```

路径默认相对于当前游戏的 `app/` 目录，支持 `create_file`、`replace_file`、`insert_lines` 和 `replace_lines`。`create_file` 要求目标不存在；`replace_file` 为完整内容 upsert，目标不存在时自动创建文件及缺失的父目录；行操作仍要求目标文件已经存在或已在同一批操作中先创建。工作区必须先展示 Diff，确认后原子执行；不能访问 `data/`、`cache/`、其他游戏、App 私有目录或系统路径。每次确认的修改进入项目级本地历史；修改通过 SSE 同步到所有已打开的工作区。

工作区还支持在项目树中右键新建或删除文件与文件夹，并将本地文件上传到指定目录。也可以把文件拖到根节点、文件夹或某个文件上；拖到文件时上传到其所在目录。只有 `.zip` 文件提供解压入口，剪切后目标目录才显示“移动到这里”。当前编辑缓冲区尚未保存内容的撤销与重做由 CodeMirror 管理；服务端不提供独立的单文件撤销接口。

代码编辑器会按文件类型提供 HTML、CSS 和 JavaScript 补全，并在 JavaScript 上下文中注入完整 `playmesh` SDK 方法树。输入 `<`、CSS 的 `:` 或 JavaScript 的 `.` 会触发相关提示，也可以随时按 `Ctrl+Space` 或 `Alt+/`。编辑器自身的第三方依赖集中在 `public/developer/editor/`；游戏需要的外部浏览器依赖应上传或解压到项目 `app/` 内，再从游戏代码引用。

本地历史位于 `packages/{gameId}/cache/developer/local-history/`，采用初始基线加逐时间操作的变更后快照。连续编辑按 5 分钟滚动窗口合并，工作区可按文件、文件夹或整个项目查看 Diff，并将指定范围恢复为某次操作的变更前或变更后状态。恢复整个项目时 `main.json` 始终由平台保留。

新建项目可选择单机或联机，项目 ID 输入框旁可一键生成符合反向域名格式的随机 ID。单机骨架使用 `modes: ["solo"]`、`displayModes: ["multi_screen"]` 和玩家 `1/1`，不生成控制器与 Authority 入口；联机骨架根据显示模式生成普通多屏或单屏多人结构。AI 修改后先调用 `/dev/api/projects/{projectId}/validate`，只有不存在 `error` 诊断时才能运行。已运行项目可通过工作区“重启”按钮或 `POST /dev/api/projects/{projectId}/run/restart` 重载游戏运行时，并保留当前分享信息。

需要重置调试存档时，先退出正在运行的游戏，再使用工作区“清理游戏数据”按钮。该操作只删除当前项目的 `data/`，不会清理 `cache/`、项目源码或开发历史。

浏览器工作区继续使用 SSE 接收实时事件；不方便维护流式连接的 API Agent 可调用 `GET /dev/api/logs?limit=50` 获取最近最多 50 条运行日志，并调用 `GET /dev/api/projects/{projectId}/run` 轮询运行状态。日志接口接受可选的 `projectId` 和 `runId` 查询参数，仅返回指定运行实例；每条日志包含稳定的 `eventId`，可用于合并缓存回放与 SSE 时去重。底层内存缓存最多保留 500 条且不写磁盘。

API Agent 的最小上下文入口是 `/dev/api/ai-context`，其中列出持久工作区 token 的全部接口、鉴权、SDK Manifest、OpenAPI 和 Schema。主工作区点击“AI”直接进入统一页面，接口文档作为只读项与提示模板同页展示。纯聊天 AI 使用 `/dev/api/projects/{projectId}/chat-prompt.txt`，可直接调用接口的 Agent 使用 `/dev/api/projects/{projectId}/agent-prompt.txt`。`GET /dev/api/status` 的 `baseUrls` 枚举当前设备可用的 HTTP 地址；Agent 端点接受可选 `baseUrl` 查询参数，但只允许使用该枚举中的地址。平台按当前 `main.json.modes/displayModes` 只拼接相关 SDK、角色语义、强制文件和当前项目源码；公共“自定义想法”同时合入两类文本，Agent 文本额外包含所选 Gateway 地址、Bearer token 与项目文件、校验、运行/重启、日志轮询和可选 SSE 接口。两份最终文件固定为 UTF-8 BOM TXT，并都在醒目的“获取项目提示词”入口中复制或下载；手机端应为 Agent 选择电脑端 AI 能访问的局域网 Base URL。模板覆盖保存在 `playmesh-library/developer/ai-prompts/`；项目本体统一保存在 `playmesh-library/packages/{gameId}/`。平台不内置游戏 Demo。

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

大屏游戏不在公共显示端提供“开始游戏”动作。每位控制器玩家提交准备状态，人数满足 `players.min` 且全员准备后，由 Authority 时钟自动倒计时并开始。回合推进也应由 Authority 时钟完成，不能依赖显示页面的定时器。

## 生命周期

```js
playmesh.lifecycle.onPause(() => stopAnimation());
playmesh.lifecycle.onResume(() => resumeAnimation());
playmesh.lifecycle.onExit(() => {
  stopTimers();
});
```

退出回调有有限等待时间，关键状态应在发生变化时保存。重新开始会把当前 Core 会话恢复为大厅并重建 WebView 和游戏业务状态，但保留会话 ID、联机码、玩家连接、分享网关和本局 token；离开游戏才关闭会话并使 token 失效。

## 持久化数据

```js
const save = playmesh.storage.getBucket("save_v1");
const score = await save.getData("high_score");
await save.setData("high_score", Math.max(score ?? 0, currentScore));
```

- Bucket 名称匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- key 只允许字母、数字、点、下划线和连字符，长度为 1 至 128。
- 平台只自动绑定当前 `gameId`，不创建 `{userId}` 目录。用户维度由游戏在 key 或 JSON 内容中设计。
- 所有客户端读写 Authority 主机的同一份 Bucket。浏览器 `localStorage` 由 SDK 保存 `playmesh.player-id.v1` 和昵称偏好，以便刷新后使用同一玩家 ID 重连；不得保存玩家凭证或 Bucket。
- 浏览器昵称采集和修改由 SDK 统一提供。分享链接、游戏 URL 和游戏代码都不得携带或自行缓存昵称；游戏也不应重复制作昵称悬浮控件。
- 使用 `session.onPlayerJoin`、`session.onPlayerLeave` 和 `session.onPlayerReconnect` 处理首次连接、掉线和同 ID 重连。不要用昵称推断玩家身份。
- Bucket 不提供 `flush()`。App 会按时间窗口或脏写阈值批量落盘，并在 WebView 重启、退出或会话关闭前等待最终写入完成。

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

## 设备能力与传感器

需要平台设备能力时，在 `main.json` 同级创建可选 `capabilities.json`。不要把传感器写入 `main.json.permissions`，也不要在代码里自行维护能力名称清单；开发者工作区在新建项目和“项目设置”中都可视化编辑该文件，Agent 可先读取 `GET /dev/api/capabilities`，再调用项目 capabilities API 保存声明。排查设备输入时调用 `GET /dev/api/capability-tests` 查看测试项，再用 `POST` 测试全部或指定能力；传感器通过时会返回首个 X/Y/Z 样本。

```json
{
  "required": ["sensor.accelerometer", "sensor.gyroscope"]
}
```

主 SDK 会在 App 和普通浏览器每次进入游戏时展示本次所需能力，不保存确认结果。用户拒绝则退出；当前环境不支持的能力显示“本平台暂不支持”，但用户同意后仍可进入，因此传感器不能成为无法降级的主流程前提。

```js
await playmesh.ready;

if (playmesh.app.device.getCapabilities().includes('sensor.accelerometer')) {
  const off = playmesh.app.onDevice(
    playmesh.app.DeviceType.accelerometer,
    30,
    ({ x, y, z, timestamp, unit }) => updateTilt({ x, y, z, timestamp, unit }),
  );
  playmesh.lifecycle.onExit(off);
}
```

`fps` 必须为 `1` 至 `120` 的整数。App 只维护一条对应原生流和最新样本，各订阅者按自己的 fps tick 收到回调；返回的取消函数应在不再使用时调用。加速度计单位为 `m/s^2`，陀螺仪单位为 `rad/s`。当前两项仅 App 已适配，普通局域网 HTML 环境使用安全空实现。

## 开发检查清单

- `main.json.id` 与包目录名一致，版本使用 `MAJOR.MINOR.PATCH`。
- 每次准备发布游戏内容时，按 `PATCH` 修复、`MINOR` 兼容新增、`MAJOR` 不兼容变更升级 `main.json.version`；内置工作区同步维护 SDK 字段，CLI 则在发布前按本地生成文件自动覆盖 `sdkVersion/appSdkVersion`。工作区通过“项目设置”或 manifest API 修改清单，普通文件接口仍只读，项目 `id` 永远不能修改。
- `orientation` 明确为 `landscape` 或 `portrait`。
- `entries.game` 解析出的 HTML 存在；大屏模式同时存在 `entries.controller` 解析出的 HTML。
- 多人游戏声明合法的 `authority.entry`。
- 需要设备能力时存在合法的 `capabilities.json`，能力 code 来自统一注册表；未声明或当前不可用时主流程仍可运行。
- SDK 从 `/playmesh/sdk/v1/playmesh.js` 引入，没有跨目录相对路径。
- 页面没有直接 WebSocket、Core 地址、原生 Bridge 或 `data/` URL。
- Authority 与玩家层职责分离，大屏公共显示端不进入玩家集合。
- 存储只通过 `playmesh.storage`，FPS 只在真实渲染完成处上报。
