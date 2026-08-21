# Playmesh 4.2.0 局域网对局发现、显式公开与 App SDK 审计

## 文档状态

- 状态：功能开发与自动化验证已完成，待 Android、Windows、macOS、Linux 四个平台
  跨设备实机验收；已随 App `4.2.0+28` 发布，但不得据此把跨设备实机验收标记为完成。iOS 自动发现/发布显式为 `unsupported`，扫码、手工邀请和
  分享链接保留。
- 审计与开发日期：2026-08-18。
- 本次实现已落地：默认不公开、SDK 单向显式公开、分享面板触发公开、LAN/Relay
  分享链接及逐链接 PNG Base64 二维码、App SDK UI 自动菜单触发一次性解绑。
- 依据：`docs/00-context.md`、`docs/01-architecture.md`、
  `docs/06-engineering-standards.md`、`docs/remote-game-relay.md`、
  `docs/platform/sdk-development.md`、`docs/game/sdk-v1.md`、
  `docs/version/NEXT.md` 及当前实现。
- App 仍为 `4.2.0+28`，Game SDK `4.1.0`、App Bridge SDK `3.3.0`、Go Core
  `0.5.0`、Core 协议 `1.3.0` 与 Relay `3.0.0` 均不因本功能升级。

## 审计结论

功能可以复用现有 `GameWebGateway`、邀请入口、`RemoteGamePage`、LAN 回环网关和
Relay 通道实现，不需要新增第二套 WebView、WebSocket、Core 会话或 Relay 协议。

以下四个边界必须固定：

1. “不自动公开”表示默认不申请 UDP multicast publication lease。分享网关是否存在与
   是否出现在附近对局列表是两层状态。
2. `setPublished()` 是无参数、单向、幂等的公开操作。首次成功后，本局运行期间不提供
   SDK 取消公开函数；重复调用直接复用进行中的结果或成功返回。
3. 打开分享面板调用同一公开操作，关闭面板只关闭 UI，不撤销公开。仅 game/session
   结束、页面销毁或进程退出等生命周期清理会停止公告、best-effort 发送 goodbye。
4. 当前网关和发现协议都只处理 IPv4。游戏分享可返回网关实际监听的非回环、非
   unspecified 唯一 IPv4，并显式包含 `169.254/16` link-local；该放宽只属于游戏分享，
   Developer Gateway 等其他地址暴露链仍不得使用 link-local。IPv6 明确不在范围内。

`getShareLinks()` 会把完整 bearer 邀请 URL、本机 LAN/VPN 地址和 Relay 邀请中的凭据交给
游戏 JavaScript。这一行为现已成为新的安全基线，替代“游戏脚本不得读取分享 Token、
URL 或二维码”的旧规则；该能力仅存在于 App Bridge，并由宿主再次校验当前本机
Authority/standalone host，普通浏览器、远程加入页和失效游戏上下文均不能调用。

## 当前实现事实

| 范围 | 已落地事实 | 约束 |
|---|---|---|
| 普通游戏分享 | 首次打开分享面板通过协调器确保通道并调用同一 `setPublished()` | 游戏启动不自动公开 |
| 开发预览 | 可先建立通道以报告运行状态 | 不自动公开 multicast |
| 关闭面板 | 只隐藏 UI | 不取消公开、不撤销 token |
| 完整停止 | `GameShareCoordinator.close()` 统一停止公开并释放全部资源 | 仅生命周期结束调用 |
| 链接来源 | LAN 来自网关首次结果；WAN 来自当前有效 Relay session | 组合为唯一不可变快照 |
| gameId | 邀请 POST 兼容返回 `gameId/gameName` | 所有 SDK 跳转复用统一预检 |
| 加入页 | 手工、扫码、附近列表和 SDK 最终进入 `RemoteGamePage` | 不新增第二条加入通道 |
| UI 配置 | `fallbackUi` 与自动系统菜单触发保持独立 | 禁用自动触发不禁用显式 UI |
| 系统输入 | 默认捕获 Escape/Menu/Back；可调用无参数单向解绑 | 原生返回仍可关闭已显示层 |

当前 standalone runtime 也被现有分享门禁视为本机房主。为保证“打开现有分享面板即
公开”一致，本方案允许 multiplayer Authority 和 standalone host 显式公开；远程加入端
不是房主。单机没有多人容量和成员规则，多个远端可能并发访问同一单机存储，这是已接受
风险。

## 零、复用与抽象硬约束

本功能不得以 SDK 或新页面为名复制现有生产逻辑。共享能力先下沉为单一应用服务、值对象
或协调器，再由不同入口调用；只有存在真实可替换继承关系时才抽象基类，默认使用组合，
避免 UI 父类、SDK 父类等无意义层级。

| 能力 | 唯一生产来源 | 消费方 |
|---|---|---|
| 分享通道创建/销毁 | `GameShareCoordinator` 承接从 `_ensureShare()`、`_stopShare()` 下沉的资源流程 | 分享面板、`setPublished()`、Relay、开发预览 |
| LAN 邀请 URL | 当前 `GameWebGateway.shareLinks()` 生产路径 | 面板、SDK、开发状态上报 |
| WAN 邀请 URL | 当前有效 `RelayHostSession.joinUri` | 面板、SDK |
| 链接类型与二维码 | 共享 `GameShareLinkSnapshot` + `ShareQrCodeEncoder` | 面板渲染、SDK Data URL 序列化 |
| 当前房间公开状态 | `GameShareCoordinator` 的 state/generation/publication lease | SDK、分享面板、生命周期 |
| multicast 平台租约与发现缓存 | App 级 `LanGameDiscoveryService` | 协调器公开租约、加入页全量投影、SDK 当前 gameId 投影 |
| 邀请解析/预检/导航 | `GameJoinCoordinator` + 现有 `RemoteGamePage` | 手工输入、扫码、附近列表、SDK 三种加入入口 |
| 分享面板与退出 | 现有 `playmesh.app.ui.*`/宿主回调 | 系统菜单和游戏自定义 UI |

禁止项：

- SDK feature 直接枚举网卡、拼接邀请 URL、解析/重编码 token 或直接构造 Relay 地址；
- App 加入页和 SDK 各自实现扫描、邀请预检、gameId 判断、WebView 或导航；
- 分享面板与 SDK 分别生成不同参数的二维码；
- 为测试方便另建只服务 SDK 的假生产通道；
- 复制代码后仅靠注释声称“逻辑一致”。

实现以“一个状态所有者、一个生产实现、多个薄适配器”为准。原页面资源编排已提取为
共享服务，并以回归测试证明旧 UI 行为未分叉；`GamePage` 只保留调用协调器的薄适配，
不再持有 `_webGateway`、`_shareLinks`、Relay、share generation 等同义可变状态。

## 一、分享与公开状态

统一 `GameShareCoordinator` 作为当前房间唯一权威写入者，持有两组正交状态：

```text
ShareChannelState
  absent -> starting -> active -> stopping -> absent

持有 Core share grant、GameWebGateway、LAN links、
standalone 临时存储和可选 Relay。

LanPublicationState
  unpublished -> publishing -> published
                 | failure -> unpublished
  unpublished/published -> disposing -> disposed

只持有公开 state、generation 和 `LanGameDiscoveryService` 返回的 publication lease；
`disposing` 只由生命周期清理触发。
```

平台 multicast publication lease 只由 App 级 `LanGameDiscoveryService` 持有。该服务按
`instanceId` 提供幂等 register/release lease，并维护发现缓存，但不复制当前房间的公开
意图或分享生命周期；协调器不直接持有 socket。`published` 仅表示协调器持有仍有效的
publication lease。

`instanceId` 属于整个分享通道身份：首次建立分享通道时生成，重复公开、公开失败重试和
WebView 刷新都复用；只有完整关闭通道或更换 game/session 时清除。状态不变量为：

```text
published => share channel active
relay active/connecting => share channel active
```

完整关闭或重建通道前，必须先使 publication 和 Relay 失效。

触发规则：

| 事件 | 分享通道 | UDP multicast | Relay |
|---|---|---|---|
| 正常游戏启动 | 不自动创建 | unpublished | 不连接 |
| 开发预览启动 | 可按现状创建 | unpublished | 不连接 |
| SDK `setPublished()` | 不存在则创建 | 申请 publication lease | 不自动连接 |
| 打开分享面板 | 不存在则创建 | 调用同一公开操作 | 保持 |
| 关闭分享面板 | 保持 | 保持 | 保持 |
| 面板连接 Relay | 确保存在 | 不改变 | 连接 |
| WebView 文档刷新 | 保持 | 保持 | 保持 |
| game/session 更换或页面销毁 | 完整关闭 | 停止公告并 best-effort goodbye | 关闭 |

游戏运行期间不提供 SDK 取消公开或停止分享入口。页面销毁、会话结束、切换游戏和进程
退出仍必须强制释放 publication lease 并完整回收；这是资源生命周期，不是游戏可调用的
反向 API。

### 部分失败与重试

- 分享通道创建失败：`setPublished()` 失败且不申请 publication lease；
- 分享通道成功、multicast 公开失败：通道和手工链接保留，公开状态仍为 unpublished，
  SDK 返回 `discovery_unavailable`；
- 分享面板遇到 multicast 失败时继续显示可复制/扫码链接，同时显示“附近发现不可用”；
- SDK 直接调用 `setPublished()` 时，公开失败会 reject；
- `openSharePanel()` 复用同一内部转换但捕获该公开错误；只要面板和手工链接成功显示，
  它仍按“面板已打开”resolve，不能把发现失败误报成整个分享面板失败；
- 后续调用只重试 multicast 公开，不重复获取 Core grant 或重建网关；
- 生命周期释放失败只能记录经过脱敏的诊断信息，仍须在 `finally` 中继续完整清理，不能
  因 multicast 失败遗留 Relay、网关或 grant。

这样可以在权限、socket 或接口创建、防火墙导致发现不可用时保留现有手工分享能力，同时不把
“有链接”误报成“附近设备一定能发现”。

### 幂等与竞态

- 已经 published：后续调用立即成功，不重建通道、不重复申请 lease；
- 正在 publishing：后续调用复用同一 Future；
- 首次失败时合并调用收到相同错误，状态回到 unpublished，之后调用可重试；
- 协调 Future 使用等价于 `then(success, failure)` 的继续策略，前一次失败不能 poison
  后续重试；
- 退出开始后设置 closing fence，新请求返回 `game_context_unavailable`；
- closing/dispose 清理拥有终止优先级，不能因任何前序 Future 失败而跳过；
- 旧会话异步结果通过 generation 校验，不能在新游戏上复活；
- Relay 创建也要有 generation/cancellation 校验。

当前 `_ensureShare()` 在 `_shareLoading == true` 时直接返回，并未等待正在进行的创建，
不能直接作为并发保证。提取后由 `GameShareCoordinator` 持有唯一
`_shareStartOperation`；分享面板、`setPublished()`、Relay 和 `getShareLinks()` 必须等待
同一个 Future，任何入口都不能用布尔值提前返回来伪装完成。

### 刷新与开发预览

当前 `_restartGame()` 会 `_stopShare()`，与项目文档“刷新保留会话、网关和 token”不
一致。本次需一并修正：

- 只刷新 Web 文档时保留通道、publication、instanceId、token 和 Relay；
- gameId、Session 或开发资源会话真正变化时完整回收；
- 新游戏不继承上一游戏的 published 意愿；
- 开发预览自动网关不等于自动公开；
- App 后台只承诺系统允许进程运行期间尽力维持。

退出清理必须 best-effort 且不中断：即使 publication 释放、Relay 隧道删除或任一步失败，
也要在 `finally` 中继续关闭 Relay、网关、grant、存储和 Session。进入 disposed 后不再
保持 published；goodbye 只是尽力发送，接收端最迟还会在 4 秒 TTL 后移除记录，不能留下
可用分享通道。

## 二、唯一的自定义 UDP multicast 发现

生产发现链固定为 `LanGameDiscoveryPlatform` 隔离的自定义 IPv4 UDP multicast，不存在
第二实现、DNS-SD/TXT 兼容、旧记录迁移、双栈发现或已知节点单播探测。当前固定常量以
`lib/core/network/lan_game_multicast_protocol.dart` 为唯一事实源：

| 常量 | 固定值 |
|---|---|
| IPv4 multicast group | `239.255.80.77` |
| UDP port | `53584` |
| wire version | `1` |
| 公告周期 | `1s`，最多 `100ms` jitter |
| 接收记录 TTL | `4s`，使用单调时钟 |
| 接口重整周期 | `1s` |
| 单数据报上限 | `1200` UTF-8 bytes |
| 接收缓存上限 | `256` 条平台记录；UI 最多投影 `64` 个实例 |

### Wire v1

公告 JSON 的顶层字段必须精确为：

```json
{
  "magic": "playmesh.lan.game",
  "version": 1,
  "kind": "announcement",
  "instance": "base64url-random-id",
  "revision": 7,
  "gatewayPort": 42317,
  "payload": {
    "gameId": "com.example.game",
    "name": "游戏显示名",
    "inviteToken": "opaque-token",
    "hostNickname": "主机昵称",
    "mode": "multiplayer",
    "playerCount": "2",
    "maxPlayers": "8"
  }
}
```

单机公告使用 `"mode":"solo"`，且 `payload` 必须省略 `playerCount/maxPlayers`；多人公告
必须同时携带这两个十进制字符串。goodbye 顶层字段必须精确为：

```json
{
  "magic": "playmesh.lan.game",
  "version": 1,
  "kind": "goodbye",
  "instance": "base64url-random-id",
  "revision": 7
}
```

约束：

- `magic/version/kind`、顶层键集合、payload 键集合、JSON 类型、UTF-8、长度、端口和数值
  范围都严格校验；未知键、缺键、坏 UTF-8、空包或超过 1200 字节的包静默丢弃；
- `instance` 在同一分享通道内稳定；重复公开、公开失败重试和文档刷新不更换，完整关闭后
  重建；`platformId = instance + NUL + sourceIp`，同一实例的多地址再由服务层合并；
- `revision` 在公告内容变化或公开重试时递增；周期心跳复用同一 revision。旧 revision、
  同 revision 的冲突内容，以及 goodbye 后迟到的同 revision 心跳都不能复活记录；
- gameId 复用现有校验并大小写精确比较；name 只作为纯文本，最多 240 UTF-8 bytes；
  hostNickname 必须非空且不得带首尾空白，最多 32 Unicode code points / 128 UTF-8 bytes；
- 多人 `0 <= playerCount <= maxPlayers <= 32`，与 Go Core Session 上限一致；单机没有人数，
  不伪装为 `1/1`；
- `gatewayPort` 等于当前 `GameWebGateway.port`。邀请 URL 只由接收端用数据报真实 source
  IP、端口与 opaque token 组装；payload 不允许自报 IP、URL、资源路径、Core 端口或
  Relay 地址；
- inviteToken 与当前网关一致，不进日志、磁盘、错误或坏包诊断；
- 未知 goodbye 无操作；已知 goodbye 立即投影 lost，goodbye 丢失时由 4 秒 TTL 收敛；
- 接收缓存按最近活动上限 256 条，驱逐仍在线记录时发 lost；可见列表最多 64 个实例，
  单个坏记录不影响其他记录。

### 多网卡与平台边界

- Android、Windows、macOS、Linux 枚举全部有效的非 loopback IPv4 物理网卡，以及能够
  成功加入组播的虚拟网卡；接收端逐接口 join，发送端逐地址绑定 socket 后发送，不依赖
  默认路由；
- 接口列表每秒重整，动态增删和地址变化按 generation 隔离。某个接口 join/bind/send
  失败只停用该接口；仍有其他可用接口时继续工作，全部失败才报告 unavailable；
- `169.254/16` link-local 被接受，但只用于游戏发现与分享，不得扩大到 Developer Gateway
  或其他网络入口；枚举后还必须通过本机临时 UDP `bind(address, 0)` 门禁，Windows
  Tentative/Disconnected 适配器残留的不可绑定 APIPA 不进入分享链接、发送 socket 或
  接收 membership。可绑定只说明地址仍配置在本机，不代表对端或远端已经可达；
- 地址只能取 `RawDatagramSocket` 收到的数据报 source IP，不信任 payload，不把组播组地址
  或本机猜测地址当作主机地址；
- 当前 Dart `Datagram` 不公开数据报目标地址或入站 interface index。接收 socket 绑定
  `anyIPv4:53584` 并加入组播组后，应用层无法证明一个格式合法的 v1 包确实发往组播地址，
  也无法拒绝恶意局域网节点直接单播投递到固定端口；这不构成生产单播发现或单播探测，
  发送端仍只向固定 multicast group 发送；
- Android 在发现/发布租约期间持有原生 MulticastLock；Windows/macOS/Linux 使用系统 UDP
  socket。iOS 自动发现/发布显式返回 unsupported，不增加 multicast entitlement；扫码、
  手工邀请和分享链接继续可用；
- 固定接收端口使用 `reuseAddress`；`reusePort` 只在支持 App 多实例且系统实现支持该选项的
  macOS 启用，Android、Windows 与 Linux 均为 false；
- AP client isolation、跨 VLAN、路由器禁用组播、本机/企业防火墙、VPN 或虚拟网卡策略、
  睡眠和系统后台限制都可能阻断发现。该链路只承诺同一可达组播域内 best-effort 发现，
  不承诺“所有局域网”或跨网段可达。

UDP multicast 同样可被局域网设备伪造；受 Dart 入站元数据限制，恶意节点还可把合法
wire v1 单播到接收端 `53584`，应用层不能按目标地址过滤。严格 Schema、source IP、
revision 与 TTL 校验只缩小输入面，不证明发布者身份或数据报经由组播到达；gameId 也只
防误入。正式加入继续经过邀请 token、Cookie、受控 Core Upgrade 和 Core Join。

## 三、统一加入链路

当前邀请 URL 不携带可验证的 gameId。为在跳转前限制 SDK 只能加入当前游戏，新增
`GameJoinCoordinator` 和 `GameInvitationInspector`，但复用现有邀请入口：

```text
附近对局 / SDK 发现项 / SDK 链接 / SDK 扫码 / App 手工输入
  -> GameInvitation.parse
  -> GameInvitationInspector.inspect
  -> 可选 expectedGameId 精确比较
  -> RemoteGameLaunch
  -> Navigator push/replace
  -> 现有 RemoteGamePage
  -> 现有 LAN 或 Relay 回环
  -> 现有邀请交换、WebView、App SDK 和 Core Join
```

现有 `POST /playmesh/join` 响应兼容增加：

```json
{
  "entry": "/controller/index.html",
  "gameId": "com.example.game",
  "gameName": "示例游戏"
}
```

原落地页只读取 entry。Relay 检查临时复用现有 Relay Web 回环，完成后关闭；不得新增
SDK 专用网络通道。

导航规则：

- App 加入页不传 expectedGameId，允许所有公开游戏；
- SDK 的发现项、链接和扫码由宿主注入当前 gameId；
- JavaScript 不能传入或覆盖 expectedGameId；
- mismatch 在关闭当前游戏和创建目标 WebView 前返回；
- 验证成功后先回送 Promise 结果，再调度 `Navigator.replace`；
- replace 前执行当前游戏退出通知和存储落盘；
- 自己的 instance/链接返回 `self_invitation`；
- 最终始终进入现有 `RemoteGamePage`。

## 四、App 加入对局页面

`JoinGamePage` 顶部增加附近对局，保留扫码和手工输入：

```text
附近对局
  扫描中 / 无结果 / 权限被拒绝 / 发现失败
  游戏名称
  主机昵称 · 纯 source IP
  多人：当前在线 / 最大人数；单机：单机
  点击整行直接加入

扫码加入
手工输入邀请链接
```

- 页面进入取得发现 lease，公告与房间 presence 自动更新列表，同时保留手动刷新；
- 不按 gameId 过滤；
- 不持久化或跨启动缓存；
- 同一 instance 多地址显示一项；
- 点击后由统一协调器尝试候选并进入现有 RemoteGamePage；发现 lease、instance mapping 与
  短期候选必须保留到邀请预检和候选复查结束，不能因先离开列表而制造
  `discovery_not_found`；
- 游戏名、主机昵称、IP 和人数只以纯文本显示；IP 是数据报 source IP，不带网关端口；
  不加载远端 HTML，也不增加图标字段或端点；
- 多人显示当前在线/最大人数；单机显示“单机”，不得伪装为 `1/1`；
- 单个坏记录不清空其他结果；
- Web 与 iOS 不支持自动发现，扫码（平台可用时）、手工邀请和分享链接入口保留；
- 文案进入现有本地化体系。

## 五、App SDK 契约

### `playmesh.app.lan`

```ts
type PlaymeshAppLanShareLinkType = "lan" | "wan";

interface PlaymeshAppLanShareLink {
  readonly url: string;
  readonly type: PlaymeshAppLanShareLinkType;
  readonly img: `data:image/png;base64,${string}`;
}

interface PlaymeshLanGame {
  readonly instanceId: string;
  readonly gameId: string;
  readonly name: string;
  readonly host: string;
  join(): Promise<void>;
}

interface PlaymeshAppLanApi {
  discoverGames(): Promise<readonly PlaymeshLanGame[]>;
  joinByLink(invitationUrl: string): Promise<void>;
  scanQrAndJoin(): Promise<void>;
  setPublished(): Promise<void>;
  getShareLinks(): Promise<readonly PlaymeshAppLanShareLink[]>;
}

interface PlaymeshAppApi {
  readonly lan: PlaymeshAppLanApi;
}
```

合法返回示例：

```json
[
  {
    "url": "http://192.168.0.6:42317/playmesh/join#inviteToken=...",
    "type": "lan",
    "img": "data:image/png;base64,iVBORw0KGgo..."
  },
  {
    "url": "https://relay.example/j/tunnel-id#inviteToken=...",
    "type": "wan",
    "img": "data:image/png;base64,iVBORw0KGgo..."
  }
]
```

`wan` 只标识 Relay 通道，URL 原样来自 `RelayHostSession.joinUri`，不保证是裸公网 IP
或 HTTP。

### 方法行为

`discoverGames()`：

- 只在原生 App Bridge 可用；
- 不接受 gameId 参数，宿主按当前绑定 gameId 过滤；
- 默认扫描 2 秒，并合并 App 级发现服务的新鲜快照；
- 返回项固定为 `instanceId/gameId/name/host`，不含 URL/token，也不增加 App 列表内部的
  hostNickname/playerCount/maxPlayers/isSolo 或图标字段/端点；join 使用 bridge-scoped
  短期映射；
- 排除当前实例，映射随 WebView/游戏切换失效。

`joinByLink()`、`scanQrAndJoin()`：

- 只在 App 环境可用；
- 要求真实用户操作：网页侧的 `navigator.userActivation` 只负责提前拒绝，宿主 WebView
  还必须在原生 pointer/key 事件发生时签发一个 2 秒内、至多消费一次的内存激活票据；
  JavaScript 上报 `userActivation: true` 不能自行创建票据；
- WebView 导航、文档重置和页面关闭都会清除未消费票据；
- 扫码复用现有 `GameInvitationScannerPage`；
- gameId 由宿主绑定；
- 都进入同一加入协调器并复用现有通道。

`setPublished()`：

- 只在 App 环境且当前 WebView 是本机 Authority/standalone host 时成功；
- 无参数，确保分享通道后申请 UDP multicast publication lease；
- JavaScript `arguments.length` 必须为 0；传入 `true`、`false` 或任何额外参数都以
  `invalid_argument` reject，且不得创建通道或改变公开状态；
- Bridge executor 只接受空 payload，并拒绝 `published` 等旧字段，不能依赖 JavaScript
  默认忽略多余参数的行为；
- 首次成功后本局保持 published；不提供 SDK 取消公开或停止分享函数；
- publishing 时复用同一 Future，published 后重复调用立即成功；
- 平台不支持或 multicast 公开失败时 Promise 以 `discovery_unavailable` 拒绝，但已经成功
  建立的手工分享通道保留，后续调用可以重试；
- 不自动连接 Relay，也不打开面板；
- 按当前要求不增加 user activation，因此游戏可在 `playmesh.app.ready` 后主动调用；
- 打开现有分享面板调用同一公开操作，关闭面板不撤销公开；
- session/page 退出仍强制释放 publication lease。

`getShareLinks()`：

- 只在 App 环境且当前 WebView 是本机房主时成功；
- 无副作用，不创建网关、不公开、不连接 Relay；
- 无分享通道时返回冻结空数组；
- 直接读取 `GameShareCoordinator.currentLinkSnapshot()`，SDK feature 不接触网卡解析器、
  `GameWebGateway`、`RelayHostSession`、token 或二维码编码器；
- 等待调用前已经开始的共享快照转换，不等待 Relay 热连接从 connecting 变为 connected；
- LAN 数据只来自生产分享流程在网关建立时调用一次 `GameWebGateway.shareLinks()` 得到并
  缓存的结果，WAN 数据只来自当前有效 `RelayHostSession.joinUri`；SDK 不重新
  枚举、重新拼接或解析；
- Relay 建立/断开时由协调器向同一快照加入/移除唯一 `joinUri`。`getShareLinks()` 本身
  不触发网卡刷新；若网络变化需要刷新链接，只能修改协调器的唯一生产刷新流程，并同时
  原子更新面板、开发状态上报和 SDK 所读快照；
- 未公开但通道存在时仍返回链接；
- LAN 在前、WAN 在后，按完整 URL 去重；
- 当前只返回可监听 IPv4，不返回 127.0.0.1 fallback；
- WAN 在 Relay tunnel 创建成功并存在未关闭的 `RelayHostSession` 时进入共享快照；
  `connecting`/`retrying` 是热连接状态，不另造 URL，`disconnected`/关闭时从快照移除；
- 每个快照项已经携带共享编码器生成的 PNG；面板渲染同一 PNG bytes，SDK 只将其序列化
  为 Data URL，不得再次生成二维码；
- 快照服务在生成完成时再次校验 generation；期间若 token、通道、Relay 或页面状态
  变化，返回 `operation_cancelled`，不得回送旧快照；
- 返回数组和项目冻结。

内部命令：

```text
app.lan.discover
app.lan.joinDiscovered
app.lan.joinByLink
app.lan.scanQr
app.lan.setPublished
app.lan.getShareLinks
```

gameId、Authority、网关和 Relay 全部来自宿主上下文，不信任 JavaScript 上报。
`userActivation` 也不信任 JavaScript 上报；所有受手势保护的命令共享宿主原生的一次性
激活票据校验。

稳定错误：

| code | 含义 |
|---|---|
| `app_unavailable` | 无 App Bridge |
| `app_not_ready` | 仅 ready 后方法被提前调用 |
| `invalid_argument` | 无参方法收到参数或 Bridge 收到未知字段 |
| `game_context_unavailable` | 无当前游戏或正在退出 |
| `not_authority` | 不是本机房主 |
| `user_activation_required` | 加入/扫码无用户操作 |
| `discovery_unavailable` | 自动发现/发布不支持、权限拒绝、无可用接口或 multicast 失败 |
| `discovery_not_found` | 短期发现实例已丢失 |
| `invalid_invitation` | 非法邀请 |
| `game_mismatch` | 目标 gameId 不同 |
| `self_invitation` | 当前主机自己的邀请 |
| `scanner_unavailable` | 平台无扫码实现 |
| `cancelled` | 用户取消 |
| `share_unavailable` | 无法建立或读取分享 |
| `share_links_too_large` | 链接/总负载超限 |
| `qr_generation_failed` | PNG 生成失败 |
| `operation_cancelled` | 退出取消操作 |

## 六、链接与二维码规范

“全部地址”是网关当前实际监听、非 loopback/unspecified、去重后的 IPv4，游戏分享显式
包含 `169.254/16` link-local，
使用动态端口和完整 fragment，并按 `sortLanEndpointCandidates()` 排序。候选地址不承诺
防火墙、AP 隔离、VPN 或路由下可达。

IPv4 过滤只由 `GameWebGateway.shareLinks()` 这一唯一生产路径消费：resolver
已与只绑定 `anyIPv4` 的网关保持一致，仅枚举 `InternetAddressType.IPv4`；无可用
网卡时也不再生成 `127.0.0.1` fallback。没有可分享 IPv4 时，生产快照的 LAN 项为空，
面板、开发上报和 SDK 必须一致，禁止只在 SDK 返回前二次过滤。link-local 的放宽必须由
游戏网关显式请求，Developer Gateway 和其他 resolver 消费者保持默认排除。multicast
公告不消费 LAN URL，只使用网关端口、token 和游戏元数据；协调器发现 LAN 快照为空时
不申请 publication lease 并让
`setPublished()` 返回 `discovery_unavailable`，但已经建立的本地分享通道仍按统一清理
规则保留。

```text
LAN:
http://<ipv4>:<port>/playmesh/join#inviteToken=<secret>

WAN:
https://<relay-host>/j/<tunnelId>#inviteToken=<secret>
```

每个 LAN/WAN 项都包含 img：

- QR 内容为 url 的精确 UTF-8；
- PNG Data URL，固定 `data:image/png;base64,`；
- 自动 version、纠错 M、黑色模块、白底、无 Logo；
- 四 module quiet zone，每 module 4 个整数像素；
- 边长 `(moduleCount + 8) * 4`，version 40 时 740 像素；
- 扫码必须逐字还原 url。

负载边界：

- 单 URL 最多 2048 UTF-8 字节；
- 最多 32 个 LAN 加 1 个 WAN；
- 单个 PNG Data URL 最多 128 KiB；
- 整个 Bridge JSON 最多 4 MiB；
- 超限整体失败，不静默截断，也不返回缺 img 的部分结果；
- 顺序或小并发生成，禁止无界 `Future.wait`；
- PNG 仅按精确 URL 做内存缓存，网卡/token/Relay/session 变化即清空；
- URL、token、PNG 不进日志、分析、磁盘、崩溃详情或错误文本。

仓库已有 `qr_flutter` 和 `qr`；现有面板的链接/二维码展示数据已提取为不可变
`GameShareLinkSnapshot`，并建立唯一
`ShareQrCodeEncoder`：使用 `QrCode`/`QrPainter.toImageData(...png)` 绘制白底和 quiet
zone。协调器对每个精确 URL 只生成一份 PNG bytes；现有面板改为渲染该 bytes，SDK 只做
Base64 Data URL 序列化。不得截图 Widget、另写二维码协议或让两个消费者重复编码。

## 七、App SDK UI 系统菜单触发解绑

新增独立的单向方法，不复用 `fallbackUi`。无参数方法若仍命名为
`setSystemMenuTriggersEnabled()` 会错误暗示“调用后启用”，因此公开名称固定为：

```ts
interface PlaymeshAppUiApi {
  disableSystemMenuTriggers(): void;
}
```

```js
await playmesh.app.ready;
playmesh.app.ui.disableSystemMenuTriggers();

customMenuButton.onclick = () => playmesh.app.ui.showGameSidebar();
shareButton.onclick = () => playmesh.app.ui.openSharePanel();
exitButton.onclick = () => playmesh.app.ui.exitGame();
```

精确语义：

- 每个新 WebView 文档默认安装系统菜单自动触发绑定；
- 只能在 `playmesh.app.ready` resolve 后调用；
- ready 前同步抛出 `app_not_ready`，不排队、不支持早期全局配置；
- 调用严格无参数，立即解绑当前文档的自动触发监听；任何额外参数同步抛出
  `invalid_argument` 且不解绑，重复的零参数调用无操作；
- 旧名称 `setSystemMenuTriggersEnabled` 不存在，也不保留兼容别名；
- 这是当前文档内的单向操作，不提供重新启用函数；刷新或启动新游戏会按默认值重新绑定；
- 调用时不自动关闭已经打开的平台层，只影响后续自动触发；
- 解绑后，菜单关闭状态不再捕获或消费 Escape、F10、ContextMenu、Menu、
  BrowserBack、GoBack、XF86Back、GameButtonB/电视返回和兼容 keyCode 来打开菜单；
- 解绑后，无平台层打开的原生 `handleNativeBack()` 返回未处理，宿主随后按既有导航规则
  处理该返回；
- 显式函数打开的菜单、信息、日志或分享层仍可消费 Escape/返回关闭自身；
- `showGameSidebar()`、`openSharePanel()`、`openRuntimeLogs()`、`openGameInfo()`、
  `exitGame()` 和 `playmesh.app.lan.*` 不受影响；
- `fallbackUi` 保持 true；普通浏览器 floatingButton 仍由原选项单独控制；
- 按产品决定，不增加防困定时器、强制恢复或平台拦截。

实现上保存全局输入监听器的 disposer，调用时真实解除当前文档监听，而不只是让回调提前
返回。原生返回继续复用既有 `appInternalRuntime.handleNativeBack()`；在没有显式平台层
需要处理时返回 `false`。该能力是纯 App SDK UI 状态，不新增 Bridge 命令。

## 八、新安全基线与已接受后果

当前 `docs/platform/sdk-development.md`、`docs/game/sdk-v1.md` 和
`docs/下一步方案.md` 中“游戏不能读取分享 Token、URL、二维码”的规则，按已确认产品决策，
自本文起对 App SDK 房主分享能力废止；功能与对应契约已实现，相关文档已同步修订。
后续不能同时恢复两套相互冲突的规范。

新的正式安全基线为：

- `getShareLinks()` 仅存在于 Playmesh App Bridge，并且只允许宿主确认的当前本机
  Authority/standalone host 调用；
- API 有意向游戏返回完整 LAN/Relay 邀请 URL 及其 PNG Data URL，不做 token 脱敏；
- 房主游戏复制、展示或通过自身网络能力发送这些邀请信息，是该 API 被授权的产品行为；
- `setPublished()` 与 `getShareLinks()` 不新增 capability 声明、用户确认或 user
  activation；
- gameId、Authority、分享通道和 Relay 状态全部取自宿主绑定上下文，不接受 JavaScript
  自报；
- `discoverGames()` 仍只返回当前 gameId 的无 token 投影，加入动作仍要求真实用户操作；
- URL、token、PNG 不得由平台 SDK 自动写入日志、分析、磁盘、崩溃详情或跨会话缓存；
- game/session/page 退出时清除平台持有的内存快照，并继续执行完整生命周期清理。

需要明确接受的事实后果是：LAN fragment 本身是 bearer invitation；Relay inviteToken
包含加入能力、Authority shareToken 和端到端共享密钥；二维码只是同一 URL 的编码，并非
脱敏。任何取得本机房主权限的游戏都可以读取并外传邀请凭据及本机 LAN/VPN/虚拟网卡
地址。这个能力边界是本方案的新设计，不再以旧安全基线作为阻断条件。

## 九、代码落点

新增：

```text
lib/core/network/lan_game_advertisement.dart
lib/core/network/lan_game_discovery_service.dart
lib/core/network/lan_game_discovery_platform.dart
lib/core/network/lan_game_discovery_platform_io.dart
lib/core/network/lan_game_discovery_platform_stub.dart
lib/core/network/lan_game_multicast_protocol.dart
lib/core/network/lan_game_presence.dart
lib/core/game_web/game_share_coordinator.dart
lib/core/game_web/game_share_link_snapshot.dart
lib/core/game_web/game_join_coordinator.dart
lib/core/game_web/game_invitation_inspector.dart
lib/core/game_web/share_qr_code_encoder.dart
lib/core/game_sdk/features/app/app_lan_feature.dart
```

修改：

```text
lib/core/game_sdk/sdk_feature_registry.dart
lib/core/game_sdk/app_webview_bridge.dart
lib/core/game_sdk/features/app/app_ui_feature.dart
lib/core/game_sdk/features/app/app_device_feature.dart
lib/core/game_web/game_web_gateway_contract.dart
lib/core/game_web/game_web_gateway_io.dart
lib/core/network/lan_endpoint_resolver.dart
lib/core/network/lan_endpoint_resolver_io.dart
lib/core/relay/relay_tunnel_contract.dart
lib/features/game/game_page.dart
lib/features/game/game_launcher.dart
lib/features/game/local_game_web_view.dart
lib/features/game/remote_game_page.dart
lib/features/game/join_game_page.dart
lib/app.dart
assets/playmesh-localization/locales/{locale}/app.json
android/app/src/main/AndroidManifest.xml
android/app/src/main/java/top/zfjmm/playmesh/LanMulticastLockHost.java
android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java
```

`GameShareCoordinator` 是当前房间唯一分享应用服务和权威状态写入者；现有
`GamePage._ensureShare()`、`_stopShare()` 的资源编排下沉后，UI、SDK、开发预览和 Relay
只保留薄适配，不各自维护状态。App 根状态持有单个 `LanGameDiscoveryService`，它拥有
平台 publication leases/socket 生命周期与发现缓存，但不拥有当前房间的公开意图。

新 App LAN TypeScript、声明和 Dart 执行器放在同一 feature。当前
`SdkSourceFragment` 已增加 feature 自有 declaration fragment，并用 interface
merging 物理拼入 `playmesh-main.d.ts`；`playmesh-app.d.ts` 保持 reference-only，
通过引用继承同一声明，避免 named type alias 在引用链中重复定义。不能手改
`assets/playmesh-library/sdk-src` 或 `public/sdk/v1` 生成物。

## 十、平台与测试

平台：

- Android 声明网络/组播权限，发现或发布租约存续时通过原生宿主持有 MulticastLock；
- Windows、macOS、Linux 使用逐接口/逐地址 UDP socket，验证防火墙、物理网卡、支持组播
  的虚拟网卡、接口动态增删与部分接口失败隔离；
- iOS 自动发现/发布使用明确 unsupported guard，不新增 multicast entitlement；删除并禁止
  恢复旧服务发现声明，本地网络 usage description 继续服务于手工邀请加入等既有链路；
- Web 使用 stub，自动发现和 App-only 方法返回明确错误；扫码/手工邀请等独立入口按各自
  平台能力保留；
- 本期不新增移动后台常驻服务。

平台验收只能证明被测设备、网卡与网络环境。AP 隔离、VLAN、禁用组播、企业防火墙、
VPN/虚拟网卡策略、睡眠与后台限制都可能导致双方无法互见，产品和错误文案不得声称覆盖
“所有局域网”。

自动化测试与来源契约持续覆盖：

- 默认未公开、开发预览不自动申请 lease、面板开/关、无参重复公开幂等；
- `setPublished(true/false)` 和任意多余参数均拒绝且绝不公开，executor 拒绝旧
  `published` payload；
- 本局没有 SDK 取消公开命令，game/session/page 退出按顺序释放 lease、发送 goodbye 并
  完整清理；
- 刷新保留、game/session 更换清理；
- wire exact keys/type/range/UTF-8/1200-byte 严格解析，announcement/goodbye、1 秒心跳、
  4 秒单调 TTL、revision 顺序、同 revision 冲突、goodbye tombstone、未知 goodbye、
  256 条 LRU 驱逐与坏包隔离；
- source IP 唯一取自数据报、同实例多地址合并、自实例排除、SDK gameId 过滤；
- App 页面全量列表与 found/update/lost，主机昵称、纯 source IP、多人当前/最大人数与单机
  投影，自动更新、手动刷新，以及点击预检完成前保留 lease/短期候选；
- LAN/Relay Inspector、mismatch/self、先回包后 replace；
- App-only、Authority/standalone/remote 门禁；
- Android/Windows/macOS/Linux 全部有效非 loopback IPv4 物理网卡和可成功加入组播的虚拟
  网卡，逐接口 join、逐地址发送、动态重整、部分失败隔离；IPv6/loopback 不参与；
- `169.254/16` link-local 可用于游戏发现/分享，但 Developer Gateway 等默认 resolver
  仍排除；
- iOS 平台自动发现/发布稳定 unsupported，扫码、手工邀请和分享链接回归不受影响；Web
  stub/非 App Bridge 返回对应 unavailable 错误；
- Relay tunnel 创建成功后由共享快照返回唯一 `joinUri`，关闭/disconnected 后移除；
- 每项 PNG Data URL、M 纠错、quiet zone、扫码精确还原及负载上限；
- 面板、开发上报和 SDK 读取同一 `GameShareLinkSnapshot`，URL 与 PNG bytes 完全一致；
- 同一 generation 内打开面板后连续调用 `getShareLinks()`，网卡解析保持一次、每个精确
  URL 的二维码编码保持一次，所有调用复用同一 `_shareStartOperation`；
- spy 断言每次 SDK `getShareLinks()` 对网卡 resolver、`GameWebGateway.shareLinks()`、
  Relay `joinUri` getter 和 `ShareQrCodeEncoder` 的新增调用次数均为 0；
- 来源门禁禁止 `app_lan_feature` 枚举网卡、拼邀请 URL、读取 Relay 或生成二维码；
- SDK JS/.d.ts/Bridge 投影保持 `instanceId/gameId/name/host`，不得加入内部显示元数据或
  图标字段/端点；
- 所有加入入口复用同一邀请预检和 `RemoteGamePage`，不存在 SDK 专用导航/通道；
- URL/token/PNG 不进日志和磁盘；
- UI 默认绑定、ready 门禁、无参解绑、重复调用和刷新恢复；
- UI 多余参数不解绑，旧 `setSystemMenuTriggersEnabled` 名称和 boolean 签名不存在；
- 解绑后不捕获按键，显式打开仍工作，显式层仍能关闭；
- SDK JS/.d.ts/manifest/Schema/补全/命令注册一致。

建议命令：

```text
dart format <本次 Dart 文件>
flutter analyze lib test
flutter test
node tool/generate_sdk.mjs
node tool/test_game_sdk.mjs
node tool/test_game_sdk_browser.mjs
node tool/test_app_bridge_sdk.mjs
node tool/test_sdk_declarations.mjs
node tool/test_app_platform_ui_sdk.mjs
git diff --check
```

2026-08-18 记录的全仓分析、测试和 Android 调试构建结果早于本次发现链改为 UDP
multicast，不能作为新协议的平台验收凭据。协议切换后的最终自动化结果须以本次任务的
实际命令输出补记；无论自动化是否通过，都不能外推为四个平台跨设备实机验收。

待完成的跨平台实机验收：

1. 启动后附近列表不可见，打开分享面板后出现，关闭面板后仍存在；退出后 goodbye 或
   最迟 4 秒 TTL 移除。
2. SDK 首次 `setPublished()` 后出现，重复调用不重复申请 lease；本局无取消公开 API。
3. 不同 gameId 主机都出现在 App 页面；列表显示主机昵称、纯 source IP、多人当前/最大
   人数或“单机”，随 presence 更新并支持手动刷新；游戏 SDK 仍只看当前 gameId 的旧投影。
4. SDK 发现项、链接和扫码只进入同 gameId，并复用 RemoteGamePage。
5. `getShareLinks()` 与当前分享面板显示同一组 IPv4/有效 Relay URL 和二维码，每项
   `img` 可扫码逐字还原 `url`。
6. 调用 `disableSystemMenuTriggers()` 后 Esc/Menu/Back 不自动开菜单，显式函数仍工作；
   重复调用无操作，刷新后恢复默认绑定。
7. Android、Windows、macOS、Linux 分别验证发布、发现、更新/丢失、权限、物理与可组播
   虚拟网卡动态增删、部分接口失败、link-local 和实际加入；该项尚未执行，不能由单元
   测试或平台声明检查替代。
8. iOS 验证自动发现/发布稳定 unsupported，同时扫码、手工邀请和分享链接保持可用。
9. 点击附近项后，即使页面准备导航也要保留 lease 与候选直到预检和候选复查结束。
10. 在 AP 隔离、VLAN、防火墙或禁用组播环境中验证明确失败/空态，不宣称全 LAN 可达。

本轮未执行发布构建与四个受支持平台的跨设备实机验收；iOS 自动发现/发布不在支持矩阵。
平台声明和自动化测试通过不能据此宣称平台验收完成。

## 十一、版本、文档与回滚

- 当前正式 App 为 `4.2.0+28`；
- Game SDK `4.1.0`、App Bridge SDK `3.3.0` 已随本版发行，不再次升号；
- 新增 LAN discovery wire v1；
- 不修改 Go Core `0.5.0`、Core 协议 `1.3.0` 或 Relay `3.0.0`；
- `/playmesh/join` 只加兼容响应字段。

本次同步更新上下文、架构、路线、工程规范、Relay、Game/App SDK 文档、
`docs/version/NEXT.md`、App 简略更新日志、全部 locale、SDK 契约/Schema/补全/生成物。
“游戏不能读取分享 URL/二维码”的旧结论已由本文件的新 App-only Authority 安全边界
替代，后续文档不得恢复相互冲突的禁读规则。

回滚时先停止并移除 UDP multicast publication/discovery，再移除 SDK 新入口和发现 UI，
并原子回滚对应契约与安全文档。
现有手工链接、扫码、RemoteGamePage、LAN 回环、Relay 和 Core 协议不分叉，可原样
保留。不得只隐藏列表却继续后台发布。

## 十二、已实现基线

当前实现固定以下边界：

1. 默认不申请 LAN 公开 lease；开发预览有网关也不自动公开。
2. `playmesh.app.lan.setPublished()` 无参数且单向；重复调用幂等，本局不提供 SDK
   取消公开或停止分享函数，任何多余参数均拒绝且无副作用。
3. 打开分享面板调用同一公开操作，关闭不取消；只有生命周期结束停止公告并释放 lease。
4. “全部 IP”当前只含真正监听的非 loopback/unspecified IPv4，可包含只用于游戏分享的
   link-local；IPv6 本期不支持。
5. multiplayer Authority 与 standalone host 都可显式公开，并接受单机并发风险。
6. App 页面显示全部 gameId、主机昵称、纯 source IP、多人当前/最大人数或“单机”，支持
   自动更新和手动刷新；点击预检完成前保留 lease。SDK 发现、链接和扫码只允许当前
   gameId，公开投影不扩展内部显示字段或图标端点。
7. `getShareLinks()` 返回完整 bearer URL 和逐链接 PNG Data URL，包括当前有效 Relay；
   这被确立为替代旧禁读规则的新安全基线，不增加 `network.share` 授权、确认或 user
   activation。
8. `getShareLinks()`、分享面板和开发上报复用同一生产快照、链接生成与二维码编码，不得
   重新枚举、拼接、解析或实现平行逻辑。
9. UI 方法固定为无参数 `disableSystemMenuTriggers()`：默认已绑定、仅 ready 后可调用、
   当前文档单向解绑、重复调用无操作、额外参数拒绝、刷新恢复默认；旧 boolean 方法名
   不存在。
10. 平台不为关闭自动菜单触发增加防困判断。
11. 发现唯一使用 `239.255.80.77:53584` 的自定义 IPv4 UDP multicast wire v1；1 秒公告、
    4 秒 TTL、单包最多 1200 字节，不保留 DNS-SD/TXT、双栈或已知节点单播兼容。
12. Android、Windows、macOS、Linux 覆盖全部有效物理 IPv4 网卡和可组播虚拟网卡，真实
    主机 IP 只取数据报 source；iOS 自动发现/发布显式 unsupported，手工通道保留。
13. 组播发现是同一可达组播域内的 best-effort 能力，不承诺穿透 AP 隔离、VLAN、防火墙、
    VPN 策略或系统后台限制。
14. 整项实现遵守 `docs/06-engineering-standards.md` 的“单一生产实现与薄适配器（强制）”；
    出现重复业务实现或同义状态所有者即不通过评审。

任一项调整都应先修订本文，再修改实现。
