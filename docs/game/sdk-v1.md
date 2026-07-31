# Game SDK / App SDK API

本文记录 Game SDK `4.0.0` 与 App SDK `3.2.0` 的最新公开 API。静态资源 URL 中的
`/v1/` 是稳定分发路径，不代表当前语义版本。`lib/core/game_sdk/features/` 下注册的
Dart feature 是唯一手写源；同一文件同时维护对应 TypeScript/声明片段和宿主执行器。
App 运行时和各网关从统一注册表组装 JS、`.d.ts` 与宿主执行器。当前清单只接受
Game SDK `4.0.0` 与 App SDK `3.2.0`；旧 `sdkVersion/appSdkVersion` 直接拒绝，
不会解析到当前发行版，也不提供旧根命名空间 shim。Game SDK 4 的游戏域全部位于
`playmesh.main.*`，App SDK 3.2 的终端域全部位于 `playmesh.app.*`；根
`playmesh.ready` 是唯一例外。旧 `playmesh.<游戏域>` 访问和旧 `playmesh.js` 文件
均不兼容、不保留。其他版本拒绝运行，不会静默切换。执行器内部的
`supportedVersions` 只校验当前实际 bundle，不能扩大清单允许版本；发生破坏性变化时
替换当前精确发行和受影响执行器，不保留历史发行解析。正式构建再生成
最新版 `sdk-src/*.ts` 和 `/playmesh/sdk/v1/*` 静态产物，内置工作区、AI 项目提示词
和 CLI/IDEA 均使用最新注册表内容。

开发者 Gateway 同时提供 AI 可直接读取的正式契约：

- `/dev/sdk-manifest.json`：逐方法签名、角色、环境、约束、返回值和错误。
- `/dev/schemas/sdk-v1.json`：`Player`、`SessionSnapshot`、`AuthorityContext`、`AuthorityResult`、生命周期和 Bootstrap Schema。
- `/dev/schemas/game-manifest.json`：`main.json` Schema。
- `/dev/schemas/game-capabilities.json`：可选 `capabilities.json` Schema。
- `/dev/api/capabilities`：平台能力 code、中文名、说明和
  `supportedPlatforms`（`WINDOWS`、`ANDROID`、`HTML`）适配列表。
- `/dev/api/capability-tests`：GET 读取由同一注册表生成的自检项，POST 测试全部或指定平台能力。
- `/dev/openapi.json`：项目、文件、历史、校验、运行、事件和 AI 上下文接口。

这些资源和 `/dev/*` API 使用持久开发者工作区 token 鉴权。AI 应先读取正式契约和当前项目源码，再创建或修改项目，随后调用项目校验、运行接口并读取 SSE/Console 日志。

## 引入与就绪

```html
<script src="/playmesh/sdk/v1/playmesh-main.js"></script>
```

## 双 SDK 边界

游戏代码始终只显式引入 `/playmesh/sdk/v1/playmesh-main.js`。两个 SDK 的职责按
“公共游戏状态”和“当前终端状态”严格拆分：

- `playmesh-main.js` 是所有平台、所有玩家共同使用的公共 Game SDK，只公开
  `playmesh.main.*`。相同方法具有相同语义；`gameInfo`、会话、玩家、角色、消息、
  同步、生命周期和 Bucket 数据由 Authority 主机或其受控运行时提供。
- `playmesh-app.js` 是当前玩家所在终端的 App SDK，只公开 `playmesh.app.*`。平台、
  身份、设备能力、权限、全屏、终端输入、locale、性能、本机 Console 日志和平台
  覆盖层由当前终端提供，因此 Windows、Android 和普通浏览器上的返回值可以不同。
- 面向游戏开发者的唯一全局对象是 `window.playmesh`，其根级公开成员严格只有
  `ready`、`main` 与 `app`。`window.playmeshApp` 不存在，公开的 `main`/`app`
  不包含任何 `__*` 内部桥接成员；SDK 内部协作通过不可枚举的私有 `Symbol` runtime
  完成，不进入声明、Manifest、提示词、补全或游戏可调用 API。
- App SDK 可以通过内部适配器读取 `playmesh.main.*` 的公共数据以渲染覆盖层，但
  不得从私有 runtime 配置、原生桥或 URL 再构造一份
  游戏信息、会话、玩家或角色状态。FPS 和联机延迟属于当前客户端，只由
  `playmesh.app.performance.*` 提供。
- Game SDK 不得伪造终端身份、硬件能力、权限或本机日志；跨设备日志不得汇总到 Authority。

游戏入口必须包含标准 `playmesh-main.js` 标签，平台据此注入 Authority 运行配置；
缺少标签的页面不是有效的 SDK 游戏入口。Playmesh App WebView 使用当前终端从本机
回环入口提供的 `playmesh-app.js`；普通浏览器使用 Authority 主机分享网关提供的
默认 `playmesh-app.js`。两者都会在主 SDK 之前自动注入，游戏代码不得自行引入该
文件，也不得手动设置 App 用户 ID。普通浏览器中的
`playmesh.app.isAvailable()` 为 `false`，但默认 App SDK 仍负责居中菜单、游戏信息、
运行日志和仅普通浏览器显示的可拖动悬浮按钮：

```js
const ready = await playmesh.ready;

if (playmesh.app.isAvailable()) {
  const identity = playmesh.app.identity.getCurrent();
  const capabilities = playmesh.app.capabilities.getAvailable();
  console.log(ready.main.gameInfo, identity, capabilities);
}
```

App 环境中 `playmesh.app.identity.getCurrent()` 返回 App 自动注入的持久化 `{ userId, nickname, source }`。`playmesh.app.capabilities` 提供 `getRegistry()`、`getDeclared()`、`getAvailable()` 与 `create(code, options)`；`device` 只保留平台、触感、全屏和统一输入等非插件宿主操作。普通浏览器中 `isAvailable()` 为 `false`、身份为 `null`、能力列表为空，创建插件实例会返回明确的不可用错误。

## 运行环境与传输抽象

不同加入方式的底层传输由平台透明处理。游戏代码始终使用同一套 Game SDK，不得探测底层链路、读取或保存分享参数，也不得按加入方式分叉会话协议。App 加入页运行在稳定的本机来源下；普通浏览器只通过主机提供的局域网入口加入。安全上下文并不等于具体能力一定可用，游戏仍须以 `playmesh.app`、能力声明和浏览器特性检测结果为准，并处理用户拒绝或平台不支持。

Authority 面向游戏只公开外层物理 `app/` 映射到运行时 `/` 的普通资源、
`/bucket/**`、`/playmesh/**` 和 SDK 无法替代的受控底层连接能力。`app` 是普通
用户路径首段：物理 `app/app/**` 映射为 `/app/**`，且不会别名到外层 `app/**`；
只有 `playmesh`、`bucket` 是平台保留首段。身份、昵称、会话和 JSON 存储均通过
SDK 完成，游戏不得构造内部 HTTP API、WebSocket、token 或连接参数。

浏览器玩家由主 SDK 生成 `p_...` ID，并把 ID 写入浏览器 `localStorage` 的 `playmesh.player-id.v1`；昵称写入 `playmesh.nickname.v1`。同一来源刷新后会复用这两项，但不持久化玩家凭证或游戏 Bucket。App 玩家使用 App 自己的 `u_...` ID 和资料，不读写浏览器 ID。服务端只允许同一玩家 ID 存在一条在线 WebSocket；旧连接在线时新连接被拒绝，旧连接掉线后才允许同 ID 重新加入。

```js
await playmesh.ready;
console.log(playmesh.main.version); // "4.0.0"
console.log(playmesh.app.version); // "3.2.0"
```

`playmesh.app.ready` 等待当前终端 App SDK 初始化；`playmesh.main.ready` 内部先
等待它，再继续 Game SDK、身份、能力确认与会话初始化。根 `playmesh.ready` 是公开根对象
唯一额外成员：它只复用 `main.ready` 初始化链并返回 `{ main, app }`，其中 `main` 是
`playmesh.main.ready` 的 `PlaymeshBootstrap` 结果，`app` 是
`playmesh.app.ready` 的同一个稳定 `PlaymeshAppBootstrap` 结果。普通浏览器没有原生
Bridge 时，App 结果以 `available: false` 正常就绪；页面存在原生 Bridge 时，
bootstrap 超时、版本拒绝或宿主错误会直接使 `app.ready`、`main.ready` 与根
`playmesh.ready` 拒绝，不会伪装成浏览器降级。若当前页面角色在
`capabilities.json` 中对应的能力
列表非空，主 SDK 会先在网页内显示隔离样式的能力确认弹窗；App 与浏览器每次加载都会
重新显示，不保存结果。用户同意后继续初始化，即使某项标记为“本平台暂不支持”也不会
阻塞；用户拒绝时 Promise 以 `capability_denied` 拒绝，并由 SDK 请求退出当前游戏。

Game SDK 会把当前页面的方向传给 App SDK 宿主桥；普通浏览器首页与控制器首页会在不显示提示层、不阻塞 SDK 初始化的前提下尽力调用 Fullscreen API，并在成功后尝试 Screen Orientation API。浏览器因缺少用户手势等原因拒绝时只记录信息并继续游玩，用户仍可通过居中游戏菜单的全屏操作再次触发。通过 App 打开的联机页面自动使用 App 身份和昵称；普通浏览器读取 `localStorage` 中的玩家 ID 与昵称，缺失时由 SDK 生成 ID 或弹出昵称输入层，然后建立 WebSocket。单机浏览器分享页完成 SDK 初始化后不创建玩家和 Session、不显示昵称界面，也不建立 WebSocket。其他初始化失败时 Promise 会拒绝，页面应展示可恢复错误。

## 游戏声明

`playmesh.main.gameInfo` 是覆盖层和游戏代码读取游戏声明的唯一公共来源：

```js
await playmesh.ready;
const info = playmesh.main.gameInfo.getCurrent();
console.log(info.id, info.name, info.displayMode);
```

返回值包含稳定 `id`、显示名称 `name`、最多 5 个清单 `tags`、`multiplayer`、`displayMode` 和当前页面角色的 `requiredCapabilities`。单机、Authority 主机、App 加入者和普通浏览器都使用同一接口；数据由当前 `playmesh-main.js` 运行时提供。`playmesh-app.js` 的 bootstrap 不包含 `game` 副本，平台游戏信息覆盖层也只读取此接口。

能力确认、普通浏览器工具栏、昵称、信息与日志层都属于 Playmesh 平台 UI。它们的
文字来自宿主 App 当前 locale 的统一 `app.json`，App WebView 会随 App 语言即时更新；
普通浏览器由分享网关注入所有启用语言的受限平台投影，SDK 再按 `navigator`
语言为覆盖层做精确/主语言匹配和 fallback。该配置是平台私有链路，本身不向游戏
暴露 messages，也不改变 `playmesh.ready` 或 API JSON；
游戏只能通过下一节独立的只读 locale 接口选择自己的翻译。平台配置不会翻译游戏
DOM、游戏资源、标签、用户内容和日志原文。游戏不得读取、覆盖或复制平台词典，也
不需要为这些平台 UI 编写中英文分支。

## 游戏业务 locale

等待 SDK 就绪后，可以同步读取当前实际显示端的 locale：

```js
await playmesh.ready;
const locale = playmesh.app.runtime.getLocale(); // 例如 "zh-CN" 或 "en-US"
```

`playmesh.app.runtime.getLocale(): string` 是只读接口：

- App WebView 返回当前显示该游戏的本机 App locale。远程加入时返回加入方 App
  locale，不继承也不查询 Authority 主机语言；App 切换语言后再次调用会得到新值。
- 普通浏览器依次检查 `navigator.languages`、`navigator.language`，直接返回第一
  个合法的系统 locale；读取失败或值非法时返回 `zh`。返回值不受 Playmesh
  平台覆盖层已启用 locale 限制，例如浏览器为 `ja-JP` 时仍返回 `ja-JP`。
- 接口只返回 locale 字符串，不返回 App 的 `app.json`、`platform.game.*` 或任何
  messages。

Playmesh 只负责自身平台覆盖层的翻译，不自动翻译游戏。游戏开发者应在游戏包中维护
自己的业务语言资源，并按该 locale 渲染游戏 DOM、图片、音频、标签和其他内容；用户
生成内容与原始日志通常应保持原样。浏览器系统 locale 若不在平台覆盖层语言集合中，
覆盖层会独立按主语言匹配并最终回退 `zh-CN`，不会改写上述 SDK 返回值。

事件订阅 API 都返回取消订阅函数：

```js
const unsubscribe = playmesh.main.session.onStateChange(renderSession);
unsubscribe();
```

## App 能力插件

游戏在根 `capabilities.json` 中按角色声明能力 code：`required` 属于主画面，单屏多人的 `controllerRequired` 属于控制器。SDK 只向当前页面暴露当前角色声明的集合。主 SDK 在 App 和普通浏览器中统一请求用户确认；普通浏览器会把不可用能力标为“本平台暂不支持”，但同意后仍进入游戏。能力声明只用于 WebView 敏感权限和 Playmesh 多平台原生适配能力。每个能力拥有独立插件；插件可以暂时没有方法和事件，也可以通过后续 `apiVersion` 增加原生方法。

弹窗、开发者工作区的项目设置和能力测试都读取同一份平台注册表。注册表公开 code、中文说明、插件 `apiVersion`、方法、事件和平台状态；工作区能力测试始终显示全平台注册表，不按当前项目声明过滤。

```js
const stream = await navigator.mediaDevices.getUserMedia({
  video: true,
  audio: true,
});
const midi = await navigator.requestMIDIAccess({ sysex: true });
```

游戏声明相应 code 后，可直接使用标准 Web API 访问摄像头、麦克风或 MIDI；App
WebView 在权限回调中核对声明，未声明即拒绝，用户仍可在系统提示中拒绝。
`media.camera` 和 `device.midi` 当前不创建能力实例。`media.microphone@1.1.0` 另外
支持 `capabilities.create("media.microphone")`，实例方法
`toText({localeId, listenFor, pauseFor})` 启动一次短语音识别，并通过
`textOnSoundLevelChange`、`textOnResult` 事件返回输入级别和完整识别结果。

加速度计、陀螺仪和设备方向直接使用 Generic Sensor、Device Motion 或 Device
Orientation 等标准 Web API，不声明 Playmesh 能力。`<input type="file">` 由用户
主动选择文件，也不声明能力。

有公开方法或事件的能力实例固定提供 `invoke(method, args)`、`on(event, callback)`、
`addEventListener(event, callback)`、`removeEventListener(event, callback)`、
`onError(callback)` 和 `dispose()`；DOM 风格方法是兼容别名，既有 `on()` 仍返回取消
订阅函数。具体语义以插件 `apiVersion` 为准。

`device.vibration@2.0.0` 是主动调用型插件，创建参数为 `{}`，不产生事件。它通过
`vibration` 插件公开 `vibrate` 和 `cancel`。`vibrate` 支持默认调用以及
`duration`、`pattern`、`repeat`、`intensities`、`amplitude`、`sharpness`、
`preset` 全部参数形态：

```js
if (playmesh.app.capabilities.getAvailable().includes('device.vibration')) {
  const vibration = await playmesh.app.capabilities.create(
    'device.vibration',
    {},
  );
  await vibration.invoke('vibrate', { duration: 1000, amplitude: 128 });
  await vibration.invoke('vibrate', {
    pattern: [0, 100, 50, 200],
    intensities: [0, 128, 0, 255],
    repeat: -1,
  });
  await vibration.invoke('vibrate', { preset: 'quickSuccessAlert' });
  await vibration.invoke('cancel', {});
  await vibration.dispose();
}
```

`preset` 按插件行为覆盖其他参数。非空 `intensities` 必须与 `pattern` 等长；
`repeat` 必须是 `-1` 或有效 pattern 索引。具体预设枚举以能力注册表为准。

### `sensor.pose6d` 与 `playmesh.app.media`

支持 ARCore 的 Android 终端提供 `sensor.pose6d@1.0.0`。位姿通过轻量能力事件传递，
视频只在网页按需打开：

```js
const pose = await playmesh.app.capabilities.create("sensor.pose6d", {
  rateHz: 30,
});

pose.addEventListener("pose", (frame) => {
  updatePose(frame.position, frame.rotation);
});

const source = await pose.invoke("openVideo", {
  width: 1280,
  height: 720,
  fps: 30,
});
const media = await playmesh.app.media.open(source);
video.srcObject = media.stream;

await media.close();
await pose.dispose();
```

`position` 是米制 `[x,y,z]`，`rotation` 是 `[x,y,z,w]` 四元数。
`captureTimestampNs` 是纳秒时间戳字符串，`trackingState` 为 `tracking`、`paused`
或 `stopped`。`pose.invoke("recenter", {})` 把当前或下一次有效跟踪结果设为该实例的
游戏原点。

`openVideo()` 返回的是受控媒体源描述符，不是 URL；`createVideoSource()` 是同契约
的描述性别名。公开媒体入口固定为：

```ts
playmesh.app.media.open(
  source: PlaymeshAppMediaSource,
  options?: { signal?: AbortSignal },
): Promise<PlaymeshAppMediaSession>
```

返回会话包含只读 `id/source/stream/state` 与幂等 `close()`；`stream` 是标准
`MediaStream`。当前 WebRTC 适配器在同一终端的 WebView 与原生宿主之间通过已有 App
SDK 宿主桥完成 offer/answer，因此不需要游戏部署信令服务器，也没有可由网页请求的媒体
地址。源不能跨页面、跨终端或在释放后复用。完整能力说明见
[游戏能力使用指南](capability-plugins.md)。

## 会话

### `playmesh.main.session.getCurrent()`

返回当前会话快照；SDK 尚未就绪时返回 `null`。

```ts
interface SessionSnapshot {
  id: string;
  joinCode: string;
  gameId: string;
  displayMode: "multi_screen" | "single_screen_multiplayer";
  state: "lobby" | "running" | "paused" | "stopped";
  minPlayers: number;
  maxPlayers: number;
  authorityClientId: string;
  players: Player[];
}
```

创建并运行会话的 App 主机固定为 Authority Client。大屏主机不在 `players` 中；普通多屏 App 主机可在集合中作为 Player，但集合位置与加入顺序没有 Authority 语义。

### `playmesh.main.session.onStateChange(callback)`

订阅会话快照。若 SDK 已就绪，注册时立即回调当前值，之后在成员或会话状态变化时再次回调。

### `playmesh.main.session.isAuthority()`

当前页面属于 Authority Client 时返回 `true`。只有 Authority 页面可以注册权威服务。

### 玩家连接事件

```js
const offJoin = playmesh.main.session.onPlayerJoin(({ player, session, isCurrentPlayer }) => {});
const offLeave = playmesh.main.session.onPlayerLeave(({ player, session, isCurrentPlayer }) => {});
const offReconnect = playmesh.main.session.onPlayerReconnect(({ player, session, isCurrentPlayer }) => {});
```

- `onPlayerJoin`：某个玩家 ID 在本局第一次真正建立 WebSocket 时触发。
- `onPlayerLeave`：在线玩家变为离线时触发。玩家仍保留在 `session.players`，其 `connected` 为 `false`，便于游戏保留中途状态。
- `onPlayerReconnect`：曾经在线的同一持久化玩家 ID 建立新连接时触发。

三个事件都返回取消订阅函数。事件对象中的 `player` 是变化后的玩家，`session` 是最新会话快照，`isCurrentPlayer` 表示该事件是否属于当前页面。游戏应使用这些事件暂停玩家操作、保留席位或恢复画面；不要自己把昵称当作重连主键。

### `playmesh.main.session.start()`

仅请求 Core 把满足基础状态与人数约束的会话切换为 `running`，返回 Promise。SDK 不判断准备、倒计时或玩法开始条件；这些业务规则必须由游戏 Authority 自行维护并确认后调用。大屏游戏应由控制器提交准备状态，再由 Authority 倒计时触发，不能在公共显示端提供玩家可点击的开始按钮。

### `playmesh.main.session.finish()`

仅 Authority 可调用，并且应由游戏规则先确认胜负或本局结束；SDK 本身不判断结束条件。该请求把基础会话切换为 `stopped` 并自动释放所有已掉线成员；仍在线玩家继续保留，可在下一局再次开始。Core 仅在 `running` 或 `paused` 状态保留 `connected: false` 的掉线玩家；大厅掉线、`finish()`、App 重置或重新开始都会自动清理离线席位，因此游戏不需要自行维护幽灵成员列表。

## 玩家

### `playmesh.main.player.getCurrent()`

```ts
interface Player {
  id: string;
  nickname: string;
  avatar: string | null;
  role: "authority" | "authority_player" | "player";
  connected: boolean;
}
```

返回当前玩家；SDK 尚未就绪或当前是大屏公共 Authority 页面时返回 `null`。

`avatar` 与 `nickname` 同级。App 玩家头像由平台自动同步，成功后为
`/bucket/_sys-user-avatars/{playerId}.png`；无自定义头像、尚未同步或 HTML
玩家均为 `null`。游戏不能设置头像。该字段同样出现在 Bootstrap、会话快照、
玩家连接事件、Authority 上下文和 Sync 上下文的所有 `Player` 中。

公开 `Player` 固定只包含 `id`、`nickname`、`avatar`、`role` 和
`connected`。Core 用于连接管理的 `source`、`latencyMs` 及其他内部字段会在
Game SDK 边界统一过滤，不会进入 Bootstrap、会话快照、玩家连接事件、
Authority 上下文或 Sync 上下文。游戏如需观察当前页面的联机延迟，应使用
`playmesh.app.performance`，不能依赖玩家内部连接元数据。

`authority_player` 表示普通多屏 App 主机同时参与为 Player；Authority 资格仍只由 App 创建会话时登记的 `authorityClientId` 与 `playmesh.main.session.isAuthority()` 决定。`authority` 是单屏多人公共显示端的宿主身份，该页面的 `getCurrent()` 为 `null`；所有加入者均为 `player`，无论加入顺序都不会成为 Authority。

### `playmesh.main.player.setNickname(nickname)`

仅普通浏览器可用。更新当前玩家昵称、广播新的会话快照并把成功后的昵称写回浏览器本地缓存；玩家 ID 和凭证不会变化。App WebView 调用会 reject。

```js
await playmesh.main.player.setNickname("新昵称");
```

浏览器版 SDK 会在游戏菜单的“游戏信息”弹窗中提供昵称修改入口，游戏不需要再制作昵称设置界面。昵称去除首尾空白后长度必须为 1 至 32 个字符。

## 游戏消息

### `playmesh.main.game.submitAction(action)`

提交一个 JSON 业务动作，返回 Promise。SDK/宿主负责附加可信发送者和会话上下文；游戏不要在动作里信任自报玩家身份。

```js
await playmesh.main.game.submitAction({ type: "player.ready", ready: true });
```

浏览器和 App 玩家都通过同一语义提交动作。游戏不得直接创建 WebSocket。

### `playmesh.main.game.onMessage(callback)`

订阅 Authority 已路由的业务消息。

```js
const off = playmesh.main.game.onMessage((message) => {
  if (message.type === "state.updated") render(message.state);
});
```

### `playmesh.main.game.onEvent(callback)`

当前 v1 是 `onMessage` 的别名，订阅相同消息流。新代码优先使用 `onMessage`，避免把业务消息误解为单独的事件通道。

## 权威状态同步

多人游戏优先使用 `playmesh.main.sync`，业务代码只定义初始状态、语义输入和可选 tick 规则。SDK 负责输入限频与合并、Authority tick、完整快照版本与分发。非 Authority 多人页面重载后会自动请求最新快照；Authority 页面重载会重建同步 runtime，需要恢复的权威状态必须先从 `playmesh.main.storage` 读取，再作为 `initialState` 启动。

```js
if (playmesh.main.session.isAuthority()) {
  playmesh.main.sync.startAuthority({
    initialState: { score: 0, position: { x: 0, y: 0 } },
    tickRate: 10,
    onInput(input, context) {
      if (input.type === "score.add") {
        return { ...context.state, score: context.state.score + 1 };
      }
      return context.state;
    },
    onTick({ state, inputs, dt }) {
      const movement = Object.values(inputs)[0]?.movement?.value;
      if (!movement) return state;
      return { ...state, position: {
        x: state.position.x + movement.x * dt,
        y: state.position.y + movement.y * dt,
      }};
    },
  });
}

await playmesh.main.sync.submitAction({ type: "score.add" });
await playmesh.main.sync.submitState("movement", { x: 1, y: 0 }, { rateHz: 20 });
const off = playmesh.main.sync.observe((snapshot) => render(snapshot.state));
```

`startAuthority` 仅 Authority 可用，`tickRate` 为 1 至 20 的整数，返回控制器：`getState()`、`setState(nextState, publish?)`、`publish(targetPlayerIds?)` 和 `stop()`。`onInput` 收到可信 `senderPlayerId`、当前状态和输入类型；`onTick` 收到 `dt`、`tick`、按玩家和 key 合并后的连续输入、会话与成员。

`submitAction(payload)` 发送一次性语义输入。`submitState(key, value, {rateHz})` 对同一 key 只保留最新值并把发送频率限制到 1 至 20 Hz，适合方向、摇杆等连续输入。`requestSnapshot()` 可显式请求最新完整快照；SDK 在普通多人页面就绪时也会自动请求。

`getSnapshot()` 返回最近快照，`observe(callback)` 注册时会立即回调已有快照。快照包含 `protocolVersion`、`stateType`、`full`、`revision`、`sequence`、`timestamp`、`sourceTick` 和 JSON `state`。当前实现始终发送完整快照；页面应以最新快照为准，不自行拼接不可信增量。

底层 `playmesh.main.game` 与 `playmesh.main.authority` 提供给需要自定义消息路由的
高级游戏，但同一个输入不应同时走两套协议。

## App 级平台功能

统一菜单与兜底覆盖层能力位于 `playmesh.app.ui`。App WebView 与普通浏览器都会
注入 `playmesh-app.js`；`playmesh.app.isAvailable()` 只表示原生 App SDK 宿主桥是否
可用，不影响浏览器使用 SDK 游戏菜单。

### `playmesh.app.ui.openSharePanel()`

当前 Authority 游戏可以在有效用户操作中请求 App 打开既有“二维码与链接”界面：

```js
button.addEventListener("click", async () => {
  await playmesh.app.ui.openSharePanel();
});
```

Promise 在界面成功显示后完成，不返回 Token、URL 或二维码内容。SDK 与 App
都会重新检查 Authority 身份和瞬时用户激活；非 Authority、后台页面或平台 UI
不可用时分别以 `not_authority`、`user_activation_required` 或
`ui_unavailable` 拒绝。界面已打开时重复调用复用同一层并重新聚焦关闭按钮；
关闭后的短暂重复请求以 `rate_limited` 拒绝。

SDK 会在发出命令前同步记录当前游戏 DOM 的焦点元素。分享层关闭后，App 通过
不属于公开 API 的宿主消息要求 SDK 恢复该元素；元素已经移除时回退到游戏文档，
普通浏览器再回退到游戏文档。这个私有过程不会把分享 Token、链接、二维码
或 App 本地化词典暴露给游戏。

### 居中游戏菜单

```js
await playmesh.app.ui.showGameSidebar();
await playmesh.app.ui.exitGame();
```

`showGameSidebar()` 手动打开 SDK 在当前 WebView/HTML 中创建的居中游戏菜单，并把焦点移到
“继续游戏”。菜单自身负责关闭和恢复游戏 DOM 焦点，因此不公开
`hideGameSidebar()`；也不提供 `onMenuRequest` 或原生按键转发。游戏菜单打开或关闭
只改变 SDK UI，不发送 `pause` / `resume` 生命周期事件。
`exitGame()` 请求 App 正常结束当前游戏、执行退出清理并返回上一 App 页面；不需要
先打开游戏菜单。`showGameSidebar()` 的名称为兼容既有公开契约而保留，不代表菜单仍位于侧边。

游戏可以在 SDK 就绪前关闭统一兜底 UI：

```js
playmesh.app.ui.configure({ fallbackUi: false });
```

此时 SDK 不创建游戏菜单、悬浮球、信息层或日志层，也不消费菜单/返回按键。普通浏览器
若仍想使用 SDK 游戏菜单、但由游戏自己的按钮负责打开，可以调用：

```js
playmesh.app.ui.initializeBrowser(); // 浏览器返回 true；App WebView 返回 false
customMenuButton.onclick = () => playmesh.app.ui.showGameSidebar();
```

`initializeBrowser()` 不创建悬浮球 DOM。默认浏览器兜底模式则创建可拖动的悬浮菜单
按钮；App WebView 永远不创建该按钮。

App SDK 在 console 日志写入点先把每个参数安全转换为字符串，再拼成最终消息并同时
交给 SDK 日志层与宿主日志管线。对象和数组使用 JSON 文本，因此 SDK“运行日志”与
开发者工作台会一致显示 `{"score":10}`，不会再由渲染端得到 `[object Object]`。

## Authority

### `playmesh.main.authority.onService(handler)`

只允许 Authority Client 注册。非 Authority 调用会抛出错误。返回注销函数。

```ts
type AuthorityContext = {
  senderPlayerId: string;
  session: SessionSnapshot;
  members: Player[];
};

type AuthorityResult = {
  targetPlayerIds: string[];
  message: object;
};
```

处理器可以异步返回单个 `AuthorityResult`、结果数组、`null` 或 `undefined`。无效结果会被忽略。

`targetPlayerIds` 通常使用 `context.members[].id`。单屏多人公共显示端不在 `members` 中；若主屏也要接收同一条状态消息，需要同时加入 `context.session.authorityClientId`，并确保目标 ID 不重复。

```js
playmesh.main.authority.onService(async (action, context) => ({
  targetPlayerIds: context.members.map((member) => member.id),
  message: { type: "action.accepted", action },
}));
```

规则、分数、答案和胜负应由处理器维护。Go Core 不解析游戏业务。

## Binary Channel

`playmesh.main.binary` 用于不适合 JSON 的高频或二进制数据，例如局域网内的位姿、语音片段、压缩快照和自定义序列化状态。SDK 按需建立独立 Binary WebSocket；同一游戏只维护一条该连接，并在其上复用多个相互隔离的逻辑 Channel。游戏不能直接创建 WebSocket、读取 URL/token 或解析平台帧头。

只有 Authority 可以创建和关闭 Channel；创建者会自动加入。其他玩家获得 Channel ID 后调用 `joinChannel(id)`。Authority 使用固定玩家 ID `playmesh.main.binary.authorityPlayerId`（值为 `"authority"`）。所有角色都使用同一组发送方法：

- `send(playerId, data)`：可靠单发。
- `send(playerIds, data)`：用一个上行二进制帧可靠发送给多个目标，由 Core 扇出。
- `send(data)`：可靠广播给当前 Channel 中除自己外的全部在线成员。
- `sendLatest(playerId | playerIds, data)`：定向发送，但尚未发出的旧帧只保留同一目标集的最新值。
- `sendLatest(data)`：广播，并只保留尚未发出的最新广播值。

```js
await playmesh.ready;

let channel;
if (playmesh.main.session.isAuthority()) {
  channel = await playmesh.main.binary.createChannel({ mode: "authority" });
  console.log(channel.id); // 通过可靠业务消息分享给其他玩家
  channel.onForward((data, context) => {
    console.log(context.targetPlayerIds); // 即使单发也始终是 string[]
    // undefined：原样通过；Uint8Array：替换后通过；throw：拒绝
    return data;
  });
} else {
  channel = await playmesh.main.binary.joinChannel(channelIdFromAuthority);
  await channel.send(
    playmesh.main.binary.authorityPlayerId,
    new Uint8Array([1, 2, 3]),
  );
}

await channel.send([playerA, playerB, playerC], reliableEvent);
await channel.sendLatest([playerA, playerB, playerC], newestSnapshot);
await channel.send(reliableBroadcast);
await channel.sendLatest(newestBroadcastSnapshot);

channel.onMessage((data, context) => {
  console.log(context.senderPlayerId, context.delivery, data);
});
```

`mode: "relay"` 直接转发字节；`mode: "authority"` 中，非 Authority 发送先进入 Authority `onForward`。Authority 自己主动发送时直接投递，不再次审核。Channel ID 本身就是加入令牌，只应通过当前游戏的可靠消息分享给本局成员。

多目标发送只上传一次 payload，Core 对去重后的目标数组执行扇出；最多指定 1024 个目标。`mode: "authority"` 下同一个多目标帧只触发一次 `onForward`，`context.targetPlayerIds` 始终为数组，Authority 返回的替换数据或拒绝结果作用于这一帧的全部目标。

`send()` 可靠排队。带目标的 `sendLatest()` 以同一 Channel、发送者与规范化目标集为合并范围；单参数 `sendLatest(data)` 以广播为合并范围。Core 实际投递时仍按每个接收者分别替换尚未发送的旧帧。接收端统一由 `onMessage()` 处理，并通过 `context.delivery` 得知 `"queued"` 或 `"latest"`。如果 Authority 处理器已经开始执行某一旧帧，Core 不会忽略其返回值；旧新审核都会继续并各自完成转发或拒绝。

广播目标由 Core 在处理请求时根据当前 Channel 在线成员计算，并排除发送者；空房间广播直接成功。当前局域网保护上限为：单帧 4 MiB、每条连接 2000 帧/秒、64 MiB/秒入站、32 MiB 出站队列、每局最多 1024 个 Channel；Authority 审核最多挂起 1024 项或 128 MiB，单次审核 15 秒超时。达到可靠队列或审核上限时 Promise 会 reject；连续状态优先使用 `sendLatest()`。

## 生命周期

```js
playmesh.main.lifecycle.onChange((event) => {});
playmesh.main.lifecycle.onPause((event) => {});
playmesh.main.lifecycle.onResume((event) => {});
playmesh.main.lifecycle.onExit((event) => {});
```

`event.state` 可能为 `ready`、`pause`、`resume`、`exit`、`closed` 或 `error`；错误事件可能携带 `event.error`。所有方法返回取消订阅函数。

`onExit` 处理器可以返回 Promise，宿主会有限等待业务清理。关键进度仍应在状态变化时调用 `setData`，不要只依赖退出回调；最终存储落盘由 App 在 WebView 重启、退出或会话关闭时完成。

刷新游戏会收到旧 WebView 的退出通知，完成存储落盘后重建页面，但不会重置 Core 会话；会话 ID、联机码、已连接玩家、分享网关和 token 均保留。真正退出游戏才销毁会话。

## 存储

### `playmesh.main.storage.getBucket(bucket)`

Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。所有 `_sys-`
前缀均由平台保留，游戏的数据、上传和清空 API 会统一拒绝，不能占用头像等系统
Bucket。

```js
const profile = playmesh.main.storage.getBucket("profile_v1");

const coins = await profile.getData("coins");
await profile.setData("coins", (coins ?? 0) + 1);
await profile.removeData("temporary_flag");
await profile.clearData();
```

| 方法 | 返回 | 说明 |
|---|---|---|
| `getData(key)` | `Promise<any>` | 读取 key；不存在时由宿主返回空值 |
| `setData(key, value)` | `Promise` | 写入可 JSON 序列化值 |
| `removeData(key)` | `Promise` | 删除单个 key |
| `clearData()` | `Promise` | 清空当前 Bucket |
| `upload(file)` | `Promise<string>` | 上传原始文件并返回 `/bucket/...` 地址 |

key 必须匹配 `^[A-Za-z0-9._-]+$`，长度为 1 至 128。当前 SDK 会用 `JSON.stringify` 检查写入值；不要写入函数、循环引用或依赖对象原型的实例。

当前宿主限制单个值序列化后不超过 256 KiB。修改先进入主机内存缓存，默认在 2 秒后批量写盘；同一 Bucket 累积 20 次脏写时会提前落盘。`setData()` 完成表示宿主已经接收修改，不表示每次调用都单独写盘。游戏没有显式 flush 能力；App 在 WebView 重启、退出或会话关闭前等待最终写入完成。

JSON 数据最终写入开始游戏的 Authority 主机 `packages/{gameId}/data/json/{bucket}.json`，始终保持私有。`upload(file)` 不经过 JSON/Base64，文件以流写入 `packages/{gameId}/data/data/{bucket}/{timestamp-ms}.{ext}`，单文件上限 256 MiB；平台保留安全的字母数字后缀并用毫秒时间戳替换原文件名。

上传返回的 `/bucket/{bucket}/{file}` 是当前游戏运行期间可直接用于 `img/audio/video/fetch` 的同源地址。网页只映射 `data/data`，不提供目录列表，也不会映射 `data/json`。除 `upload(file)` 使用受控 `/bucket/**` 上传外，JSON 读写只经 Game SDK 的受控连接交给 Authority，不存在公开的存储 HTTP 业务接口。浏览器 `localStorage` 只允许 SDK 保存玩家 ID 与昵称偏好，不保存玩家凭证或 Bucket；其他 App 玩家通过 Authority 主机的同一存储服务访问。

平台不定义 `{userId}` 存储层。需要按用户区分时，由游戏设计 key 或 JSON 结构。

## 性能

### `playmesh.app.performance.reportFrame(timestamp?)`

报告一帧真实游戏画面已经完成。`timestamp` 必须是有限数字，省略时使用 `performance.now()` 或 `Date.now()`。App SDK 按约一秒窗口计算整数 FPS，并只在本地内存中更新读取接口、监听器和覆盖层，不把 FPS 上报给 Dart。

```js
function frame(timestamp) {
  update();
  drawCanvas();
  playmesh.app.performance.reportFrame(timestamp);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
```

SDK 不启动独立 RAF。Canvas/WebGL 应在实际绘制或提交后调用；没有真实逐帧渲染的游戏无需调用。

### `playmesh.app.performance.getFps()`

返回最近一次计算出的 FPS；尚未形成统计窗口时返回 `null`。

### `playmesh.app.performance.onFps(callback)`

订阅 FPS。注册时立即回调当前值，之后在产生新统计值时回调。返回取消订阅函数。

### `playmesh.app.performance.setVisible(visible)`

显示或隐藏当前客户端的 App SDK 性能浮层。该操作只影响当前页面，不广播状态，也不改变
游戏生命周期。

### 自动联机延迟

多人会话就绪后，App SDK 每 3 秒生成唯一 probe ID 并调度一次经过 Core 和 Authority 在线状态确认的往返探测。Game SDK 只把 ping 送入既有 Session transport，并把收到的原始 pong 转交 App SDK；RTT 计算和平滑只在 App SDK 内存完成，Dart 不保存或上报指标。单机游戏不探测、不显示延迟。最近的平滑 RTT 由以下接口读取：

```js
const latencyMs = playmesh.app.performance.getLatency();
const diagnostics = playmesh.app.performance.getLatencyDiagnostics();
const off = playmesh.app.performance.onLatency((value) => console.log(value));
```

`getLatency()` 在尚无有效样本或 Authority 不在线时返回 `null`。诊断对象包含客户端发送/接收时间、Core 接收/发送时间、Authority 可用状态和原始 RTT，供开发诊断使用；游戏规则不得依赖延迟数值决定胜负。

FPS、联机延迟、居中游戏菜单、信息和日志覆盖层都由 `playmesh-app.js` 在网页内创建，并使用
Shadow DOM 与游戏样式隔离。新开、刷新或重连后游戏菜单、性能层、信息层和日志层默认
关闭；普通浏览器默认显示可拖动悬浮入口，App WebView 不显示悬浮入口。游戏菜单打开或
关闭不改变游戏生命周期。该性能浮层是唯一实现，Game SDK 不创建或保留旧浏览器性能
panel。

## 浏览器行为

- 当前页面角色对应的 `required` 或 `controllerRequired` 非空时，浏览器每次加载都由主 SDK 弹出能力确认；空数组是有效声明，绝不回退到另一角色。不支持项只做标注，不阻止同意后进入。
- 浏览器主游戏页和控制器页都会无弹窗尽力自动全屏，并在 SDK 游戏菜单保留全屏操作；`playmesh.ready` 和加入对局不依赖全屏成功。
- `playmesh-app.js` 在捕获阶段监听 `Escape`、浏览器返回键、Android Menu keyCode 和菜单键，第一次按下即可打开或关闭 SDK 游戏菜单；原生层不注入、不转发这些按键。
- 普通浏览器加载 Authority 主机提供的默认 App SDK；默认菜单至少提供继续、刷新、游戏信息、运行日志和退出游戏，且只有普通浏览器显示可拖动悬浮入口。
- 普通多人多屏分享加载清单显式声明的 `main.json.entries.game`，浏览器玩家加入
  Session 并建立 WebSocket；只有单屏多人分享才加载同样显式声明的
  `entries.controller`。缺失入口直接拒绝，不使用模板路径回退。
- 单机分享加载 `entries.game`，不加入多人 Session，也不建立会话 WebSocket；浏览器 Console 只保留在当前浏览器；`playmesh.main.session.getCurrent()` 与 `playmesh.main.player.getCurrent()` 返回 `null`。
- 自定义嵌套 HTML 入口由网关按入口所在目录设置页面基准 URL，页面内相对 CSS、脚本
  和图片仍解析到当前游戏的运行时根路径，不会改变 SDK、会话或存储边界。
- 浏览器入口由主机分享网关注入配置，游戏不能自行拼接地址或 token。
- 分享 URL 和宿主注入配置不携带临时昵称。SDK 首次进入时显示昵称输入层并写入 `localStorage`，后续刷新自动复用昵称。
- 浏览器每次刷新都重新调用加入接口，但复用 `localStorage` 中的玩家 ID 和昵称；短期凭证不持久化。运行中旧连接掉线后，同 ID 重连可由游戏恢复准备状态和临时玩家状态。
- SDK 在普通浏览器页面上提供隔离于游戏样式的居中游戏菜单和随系统明暗模式切换的二级弹窗；修改昵称后更新 Core 会话和本地昵称偏好。App 扫码加入环境复用同一个 `playmesh-app.js` 菜单实现。
- 旧浏览器连接断开后，其玩家从会话成员集合移除并释放人数名额；短暂的刷新竞态由 SDK 对 `session_full` 做有限重试。
- 刷新继续使用本局分享 token；退出游戏、会话关闭、App/Core 重启后旧 token 失效。
- 关闭分享面板和刷新游戏不会使 token 失效。
- 浏览器存储、动作与消息语义和 App WebView 保持一致，但浏览器不获得 App 原生硬件能力或用户私有资料。

## 错误处理

命令错误通过 Promise reject 返回：

```js
try {
  await playmesh.main.game.submitAction({ type: "round.join" });
} catch (error) {
  showError(String(error));
}
```

订阅回调中的异常由游戏自己处理。Authority 处理器抛出的异常会作为生命周期 `error` 事件暴露给 Authority 页面。

Console 日志由运行页面的宿主捕获，不经过 Game SDK 或游戏网关。Playmesh App 的 WebView 只把本设备当前页面的 `console.log/info/warn/error/debug` 写入本机运行日志流；其他 App 或浏览器玩家的日志不会传给 Authority。普通浏览器继续使用自身开发者工具查看本机 Console。App SDK 完成私有 `Symbol` runtime 注册、Game SDK 完成唯一公开全局 `window.playmesh` 赋值后，分别输出 `Playmesh App SDK 注入成功` 和 `Playmesh Game SDK 注入成功`；完成宿主握手后再输出对应的 `SDK 就绪` 日志，可直接区分“文件已注入”和“Bridge 已就绪”。单机 App 页面由本地 Game SDK Bridge 返回无多人 Session 的 bootstrap，并提供本地存储与生命周期命令；当前客户端性能由 App SDK 提供。Bridge 请求超过 15 秒会 reject 并产生未处理 Promise 日志，不会永久等待。App 在每次启动或刷新游戏前清空旧缓存，并在本次运行期间保留最近 500 条本机日志，即使游戏内日志面板没有打开；工作区和游戏内日志层都可一键复制最近日志。缓存不写磁盘，App 生命周期结束后清空。

## AI 开发依据

AI 必须以 SDK Manifest、Schema、OpenAPI、当前项目类型和当前项目源码为唯一开发
依据，不得从其他模式推断页面拓扑或联机逻辑。
