# Game SDK v1

本文记录 Game SDK `1.4.3` 与 App Bridge SDK `1.2.1` 的公开 API。`sdk-src/playmesh.ts` 和 `sdk-src/playmesh-app.ts` 是唯一手写源；构建生成 `/playmesh/sdk/v1/*.js` 与 `.d.ts`，内置工作区、AI 项目提示词和 CLI/IDEA 均使用这些同源产物。生成的声明文件内置完整中文 JSDoc，IDEA 的补全、参数信息和悬浮文档无需联网即可显示中文用途、返回值、环境边界和限制；AI 提示词会嵌入两份完整声明，并以其作为唯一接口事实源。

开发者 Gateway 同时提供 AI 可直接读取的正式契约：

- `/dev/sdk-manifest.json`：逐方法签名、角色、环境、约束、返回值和错误。
- `/dev/schemas/sdk-v1.json`：`Player`、`SessionSnapshot`、`AuthorityContext`、`AuthorityResult`、生命周期和 Bootstrap Schema。
- `/dev/schemas/game-manifest.json`：`main.json` Schema。
- `/dev/schemas/game-capabilities.json`：可选 `capabilities.json` Schema。
- `/dev/api/capabilities`：平台能力 code、中文名、说明和 App/HTML 适配状态。
- `/dev/api/capability-tests`：GET 读取由同一注册表生成的自检项，POST 测试全部或指定平台能力。
- `/dev/openapi.json`：项目、文件、历史、校验、运行、事件和 AI 上下文接口。

这些资源和 `/dev/*` API 使用持久开发者工作区 token 鉴权。AI 应先读取正式契约和当前项目源码，再创建或修改项目，随后调用项目校验、运行接口并读取 SSE/Console 日志。

## 引入与就绪

```html
<script src="/playmesh/sdk/v1/playmesh.js"></script>
```

## 双 SDK 边界

游戏代码始终只显式引入 `/playmesh/sdk/v1/playmesh.js`。该 SDK 连接创建对局的 Authority 主机，会话、联机消息和 `playmesh.storage` 都以 Authority 主机为唯一可信来源。App WebView 网关会在入口缺少该标签时补注入主 SDK，作为导入和开发运行的安全兜底。

Playmesh App WebView 会在主 SDK 之前自动注入 `/playmesh/sdk/v1/playmesh-app.js`。它只提供当前设备能力和 App 本地身份，不接管联机或游戏数据。游戏代码不得自行引入该文件，也不得手动设置 App 用户 ID。

普通浏览器不会下载或执行 `playmesh-app.js`。主 SDK 仍会提供安全的 `playmesh.app` 空实现，因此跨环境代码可以先检查能力而不会因为对象不存在而崩溃：

```js
await playmesh.ready;

if (playmesh.app.isAvailable()) {
  const identity = playmesh.app.identity.getCurrent();
  const capabilities = playmesh.app.device.getCapabilities();
}
```

App 环境中 `playmesh.app.identity.getCurrent()` 返回 App 自动注入的持久化 `{ userId, nickname, source }`。`playmesh.app.device` 当前提供 `getPlatform()`、`getCapabilities()`、`getDeclaredCapabilities()`、`haptic(style)`、`setFullscreen(enabled)`、`onInput(callback)` 和 `onDevice(...)`；`getDeclaredCapabilities()` 返回游戏声明，`getCapabilities()` 只返回本设备当前真正可用的能力，只有后者包含的能力才可订阅。普通浏览器中 `isAvailable()` 为 `false`、身份为 `null`、可用能力列表为空，原生操作返回明确的不可用错误。

浏览器玩家由主 SDK 生成 `p_...` ID，并把 ID 写入浏览器 `localStorage` 的 `playmesh.player-id.v1`；昵称写入 `playmesh.nickname.v1`。同一来源刷新后会复用这两项，但不持久化玩家凭证或游戏 Bucket。App 玩家使用 App 自己的 `u_...` ID 和资料，不读写浏览器 ID。服务端只允许同一玩家 ID 存在一条在线 WebSocket；旧连接在线时新连接被拒绝，旧连接掉线后才允许同 ID 重新加入。

```js
await playmesh.ready;
console.log(playmesh.version); // "1.4.3"
```

`playmesh.ready` 在 App WebView 中等待宿主 Bridge 注入。若 `capabilities.json.required` 非空，主 SDK 会先在网页内显示隔离样式的能力确认弹窗；App 与浏览器每次加载都会重新显示，不保存结果。用户同意后继续初始化，即使某项标记为“本平台暂不支持”也不会阻塞；用户拒绝时 Promise 以 `capability_denied` 拒绝，并由 SDK 请求退出当前游戏。

浏览器游戏首页与控制器首页还会显示不遮挡游戏的可选全屏浮层，但 SDK 初始化、昵称和会话加入不等待全屏结果；全屏失败或选择“暂不全屏”均不影响游玩。通过 App 打开的联机页面自动使用 App 身份和昵称；普通浏览器读取 `localStorage` 中的玩家 ID 与昵称，缺失时由 SDK 生成 ID 或弹出昵称输入层，然后建立 WebSocket。单机浏览器分享页完成 SDK 初始化后不创建玩家和 Session、不显示昵称界面，也不建立 WebSocket。其他初始化失败时 Promise 会拒绝，页面应展示可恢复错误。

事件订阅 API 都返回取消订阅函数：

```js
const unsubscribe = playmesh.session.onStateChange(renderSession);
unsubscribe();
```

## App 设备传感器

游戏先在根 `capabilities.json` 的 `required` 中声明 `sensor.accelerometer` 或 `sensor.gyroscope`。主 SDK 在 App 和普通浏览器中统一请求用户确认；普通浏览器会把这两个能力标为“本平台暂不支持”，但同意后仍进入游戏，其安全空实现不会产生传感器回调。

弹窗中的中文名、用途说明和当前环境支持状态来自平台统一能力注册表，不由 SDK 维护另一份名称映射。开发工具也从同一注册表动态生成 `capabilities.json` 选项，因此后续新增能力无需同步修改这些页面。

```js
await playmesh.ready;

const off = playmesh.app.onDevice(
  playmesh.app.DeviceType.accelerometer,
  30,
  ({ x, y, z, timestamp, unit }) => {
    updateTilt({ x, y, z, timestamp, unit });
  },
);

off();
```

`playmesh.app.device.onDevice` 是同一方法的别名。`fps` 必须是 `1` 至 `120` 的整数。加速度计单位为 `m/s^2`（包含重力），陀螺仪单位为 `rad/s`；`timestamp` 为毫秒时间戳。

同一种传感器只保持一条原生采集流，原生采样频率取当前监听器的最高 fps；原始事件只更新唯一最新快照，每个监听器再按自己的 fps tick 收到该快照。最后一个监听器取消、页面重载或退出后，App 自动停止采集。

## 会话

### `playmesh.session.getCurrent()`

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

### `playmesh.session.onStateChange(callback)`

订阅会话快照。若 SDK 已就绪，注册时立即回调当前值，之后在成员或会话状态变化时再次回调。

### `playmesh.session.isAuthority()`

当前页面属于 Authority Client 时返回 `true`。只有 Authority 页面可以注册权威服务。

### 玩家连接事件

```js
const offJoin = playmesh.session.onPlayerJoin(({ player, session, isCurrentPlayer }) => {});
const offLeave = playmesh.session.onPlayerLeave(({ player, session, isCurrentPlayer }) => {});
const offReconnect = playmesh.session.onPlayerReconnect(({ player, session, isCurrentPlayer }) => {});
```

- `onPlayerJoin`：某个玩家 ID 在本局第一次真正建立 WebSocket 时触发。
- `onPlayerLeave`：在线玩家变为离线时触发。玩家仍保留在 `session.players`，其 `connected` 为 `false`，便于游戏保留中途状态。
- `onPlayerReconnect`：曾经在线的同一持久化玩家 ID 建立新连接时触发。

三个事件都返回取消订阅函数。事件对象中的 `player` 是变化后的玩家，`session` 是最新会话快照，`isCurrentPlayer` 表示该事件是否属于当前页面。游戏应使用这些事件暂停玩家操作、保留席位或恢复画面；不要自己把昵称当作重连主键。

### `playmesh.session.start()`

请求把满足开始条件的会话切换为运行状态，返回 Promise。普通游戏可在 Authority 规则确认开始后调用；大屏游戏应由全员准备和 Authority 倒计时触发，不能在公共显示端提供玩家可点击的开始按钮。

### `playmesh.session.finish()`

仅 Authority 可调用。把本局切换为 `stopped` 并自动释放所有已掉线成员；仍在线玩家继续保留，可在下一局再次开始。Core 仅在 `running` 或 `paused` 状态保留 `connected: false` 的掉线玩家；大厅掉线、`finish()`、App 重置或重新开始都会自动清理离线席位，因此游戏不需要自行维护幽灵成员列表。

## 玩家

### `playmesh.player.getCurrent()`

```ts
interface Player {
  id: string;
  nickname: string;
  role: "authority" | "authority_player" | "player";
  connected: boolean;
}
```

返回当前玩家；SDK 尚未就绪或当前是大屏公共 Authority 页面时返回 `null`。

`authority_player` 表示普通多屏 App 主机同时参与为 Player；Authority 资格仍只由 App 创建会话时登记的 `authorityClientId` 与 `playmesh.session.isAuthority()` 决定。`authority` 是单屏多人公共显示端的宿主身份，该页面的 `getCurrent()` 为 `null`；所有加入者均为 `player`，无论加入顺序都不会成为 Authority。

### `playmesh.player.setNickname(nickname)`

仅普通浏览器可用。更新当前玩家昵称、广播新的会话快照并把成功后的昵称写回浏览器本地缓存；玩家 ID 和凭证不会变化。App WebView 调用会 reject。

```js
await playmesh.player.setNickname("新昵称");
```

浏览器版 SDK 会自动悬浮显示“修改昵称”按钮，游戏不需要再制作昵称设置界面。昵称去除首尾空白后长度必须为 1 至 32 个字符。

## 游戏消息

### `playmesh.game.submitAction(action)`

提交一个 JSON 业务动作，返回 Promise。SDK/宿主负责附加可信发送者和会话上下文；游戏不要在动作里信任自报玩家身份。

```js
await playmesh.game.submitAction({ type: "player.ready", ready: true });
```

浏览器和 App 玩家都通过同一语义提交动作。游戏不得直接创建 WebSocket。

### `playmesh.game.onMessage(callback)`

订阅 Authority 已路由的业务消息。

```js
const off = playmesh.game.onMessage((message) => {
  if (message.type === "state.updated") render(message.state);
});
```

### `playmesh.game.onEvent(callback)`

当前 v1 是 `onMessage` 的别名，订阅相同消息流。新代码优先使用 `onMessage`，避免把业务消息误解为单独的事件通道。

## 权威状态同步

多人游戏优先使用 `playmesh.sync`，业务代码只定义初始状态、语义输入和可选 tick 规则。SDK 负责输入限频与合并、Authority tick、完整快照版本与分发。非 Authority 多人页面重载后会自动请求最新快照；Authority 页面重载会重建同步 runtime，需要恢复的权威状态必须先从 `playmesh.storage` 读取，再作为 `initialState` 启动。

```js
if (playmesh.session.isAuthority()) {
  playmesh.sync.startAuthority({
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

await playmesh.sync.submitAction({ type: "score.add" });
await playmesh.sync.submitState("movement", { x: 1, y: 0 }, { rateHz: 20 });
const off = playmesh.sync.observe((snapshot) => render(snapshot.state));
```

`startAuthority` 仅 Authority 可用，`tickRate` 为 1 至 20 的整数，返回控制器：`getState()`、`setState(nextState, publish?)`、`publish(targetPlayerIds?)` 和 `stop()`。`onInput` 收到可信 `senderPlayerId`、当前状态和输入类型；`onTick` 收到 `dt`、`tick`、按玩家和 key 合并后的连续输入、会话与成员。

`submitAction(payload)` 发送一次性语义输入。`submitState(key, value, {rateHz})` 对同一 key 只保留最新值并把发送频率限制到 1 至 20 Hz，适合方向、摇杆等连续输入。`requestSnapshot()` 可显式请求最新完整快照；SDK 在普通多人页面就绪时也会自动请求。

`getSnapshot()` 返回最近快照，`observe(callback)` 注册时会立即回调已有快照。快照包含 `protocolVersion`、`stateType`、`full`、`revision`、`sequence`、`timestamp`、`sourceTick` 和 JSON `state`。当前实现始终发送完整快照；页面应以最新快照为准，不自行拼接不可信增量。

底层 `playmesh.game` 与 `playmesh.authority` 仍保留给需要自定义消息路由的高级游戏，但同一个输入不应同时走两套协议。

## Authority

### `playmesh.authority.onService(handler)`

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
playmesh.authority.onService(async (action, context) => ({
  targetPlayerIds: context.members.map((member) => member.id),
  message: { type: "action.accepted", action },
}));
```

规则、分数、答案和胜负应由处理器维护。Go Core 不解析游戏业务。

## 生命周期

```js
playmesh.lifecycle.onChange((event) => {});
playmesh.lifecycle.onPause((event) => {});
playmesh.lifecycle.onResume((event) => {});
playmesh.lifecycle.onExit((event) => {});
```

`event.state` 可能为 `ready`、`pause`、`resume`、`exit`、`closed` 或 `error`；错误事件可能携带 `event.error`。所有方法返回取消订阅函数。

`onExit` 处理器可以返回 Promise，宿主会有限等待业务清理。关键进度仍应在状态变化时调用 `setData`，不要只依赖退出回调；最终存储落盘由 App 在 WebView 重启、退出或会话关闭时完成。

重新开始会收到旧 WebView 的退出通知，把原 Core 会话重置为大厅并重建页面；会话 ID、联机码、已连接玩家、分享网关和 token 保留。真正退出游戏才销毁会话。

## 存储

### `playmesh.storage.getBucket(bucket)`

Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。

```js
const profile = playmesh.storage.getBucket("profile_v1");

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

key 必须匹配 `^[A-Za-z0-9._-]+$`，长度为 1 至 128。当前 SDK 会用 `JSON.stringify` 检查写入值；不要写入函数、循环引用或依赖对象原型的实例。

当前宿主限制单个值序列化后不超过 256 KiB。修改先进入主机内存缓存，默认在 2 秒后批量写盘；同一 Bucket 累积 20 次脏写时会提前落盘。`setData()` 完成表示宿主已经接收修改，不表示每次调用都单独写盘。游戏没有显式 flush 能力；App 在 WebView 重启、退出或会话关闭前等待最终写入完成。

所有数据最终写入开始游戏的 Authority 主机 `packages/{gameId}/data/{bucket}.json`。浏览器 `localStorage` 只允许 SDK 保存玩家 ID 与昵称偏好，不保存玩家凭证或 Bucket；其他 App 玩家通过会话访问主机存储。

平台不定义 `{userId}` 存储层。需要按用户区分时，由游戏设计 key 或 JSON 结构。

## 性能

### `playmesh.performance.reportFrame(timestamp?)`

报告一帧真实游戏画面已经完成。`timestamp` 必须是有限数字，省略时使用 `performance.now()` 或 `Date.now()`。SDK 按约一秒窗口计算整数 FPS，并把结果上报宿主。

```js
function frame(timestamp) {
  update();
  drawCanvas();
  playmesh.performance.reportFrame(timestamp);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
```

SDK 不启动独立 RAF。Canvas/WebGL 应在实际绘制或提交后调用；没有真实逐帧渲染的游戏无需调用。

### `playmesh.performance.getFps()`

返回最近一次计算出的 FPS；尚未形成统计窗口时返回 `null`。

### `playmesh.performance.onFps(callback)`

订阅 FPS。注册时立即回调当前值，之后在产生新统计值时回调。返回取消订阅函数。

### 自动联机延迟

多人会话就绪后，SDK 每 3 秒自动执行一次经过 Core 和 Authority 在线状态确认的往返探测。单机游戏不探测、不显示延迟。最近的平滑 RTT 由以下接口读取：

```js
const latencyMs = playmesh.performance.getLatency();
const diagnostics = playmesh.performance.getLatencyDiagnostics();
const off = playmesh.performance.onLatency((value) => console.log(value));
```

`getLatency()` 在尚无有效样本或 Authority 不在线时返回 `null`。诊断对象包含客户端发送/接收时间、Core 接收/发送时间、Authority 可用状态和原始 RTT，供开发诊断使用；游戏规则不得依赖延迟数值决定胜负。

FPS 与联机延迟由 SDK 在网页内创建同一个隔离悬浮层。App 工具坞只调用显示开关，不再原生重复绘制；普通浏览器由 SDK 创建与 App 游戏工具区对应的可收纳功能区，提供刷新、性能开关、进入/退出全屏、游戏信息、浏览器日志指引和昵称设置，但不模拟 App 导航、退出游戏或分享能力。`setVisible(boolean)` 可供宿主集成使用，普通游戏通常不需要调用。

## 浏览器行为

- `capabilities.json.required` 非空时，浏览器每次加载都由主 SDK 弹出能力确认；不支持项只做标注，不阻止同意后进入。
- 浏览器主游戏页和控制器页都提供可选全屏操作；`playmesh.ready` 和加入对局不依赖全屏成功。
- 普通多人多屏分享加载 `main.json.entries.game`（默认 `app/index.html`），浏览器玩家加入 Session 并建立 WebSocket；只有单屏多人分享才加载 `entries.controller`（默认 `app/controller/index.html`）。
- 单机分享加载 `entries.game`，只使用静态资源和 HTTP 存储，不调用加入接口且不建立 WebSocket；浏览器 Console 只保留在当前浏览器；`session.getCurrent()` 与 `player.getCurrent()` 返回 `null`。
- 自定义嵌套 HTML 入口由网关按入口所在目录设置页面基准 URL，页面内相对 CSS、脚本和图片仍解析到当前游戏的 `/app/...`，不会改变 SDK、会话或存储边界。
- 浏览器入口由主机分享网关注入配置，游戏不能自行拼接地址或 token。
- 分享 URL 和宿主注入配置不携带临时昵称。SDK 首次进入时显示昵称输入层并写入 `localStorage`，后续刷新自动复用昵称。
- 浏览器每次刷新都重新调用加入接口，但复用 `localStorage` 中的玩家 ID 和昵称；短期凭证不持久化。运行中旧连接掉线后，同 ID 重连可由游戏恢复准备状态和临时玩家状态。
- SDK 在普通浏览器页面上提供隔离于游戏样式的可收纳功能区和固定配色二级弹窗；修改昵称后更新 Core 会话和本地昵称偏好。App 扫码加入环境只显示 SDK 性能层，由 App 自己的共用工具区提供返回、刷新、全屏、日志和设置，不重复显示浏览器工具区。
- 旧浏览器连接断开后，其玩家从会话成员集合移除并释放人数名额；短暂的刷新竞态由 SDK 对 `session_full` 做有限重试。
- 刷新继续使用本局分享 token；退出游戏、会话关闭、App/Core 重启后旧 token 失效。
- 关闭分享面板和重新开始不会使 token 失效。
- 浏览器存储、动作与消息语义和 App WebView 保持一致，但浏览器不获得 App 原生硬件能力或用户私有资料。

## 错误处理

命令错误通过 Promise reject 返回：

```js
try {
  await playmesh.game.submitAction({ type: "round.join" });
} catch (error) {
  showError(String(error));
}
```

订阅回调中的异常由游戏自己处理。Authority 处理器抛出的异常会作为生命周期 `error` 事件暴露给 Authority 页面。

Console 日志由运行页面的宿主捕获，不经过 Game SDK 或游戏网关。Playmesh App 的 WebView 只把本设备当前页面的 `console.log/info/warn/error/debug` 写入本机运行日志流；其他 App 或浏览器玩家的日志不会传给 Authority。普通浏览器继续使用自身开发者工具查看本机 Console。App SDK 与 Game SDK 在各自全局对象赋值成功后，分别输出 `Playmesh App SDK 注入成功` 和 `Playmesh Game SDK 注入成功`；完成宿主握手后再输出对应的 `SDK 就绪` 日志，可直接区分“文件已注入”和“Bridge 已就绪”。单机 App 页面由本地 Game SDK Bridge 返回无多人 Session 的 bootstrap，并提供本地存储、性能和生命周期命令。Bridge 请求超过 15 秒会 reject 并产生未处理 Promise 日志，不会永久等待。App 在每次启动或重新开始游戏前清空旧缓存，并在本次运行期间保留最近 500 条本机日志，即使游戏内日志面板没有打开；工作区和游戏内日志层都可一键复制最近日志。缓存不写磁盘，App 生命周期结束后清空。

## AI 开发依据

平台不内置游戏 Demo。AI 必须以 SDK Manifest、Schema、OpenAPI、当前项目类型和当前项目源码为唯一开发依据，不得从其他模式推断页面拓扑或联机逻辑。
