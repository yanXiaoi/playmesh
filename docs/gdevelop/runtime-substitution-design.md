# GDevelop 运行时后端替换设计

## 状态与范围

本文定义 Playmesh 预览和发布流程对 GDevelop 运行时的后端替换边界。固定上游始终以
`webide-lock.json` 为准，本文不复制当前版本、commit 或摘要。

本文只定义目标边界和宿主合同，不记录当前实现状态。后续新增能力仍不得在未经独立审计时
扩展 App、Game SDK 或 Go Core 的公共接口；当前入口只在[源码接线索引](integration-wiring.md)
中维护。

本文服从 [GDevelop 开发总规范](development-standards.md)。这里的“替换”只指精确外部
backend/I/O seam：Playmesh 可以实现该 seam 所需的网络或宿主传输，但官方状态机开始后的
对象、事件、回调、结果和错误仍归官方实现。本文所列固定错误码只适用于 Playmesh 私有 façade
自身的连接、超时和协议失败，不得覆盖已经进入官方逻辑后产生的错误。

## 已冻结的全局原则

1. 运行时替换只能位于真正的 backend/I/O seam。不得重写 GDevelop 的公开事件工具、
   session state、消息管理、变量管理、对象行为、登录状态机或存储语义。
2. GDevelop 没有正式 backend interface 时，只能对固定上游源码中的精确外部调用点做
   最小补丁，引入 Playmesh 私有 allowlisted compatibility façade。禁止手写复刻整份上层
   文件，也禁止在脚本加载后 monkey-patch `gdjs` 公共函数。
3. Multiplayer、身份和 locale façade 只能通过不可枚举的私有 `Symbol` 协作；不得全局替换
   `fetch`、`WebSocket`、`localStorage` 或 `Peer`。Storage 是经单独审批的唯一例外：锁定的
   `storagetools` seam 只调用公开且精确类型化的
   `playmesh.app.storage.getBucket(...).getDataSync/setDataSync`，不增加 GDevelop 私有入口。
   同样禁止全局改写 `ApiConfigs`、批量替换官方 host 或把官方端点统一指向无效域名；需要禁用
   的在线服务必须在其精确 service 调用点显式失败关闭。
4. 通用 Browser HTML5 导出完全保留官方 backend。只有 Playmesh 预览和“发布到
   Playmesh”生成的完整 file map 可以经过替换注册表。
5. 每个替换项必须同时校验精确文件路径、固定上游 SHA-256、入口 HTML 中的精确脚本引用
   和唯一性。任一条件不符时失败关闭，不得退回官方网络、PeerJS 或浏览器存储。
6. 升级时先校验固定上游，再机械重放 seam 补丁并重新构建。不能直接修改临时 checkout，
   所有步骤必须进入 source policy、overlay、生成脚本和测试。
7. 除明确批准的 backend seam 外，补丁前后的上游源码 AST 必须等价。GDevelop 工程可见的
   API、事件格式、返回类型和对象行为必须保持官方格式；Playmesh 私有 lobby/backend 适配器
   可以按本文件冻结的产品合同改变大厅展示和外部 I/O 映射，但不得把这些变化扩散到项目数据、
   App/Game SDK 公共接口或普通官方导出。

## 通用异步替换注册表

替换目标一律使用以导出 Web 根目录为基准的**逻辑路径**：入口是 `index.html`，运行时文件是
`Extensions/...`、`events-tools/storagetools.js` 等 GDevelop 根相对路径。注册项、source policy、
升级 guard 和诊断信息都只能出现这种逻辑路径。

逻辑 Web 路径不等于 Playmesh package file map 的内部物理 key。现有
`PlaymeshGamePackageLayout.packagePathForWebPath(rootPath)` 可以把逻辑 `rootPath` 定位到当前
package 中的物理条目；物理前缀是 package layout 的实现细节，不是第二套 Web 根布局。注册表
必须通过这一唯一 layout abstraction 读写条目，不能自行拼接或剥离前缀，也不能把内部物理
key 暴露为注册项输入。

因此，本设计不要求迁移全局 package producer 或改变 ZIP 的物理目录。若以后确实要改变物理
ZIP 布局，应作为独立的 package-format 迁移审批，不应夹带在运行时后端替换中。

建议的内部形态如下；名称仅用于说明职责，最终实现应遵循现有模块命名：

```text
complete Playmesh file map + canonical package layout
  -> async runtime substitution registry (logical web-root targets only)
       -> resolve logical target to one physical entry through layout helper
       -> exact path + upstream SHA + index reference guard
       -> selected private backend replacement
       -> replacement SHA + provenance record
  -> preview response / Playmesh publish upload
```

每个注册项至少包含：

- 规范化目标路径；
- 固定上游源码或构建产物 SHA-256；
- 根入口 `index.html` 中预期的脚本 `src`；
- 异步读取、哈希和替换函数；
- 替换产物 SHA-256；
- 适用条件，例如 storage 总是适用、multiplayer 只在项目启用多人时适用；
- 失败代码和可本地化诊断键。

目标路径必须写成逻辑 Web 根相对路径。当前固定版本至少包括
`events-tools/storagetools.js`、`Extensions/Multiplayer/peerJsHelper.js`、
`Extensions/Multiplayer/multiplayertools.js`、
`Extensions/PlayerAuthentication/playerauthenticationtools.js`。注册表将目标交给 canonical
layout helper 定位物理条目，不接受调用方传入内部 package key，也不维护第二套前缀兼容逻辑。

注册表必须复制输入映射后再替换，不能修改调用方持有的映射。文本和 `Blob` 都按实际字节做
SHA-256；不能把每个运行时文件的 digest 塞进 `game.json` 或 `main.json`。替换契约属于
Playmesh source policy 的内部清单。

## 私有 façade 的安全边界

不可枚举 `Symbol` 只用于避免污染 GDevelop 公共 API 和降低误用，不是安全隔离。游戏脚本和
同一 JavaScript realm 中的依赖仍可能发现或调用它，因此每个私有方法都必须是用途封闭的
compatibility façade，并由 App/SDK 在**每次调用**时重新执行权限和 schema 校验。

统一要求如下：

- façade 在创建时捕获当前 game/session/player scope，调用方不能传入或切换这些身份；
- 只接受锁定上游明确需要的 operation enum、DTO、控制帧、identity key 和 Peer/DataConnection
  子集；额外字段、未知枚举、越界长度、错误状态转换都失败关闭；
- 不提供任意 URL、method、header、credential token、request body、fetch、raw socket、WebRTC、
  Binary channel 或 Go Core connection；官方身份状态要求的 `userToken` 只能是不可用于宿主
  鉴权的不透明 compatibility handle；
- 所有来自 façade 的 UI 路由由 SDK 内部配置到官方已创建的 frame，不把内部 URL 返回给游戏；
- GDevelop close/leave 只映射到 GDevelop backend 的 soft leave/soft close。退出真实 Playmesh
  Session 仍由 App 容器控制；
- 错误只返回固定、本地化可映射的 compatibility error code，不回显 credential、内部地址或
  transport 细节。

建议只挂载一个不可枚举、冻结的私有注册表，例如
`Symbol.for('playmesh.runtime.backends.v1')`。patched runtime 只能用固定 engine/feature/version
协商具体 façade：

```ts
type PlaymeshRuntimeCompatibilityRegistryV1 = {
  negotiate(request: {
    engine: 'gdevelop';
    engineVersion: string; // 必须精确等于 webide-lock.json 的当前上游版本
    feature: 'storage' | 'multiplayer' | 'playerAuthentication' | 'locale';
    minVersion: number;
    maxVersion: number;
  }): Readonly<ApprovedFeatureFacade>;
};
```

各 feature 只接受当前锁定 engine 与当前私有 façade 版本，不为旧 patched runtime 保留兼容
分支。协商缺失、engine 版本不符或 façade 版本无交集时确定性失败关闭。注册表不提供按名称
任意取对象、动态方法调用或 raw transport escape hatch；宿主对返回 façade 的每次调用仍执行
前述校验。

## Storage：只替换 `getItem`/`setItem` 两个 seam

固定上游：

| 文件 | SHA-256 |
| --- | --- |
| `GDJS/Runtime/events-tools/storagetools.ts` | `52e9739dcce8ea4909107ce1c940cad948975062496a9089e6bde3e88c178d88` |
| 构建产物 `events-tools/storagetools.js` | `76cf02415edea1d5a2c3434508c44c4aa9ebe5dee82d71322ef60132f5b137e9` |

source policy 另锁定官方 TS 的 Git Blob SHA-1
`d61394d79c78e787f488ae63e4185ffff5c9dee3`；上游文件发生任意变化时先停止升级并重新审计，
不能按模糊文本继续替换。

官方实现只有两个底层持久化调用：读取时调用
`localStorage.getItem('GDJS_' + name)`，卸载文件时调用
`localStorage.setItem('GDJS_' + name, serializedString)`。其余九个事件工具、
`loadedObjects`、Load/Unload、路径和类型判断、exists/delete/clear 行为全部是官方上层语义，
不得修改。

补丁不建立 GDevelop 私有 façade、启动快照、预热 gate、driver map 或浏览器内持久化副本。
它在每次官方 load/unload 真正触及底层 I/O 时惰性判断公开 SDK：

1. `window.playmesh` 不存在：逐字保留官方 `localStorage` 分支与 `GDJS_` 前缀，通用官方
   Browser HTML5 导出行为不变。
2. `window.playmesh` 存在且 App 同步能力完整：使用
   `playmesh.app.storage.getBucket('GDJS/' + name)`。读取固定保留 key
   `$playmesh.gdevelop.root.v1`，不存在时得到 `null`；写入直接提交官方内存中的完整
   `jsObject` root，而不是序列化字符串。App WebView 写当前设备的 App Bucket；普通浏览器
   由同一 App SDK 方法写当前源 `localStorage`。
3. `window.playmesh` 存在但 `app/storage/getBucket` 或任一同步方法缺失：抛出明确的
   App Bridge SDK 3.3.0 不兼容错误，绝不 fallback 到官方 `GDJS_` key、空 root、Main Bucket
   或旧 WS 存储。

能力不能在模块加载时缓存；App SDK 的同步方法在原生 App 中只接受 bootstrap 下发并由 SDK
立即移除的随机 loopback capability endpoint，未完成 `playmesh.app.ready` 时明确失败；普通
浏览器直接使用 App SDK 的当前源本地实现。GDevelop 补丁不扫描或 hydrate 全部 Bucket。官方 `loadedObjects`、
Load/Unload、路径、类型、exists/delete/clear 与临时 load 后自动 unload 的语义保持原样；
只有实际走到 Unload 才调用同步写入。同步错误在 Playmesh 分支中失败关闭，不被官方
localStorage 的 catch 吞掉。

存档所有权固定为“当前设备 + 当前游戏”，与玩家昵称、Authority、Session 和加入来源无关；
改名、房主迁移或同名玩家不会切换或共享 App Bucket。原始 GDevelop storage file 名不归一化，
作为 `GDJS/<name>` 逻辑 Bucket 名；App 本地存储层使用
`logical/sha256-{digest}.json` envelope 保存并校验原名。单 Bucket 完整 JSON root 上限为
10 MiB。原生同步 JSON 通过随机 loopback capability endpoint 和 requestId 重放保护访问当前
`AppLocalBucketStore`；同步 XHR 响应丢失只以完全相同请求立即重试一次。它不使用 Main Bucket
的 Authority HTTP 路由、revision/CAS 或 binary upload。

`apply-source-policy.mjs` 是该 TS seam 的唯一修改入口，输出清单记录 preimage Git Blob 和
post-patch SHA-256。测试必须覆盖无 Playmesh 的官方 fallback、App 本地逻辑 Bucket、普通浏览器
App Bucket、同步方法缺失和伪造/残缺 SDK，并断言不存在 GDevelop 私有 `Symbol.for`，且
Playmesh 分支不读取 `playmesh.main.storage` 或 fallback 到官方 `GDJS_` key。

## Multiplayer：保留官方项目 API 与对象同步，适配 Playmesh lobby/backend

### 边界澄清：不向项目暴露底层网络

下文出现的 Peer、HTTP、WebSocket、identity 和 endpoint 名词，只描述锁定版 GDevelop **原源码
正在调用的形状**，不是 Playmesh 向 GDevelop 工程或项目脚本开放的能力。最终边界必须满足：

- 不在 `window`、`gdjs`、公开 Game SDK、`.d.ts`、事件表或扩展 API 上挂载任何新对象；
- engine-local adapter 可以在闭包内短暂合成官方上层期望的 `Response`、socket event 或
  DataConnection 形状，但它们不是浏览器/PeerJS 原对象，也不能被项目取得；
- 私有 registry 只返回下文用途封闭的 façade。即使同 realm 的恶意脚本发现私有 `Symbol`，
  也只能提交固定 operation/frame，并会被 compatibility bridge/宿主逐调用校验，无法取得任意
  网络能力；
- 底层 Playmesh Session、Binary relay、Authority 和 Go Core 连接由 canonical GDevelop
  bridge/bootstrap 通过现有 SDK 能力协调，绝不作为 handle 返回；App/Game SDK 不增加
  GDevelop 专用业务或公共接口；
- endpoint 若实现时需要标识，只能是 canonical adapter 内部封闭枚举（例如 lobby UI/auth UI），
  由兼容层解析并直接配置官方 frame；不能接收、解析或返回任意 URL。

### 固定源与“不改”清单

| 文件 | 固定源 SHA-256 | 处理方式 |
| --- | --- | --- |
| `Extensions/Multiplayer/peerJsHelper.ts` | `2d782d5e921d7bada70cc1446639358e1b15ab02373c466b3d2c745742e8b5ae` | 只把唯一 Peer 构造表达式替换为 allowlisted façade |
| `Extensions/Multiplayer/multiplayertools.ts` | `701da9ec2888bfa6c49dde11b99d2fc5a33851949972127e1bd922c63bd6107b` | 只把精确 HTTP/socket 调用和 iframe 消息调用点替换为 allowlisted façade |
| `Extensions/Multiplayer/multiplayercomponents.ts` | `3933eb58e8cf1d13445bce6af9ff65ef23d11294c7272059772a720e96f24d00` | 只把官方 lobby iframe 的唯一 `src` 赋值交给本地 frame 配置 façade |
| `Extensions/PlayerAuthentication/playerauthenticationtools.ts` | `9a9d5409135bfc78599354ab28ba6033f6f8c8cf6c706e0da6895f0d2e4e74d5` | 只替换身份持久化、注册检查、认证 transport 和 iframe 消息调用 |
| `Extensions/PlayerAuthentication/playerauthenticationcomponents.ts` | `2d316cdbf4a715621d770a176691d75ef2d630a3a2daff81945e66366c916c31` | 只把官方认证 iframe 的唯一 `src` 赋值交给本地 frame 配置 façade |
| `Extensions/Multiplayer/peer.js` | `832acdb544512d14f9fddb3fd8bc7208337fe2c76ab25014b40dc040f7a44f1d` | 可原样保留；patched helper 不再构造它 |
| `Extensions/Multiplayer/messageManager.ts` | `9833e4e86445fe680360f19ca10444fa0dfa23f558dcc4974806be7dc0966970` | 原样保留 |
| `Extensions/Multiplayer/multiplayerVariablesManager.ts` | `18753455818941415db1b4da5a5f6fafc76f9e2f189aa0ceda227a2507e296f3` | 原样保留 |
| `Extensions/Multiplayer/multiplayerobjectruntimebehavior.ts` | `aba35503c276d1a038e77fdc50197e3c7226db2a2f5a1fe901315a3353ee6819` | 原样保留 |

`messageManager` 的网络边界只调用 `gdjs.multiplayerPeerJsHelper`；它本身没有 fetch、
WebSocket 或 Peer 构造。变量管理和对象行为也没有外部 I/O。因此这三层不能成为替换点。

### Peer transport seam

`peerJsHelper.ts` 唯一创建外部传输的调用是 `new Peer(peerConfig)`。最小补丁只把这一表达式
改为私有 allowlisted compatibility façade；压缩、解压、消息队列、连接映射、just-connected/
just-disconnected、ready、重连判定和公开函数全部保留。

GDevelop 一侧只要求 façade 返回该固定版本官方代码实际使用的 Peer/DataConnection 合同。它
不是通用 PeerJS、WebRTC 或 Playmesh Binary 能力，不接收 `peerConfig`、服务器 URL、token，
也不返回 raw socket、RTC connection、Binary channel 或 Go Core connection：

```ts
type GDevelopPeerCompatibilityFacadeV1 = {
  createOfficialPeer(): OfficialPeerLike;
};

type OfficialPeerLike = {
  id: string;
  on(event: 'open' | 'error' | 'connection' | 'close' | 'disconnected',
     handler: Function): void;
  connect(officialPeerId: string): OfficialDataConnectionLike;
  reconnect(): void;
};

type OfficialDataConnectionLike = {
  peer: string;
  peerConnection?: Readonly<{ connectionState?: string }>;
  on(event: 'open' | 'data' | 'error' | 'close' | 'iceStateChanged',
     handler: Function): void;
  send(data: object): void;
  close(): void;
};
```

`peerConnection` 只是为满足锁定上游读取 `connectionState` 而合成的只读形状，绝不是实际
`RTCPeerConnection`。

宿主逐次校验 `connect/send/close` 的类型、大小、成员和当前 session；`close()` 只映射为
GDevelop soft leave，不关闭 Playmesh App 会话。该对象可以由 Playmesh Binary relay channel
实现，但不能把 `sendDataTo`、
`getAllMessagesMap`、`getAllPeers` 或 `connect` 改写为 Playmesh 版本。官方 `peer.js` 可以继续
随包加载而不被使用；如将来决定替换为 no-op，必须先证明 patched helper 和同一入口中的其他
脚本都不存在运行时 `Peer` 引用。

### Lobby/cloud/service-discovery seam

锁定版 Multiplayer 官方源码的外部调用点只有以下三类；前两类位于
`multiplayertools.ts`，iframe `src` 赋值位于 `multiplayercomponents.ts`：

1. HTTP I/O：`fetchAsPlayer` 内的一处 `fetch`，以及游戏注册检查的一处 `fetch`；
2. lobby socket I/O：创建一条 `WebSocket`，后续继续由官方代码绑定
   `onopen/onmessage/onclose` 并调用 `send/close`；
3. 大厅 iframe：官方代码继续创建容器、iframe、message listener 和调用 `postMessage`；
   component seam 只把该 iframe 配置成 `sandbox="allow-scripts"`、无网络的本地 `srcdoc`，tools
   seam 只收发版本化消息。每个 frame 使用 256-bit capability nonce、严格递增 sequence 和精确
   `WindowProxy` 绑定；消息必须逐字段白名单化，不能返回 URL、凭据或替换官方状态函数。

源码 seam 内可以用一个仅本文件可见的 adapter 合成上层所需的 `Response`/`WebSocket` 形状，
但私有 Symbol 边界不得暴露通用 fetch、URL resolver 或 raw socket。最小宿主契约是按固定
operation 和固定 schema 白名单化的 compatibility façade：

```ts
type LobbyOperationV1 =
  | 'checkGameRegistration'
  | 'quickJoin'
  | 'getLobbyById'
  | 'heartbeat'
  | 'endGame'
  | 'migrateHost';

type LobbyRequestByOperationV1 = {
  checkGameRegistration: ExactCheckGameRegistrationRequestV1;
  quickJoin: ExactQuickJoinRequestV1;
  getLobbyById: ExactGetLobbyByIdRequestV1;
  heartbeat: ExactHeartbeatRequestV1;
  endGame: ExactEndGameRequestV1;
  migrateHost: ExactMigrateHostRequestV1;
};

type LobbyResponseByOperationV1 = {
  checkGameRegistration: ExactCheckGameRegistrationResponseV1;
  quickJoin: ExactQuickJoinResponseV1;
  getLobbyById: ExactGetLobbyByIdResponseV1;
  heartbeat: ExactHeartbeatResponseV1;
  endGame: ExactEndGameResponseV1;
  migrateHost: ExactMigrateHostResponseV1;
};

type GDevelopLobbyCompatibilityFacadeV1 = {
  request<K extends LobbyOperationV1>(
    operation: K,
    payload: LobbyRequestByOperationV1[K]
  ): Promise<LobbyResponseByOperationV1[K]>;
  createOfficialLobbyControlFacade(): OfficialLobbyControlFacadeV1;
  configureOfficialLobbyFrame(frame: HTMLIFrameElement): void;
  createOfficialPeer(): OfficialPeerLike;
};

type OfficialLobbyControlFacadeV1 = {
  onopen: (() => void) | null;
  onmessage: ((event: { data: string }) => void) | null;
  onclose: (() => void) | null;
  send(frame: OfficialOutboundLobbyFrameV1): void;
  close(): void;
};
```

每个 `Exact*V1` 和 response 类型都必须在 source policy 中固化为锁定上游实际使用的字段、
类型、长度和枚举；缺字段、额外字段、未知 operation 或越界内容由 App 在每次调用时拒绝。
源码内局部 adapter 负责把 allowlisted response 合成为官方代码读取的 `status`、`statusText`、
`ok` 和异步 `text()`，不能让上层改为 Playmesh-specific DTO。

`OfficialLobbyControlFacadeV1` 只是当前锁定官方状态机使用的控制帧门面。它不接收 URL、header、
token 或 arbitrary string；即使 TypeScript 编译后收到字符串，宿主也必须解析并按以下
action/type 的精确 schema 再校验，才映射到 Playmesh SDK。它不暴露底层 WebSocket、Binary
channel 或 Go Core connection；`close()` 映射为 GDevelop soft leave，而非退出 App Session。

官方 outbound socket action：

- `heartbeat`；
- `getConnectionId`；
- `sessionInformation`；
- `startGameCountdown`（只保留当前官方调用面，兼容层实现为无副作用 no-op）；
- `startGame`；
- `joinGame`；
- `updateConnection`；
- `sendPeerId`。

官方 inbound socket type：

- `connectionId`；
- `lobbyUpdated`；
- `gameStarted`；
- `peerId`。

allowlisted request façade 需要覆盖官方当前使用的注册检查、quick join、按 lobby ID 查询、
heartbeat、结束游戏和 host migration 请求。对 Playmesh 运行时，一个 Playmesh Session 精确映射为
一个虚拟 GDevelop lobby：lobby 状态自动进入该 lobby，running 状态自动进入 game；同一
frame/session 的 `sessionInformation` 最多触发一次自动加入。这里没有第二套房间创建、房间码或
人工 Join 流程。

Authority 加入后直接显示并执行 Start；guest 的 Start 请求必须被拒绝。产品合同没有倒计时：
不得生成倒计时按钮、pending operation、`gameCountdownStarted` 事件或 Binary packet。官方
`startGameCountdown` action 仍可被当前官方状态机调用，但 compatibility façade 只做同步、无副作用
no-op；旧 type 5 倒计时帧必须忽略或拒绝，不能恢复旧协议。Start/join、`playerNumber`、
`hostPeerId`、lobby 状态和软离开继续适配为官方代码可消费的形状。

`connectionId` 消息中的 `positionInLobby` 是官方稳定玩家编号的唯一赋值来源。canonical
bridge/bootstrap 应在自动注入的 GDevelop 私有 Authority 服务命名空间中维护
`playerId -> playerNumber`，并由虚拟 lobby socket 原样送入官方状态机；不能为此修改
Go Core 的通用会话协议。官方 `leaveGameLobby` 仍执行本地 lobby/game 清理，底层 channel
采用软离开，Playmesh Session 是否真正退出继续由 App 容器控制。

同一 Session 的 roster 或稳定编号快照变化时，bridge 必须重新投影官方 lobby 玩家列表并刷新
头像；不能只依赖首次 lobby 消息。后加入玩家获得稳定 `playerNumber` 后，Authority 与 guest
看到的成员、昵称和头像应收敛到同一快照。软离开、warm re-entry 和 reset 复用当前 Session 与
Binary Channel，但不得重放旧成员展示或旧倒计时状态。

### Player Authentication seam

Multiplayer 通过官方 `gdjs.playerAuthentication.getUserId/getUserToken/getUsername` 读取身份。
这些 getter 和 `_username/_userId/_userToken` 状态不能覆盖。最低 seam 是：

- `window.localStorage.getItem/setItem/removeItem` 三个身份持久化调用改为私有 identity
  compatibility façade；
- 游戏注册检查的一处 `fetch` 改为 allowlisted operation request；
- Electron/Cordova 登录的一处 `new WebSocket` 改为固定认证帧门面；
- 官方登录页由 façade 配置为同样无网络、带独立 capability 的本地 `srcdoc` frame，官方
  window/iframe、message listener、`login()` 和通知流程不变；认证结果只回父 realm，frame 不
  获得 Playmesh token 或 Session 凭据。

私有 Symbol 不提供 fetch-like、WebSocket-like 或 URL resolver。建议的 GDevelop 侧最小形状：

```ts
type GDevelopPlayerAuthCompatibilityFacadeV1 = {
  readOfficialIdentity(key: OfficialIdentityStorageKeyV1): string | null;
  writeOfficialIdentity(
    key: OfficialIdentityStorageKeyV1,
    value: ExactOfficialIdentityRecordV1
  ): void;
  removeOfficialIdentity(key: OfficialIdentityStorageKeyV1): void;
  checkGameRegistration(
    payload: ExactCheckGameRegistrationRequestV1
  ): Promise<ExactCheckGameRegistrationResponseV1>;
  createOfficialAuthenticationControlFacade(): OfficialAuthenticationControlFacadeV1;
  configureOfficialAuthenticationFrame(frame: HTMLIFrameElement): void;
};

type OfficialAuthenticationControlFacadeV1 = {
  onopen: (() => void) | null;
  onmessage: ((event: { data: string }) => void) | null;
  onclose: (() => void) | null;
  send(frame: OfficialAuthenticationOutboundFrameV1): void;
  close(): void;
};
```

`OfficialIdentityStorageKeyV1`、identity record 和认证帧必须是 source policy 从锁定上游提取的
封闭枚举/精确 schema。宿主逐调用检查当前 game/session、字段、长度和状态转换；未知 key、
operation、frame 或额外字段全部拒绝。认证 channel 不接收 URL、token、header 或任意消息，
也不暴露 raw socket/connection；`close()` 同样只执行该 GDevelop 流程的 soft close。

Playmesh 身份由宿主预载到 identity façade，使官方第一次 getter 触发的读取得到
`{username,userId,userToken}`。`userToken` 只能是 GDevelop 私有 backend 可识别的不透明值，
它不是 App token、Session 原始凭据或 Go Core credential，也不能被任何宿主 API 用于鉴权。
显式 logout 仍清理官方内存状态；重新进入游戏时由宿主按当前 Playmesh 身份重新预载。

### 宿主合同

Playmesh 私有 backend 必须提供：

1. 当前 game/session/player 的同步身份快照；如果官方同步入口早于 SDK ready，则全部异步 façade
   共用一次有界 negotiation，官方同步 control socket 使用最多 16 帧的 deferred virtual socket，
   ready 拒绝、ready 超时、coordinator attach/context 超时、无 Session 和 dispose 均以固定错误码
   失败关闭；bridge 自身不会主动 attach、订阅 SDK 或触碰 Channel/Go Core；
2. canonical GDevelop bridge/bootstrap 通过现有 Game SDK session/binary 能力创建或加入一条
   GDevelop 专用 Binary relay channel，并把成员变化适配成 engine-local connection 事件；该能力
   不返回 channel/connection handle，也不修改 App/Game SDK；
3. 私有 Authority 服务负责 channel 发现和稳定玩家编号，不占用游戏默认 Authority
   namespace；
4. 从现有 Session 状态合成官方 lobby REST/WS DTO 和 action/type 顺序；
5. 在浏览器分享、本地 Windows WebView 和 Android WebView 提供一致的本地 lobby/auth
   页面地址；
6. backend 缺失、ready/attach 超时或协议版本不匹配时失败关闭并显示可本地化诊断，不访问
   GDevelop 官方服务。

这些能力的 GDevelop 业务编排只存在于 canonical bridge/bootstrap，并复用现有
`playmesh.main.session`、`playmesh.main.binary` 与 Gateway 路由；未扩大游戏公共 SDK。后续若出现
新缺口，先在 GDevelop 私有兼容层解决；只有共享宿主问题有独立非 GDevelop 复现时，才允许修改
共享宿主，而且仍不能把底层连接或通用网络能力暴露给游戏。

## 验证矩阵

### Source policy 与等价性

- 从锁定 commit 获取固定源，逐个校验本文列出的 SHA-256；
- 升级重放脚本只能修改审批清单内的 AST 节点；匹配 0 次或多次都失败；
- 对 patched 源执行 AST 归一化：把 façade 调用还原成原表达式后必须与上游 AST 相同；
- `messageManager`、variables manager、object behavior 和保留的 `peer.js` 必须与上游
  SHA 完全一致；
- patched helper 的构建产物不得再出现可执行的 `new Peer`；
- patched multiplayer/player-auth 产物不得在批准 seam 外直接调用官方 fetch、WebSocket、
  localStorage 或官方外部 endpoint。
- source policy 和最终产物不得出现用于批量禁用服务的全局 `ApiConfigs`/host 重写；每项在线
  服务替换都必须能映射到一个经审计的精确 seam；
- patched component/tools 必须把 lobby/auth iframe 限制为无网络 `srcdoc`，并覆盖错误
  `WindowProxy`、nonce、sequence、额外字段、token 泄漏与认证结果回流 frame 的负向用例。

### File-map 边界

- 通用 HTML5 导出得到官方字节；
- Playmesh 预览和发布得到相同 replacement SHA；
- 预览与发布传入替换注册表的 target identifier 必须是逻辑根相对 `index.html`、
  `Extensions/...`、`events-tools/...`；注册表通过
  `PlaymeshGamePackageLayout.packagePathForWebPath` 精确找到现有 physical file-map entry；
- 测试必须证明 source policy/registry 从不接受内部 physical key，并证明 canonical layout helper
  能解析当前 package map；不得为新旧前缀各写一套 fallback，也不得在注册表内 heuristic
  add/strip 前缀；
- 未启用多人时不替换 multiplayer/player-auth，Storage 按既定策略替换；
- 文件缺失、重复 script、路径大小写变化、SHA 不符和入口引用不符都失败关闭；
- Blob、文本和非 ASCII 内容按实际字节哈希。

### 官方语义回归

- Storage 九个事件工具和 Load/Unload 时序；
- Peer ready/connect/data/error/close/disconnected、压缩和消息顺序；
- 唯一 Session/lobby 自动加入、Authority direct start、guest 拒绝、中途加入、host migration、
  end、软离开；
- 稳定 playerNumber、username/userId、just-started/just-ended 单帧标志；
- messageManager 的对象/变量所有权、保存更新和断线恢复；
- façade 拒绝、瞬断、重连、重复成员事件和缺失 backend 的失败路径；
- façade 自身的传输错误使用本文固定诊断；进入官方状态机后的失败保留官方错误类型、消息和
  返回结构，不被 Playmesh 统一错误覆盖；
- 早于 `playmesh.main.ready` 的并发 async/sync 官方调用共享有界 negotiation，ready reject/timeout、
  attach timeout、无 Session、dispose 和 deferred 队列溢出均有确定失败；inactive 路径零 SDK/
  Channel/Go Core 副作用；
- 后加入玩家的稳定编号、昵称与头像刷新；`startGameCountdown` 只做无副作用 no-op，并证明
  不存在倒计时按钮、pending operation、事件、Binary packet 或旧 type 5 接受路径；
- soft leave、warm re-entry、同 Session reset 与稳定编号 epoch rollover；
- Windows 本地、Android 本地和普通浏览器分享三种宿主路径。

## 升级与回滚

升级 GDevelop 时按 `core-upgrade-guide.md` 获取新固定 commit。先运行 SHA/AST guard；若任一
seam 不再唯一匹配，升级立即停止，重新审计官方外部调用点后才可修改补丁脚本。不得通过放宽
正则、跳过 SHA 或保留上一版手写上层实现来让构建通过。

回滚只需要禁用对应 replacement 注册项并恢复上一份已验证的 Playmesh WebIDE 产物；通用
官方导出始终未被改动。若新版私有 backend 与旧产物协议不一致，必须按版本整体回滚，不能让
新 SDK 驱动旧 patched runtime。
