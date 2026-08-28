# 远程游戏 WebRTC / TURN 传输

本文描述 Relay 协议 `4.0.0`。该版本是不兼容更新：旧的 raw TCP Upgrade、应用层
AES-GCM 字节中转和每条 TCP 连接各建一条公共 Relay 连接已经删除，3.x 邀请不能由
4.x 客户端继续使用。

## 目标与边界

- 创建、加入、扫码和分享入口保持原有用户流程与 URL 外形。
- 一个加入用户只建立一个 Pion `PeerConnection`。
- 加入端每接受一个本地 TCP 连接，就创建一条独立、可靠、有序的 DataChannel。
- `target=web` 转发游戏 HTML、JavaScript、图片和 WebSocket；`target=core` 转发
  Session HTTP、文本 WebSocket 和 Binary WebSocket。
- Go Server 只负责鉴权、在线租约、临时凭据 TTL、限流、信令转发以及 Pion STUN/TURN，
  不读取业务流。
- Authority Go Core 为通用 HTML WebRTC 信令提供局域网 STUN/TURN；监听地址直接复用
  Flutter 已有的可绑定 IPv4 网卡遍历结果，不在 Go 中另做一套网卡选择。
- TURN 是无法直连时的唯一公共数据兜底，不再保留第二套 TCP Relay。
- 传输失败不做 TCP 回退，也不跨 PeerConnection 静默迁移；当前 PC 和本地连接关闭，
  用户回到现有加入入口重新进入。

## 结构

```text
加入端 WebView
  ├─ 本地 Web 网关 ─┐
  └─ 本地 Core 网关 ├─ 一个 Pion PeerConnection ── Authority Go Core
                    │    ├─ DataChannel(web, connection A)
                    │    ├─ DataChannel(web, connection B)
                    │    └─ DataChannel(core, connection C)
                    └─ ICE: host / srflx / relay(TURN UDP 或 TCP)

Go Server
  ├─ Relay 4.0 WebSocket：只中转 SDP、trickle ICE 与关闭信号
  ├─ Host 在线租约、短期 peer 凭据与人数/IP/消息限流
  └─ Pion TURN：UDP/TCP 3478，短期 TURN REST 凭据

Authority Go Core（通用 HTML WebRTC）
  └─ 各可绑定 LAN IPv4 上的 Pion STUN/TURN：动态 UDP/TCP 监听、玩家隔离凭据
```

Authority Go Core 为每个加入用户维护独立的 `PeerConnection`，因此一个房间可同时服务
多个用户；单个用户的 Web/Core 请求复用该用户的 PC，但不复用全局 DataChannel。
DataChannel 的独立可靠有序流避免把所有 HTTP 和 WebSocket 串进一个全局队列。

## 控制面

Flutter App 和 Runtime 不直接承载 Pion。它们只调用本机 Go Core 的回环控制 API：

- `POST /v1/relay/host`：Authority 建立公共 WebRTC 会话。
- `GET /v1/relay/host/{id}`：读取连接状态、人数和每个 peer 的模式。
- `DELETE /v1/relay/host/{id}`：显式关闭 Authority 会话。
- `POST /v1/relay/client`：加入端以邀请 URL 建立一个 PC，并取得 Web/Core 回环地址。
- `GET /v1/relay/client/{id}`：读取加入端状态。
- `DELETE /v1/relay/client/{id}`：关闭 PC、两个监听器及所有 DataChannel。

加入隧道不提供 ICE restart 或自动换路控制端点。PeerConnection 失败即关闭本次加入；玩家
返回既有加入界面后，自行选择局域网或公网邀请重新建立一条新通道。通用 HTML 信令 API
仍只提供不透明信令转发，游戏若在自己的业务 PeerConnection 中实现 ICE restart，属于游戏
自身行为，不会复活平台加入隧道。

平台隧道关闭会同步关闭现有 web/core DataChannel 与本机 socket；游戏主 Session 连接因此
断开，并继续通过既有 `playmesh.main.lifecycle.onChange()` 收到 `event.state` 为 `closed`
或 `error` 的回调。SDK 与 Dart 会话客户端可以继续重试原来的本机 Session/Binary 端点，
但平台不会借此弹出界面、导航、切换路线或创建新 PeerConnection，因此 Pion 隧道关闭后
这些重试不会自动恢复跨设备连接。

### 加入准备与连接移交

扫码、手工链接、App SDK 与 Runtime SDK 的链接/扫码加入都先进入同一个
`GameJoinCoordinator.prepareLink()`。该步骤不是 Authority 鉴权，但必须解析邀请、拒绝
自邀请和 `expectedGameId` 不匹配，并通过受控邀请端点取得和校验 `entry/gameId/gameName`。
这些结果是远程 App Bridge 隔离、当前游戏 SDK 上下文和本地 Bucket 命名所必需，不能通过
直接跳过网络准备来提速。

Relay 准备调用一次 `POST /v1/relay/client` 后，使用该会话的 Web 回环校验邀请。成功结果把
同一个 Relay client session 和受控 `entry` 校验结果以单次所有权移交给 App/Runtime 游戏
页；游戏页不再关闭会话后再次 `POST /v1/relay/client`。Dart 预检收到的 HttpOnly Cookie
不能进入 WebView Cookie 仓库，所以 WebView 必须在已移交会话的同一 Web 回环上加载原邀请
入口、再次 POST token，并由浏览器响应 Cookie 后重定向到受控入口。准备失败、取消、gameId
不匹配、导航失败和页面/Runtime 退出都必须由当前所有者关闭会话。连接对象不进入公开 SDK、
Bridge 返回值、日志或游戏 JavaScript。

LAN 仍单独建立本机 Web/Core tunnel，并同样让 WebView 从原邀请入口建立自己的 Cookie；
不得用 Dart 预检返回的 `entry` 绕过这一步。二维码识别只负责返回原始字符串；App 两个扫码入口在结果返回后的
第一帧先显示不可操作、不可返回的“正在加入”遮罩，再开始上述准备。手工输入在点击加入时
已经进入同一视觉状态，不增加扫码专用等待层。

每个请求都必须带：

```text
X-Playmesh-Control-Version: 1.0.0
X-Playmesh-Request-ID: <1..128 位关联 ID>
X-Playmesh-Timestamp: <Unix 毫秒>
```

成功 JSON 为 `playmesh.webrtc-tunnel.snapshot`，包含 `protocolVersion`、`timestamp`、
同一 `requestId` 和业务字段。控制 API 只监听回环地址，并继续执行 Origin 与输入限制。

## Go Server Relay 4.0 信令

Relay 声明固定为：

```json
{
  "protocolVersion": "4.0.0",
  "transport": "playmesh-webrtc-datachannel",
  "publicBaseUrl": "https://relay.example",
  "hostPath": "/relay/v1/host",
  "clientPath": "/relay/v1/client",
  "maxConnectionsPerTunnel": 64
}
```

创建、删除和 WebSocket 握手必须携带 `X-Playmesh-Relay-Version: 4.0.0`、
`X-Playmesh-Request-ID` 与 `X-Playmesh-Timestamp`。Authority 另带来源 Bearer token 和
`X-Playmesh-Host-Lease`；加入端带 `X-Playmesh-Join-Capability`。

服务端签发的 `playmesh.relay.credentials` 包含房间 ID、Host lease、Join capability、
首次附着/初始 ICE 凭据到期时间及短期 ICE servers。主机信令连接附着后，房间不再由该时间
硬过期；服务端每次加入都为该 peer 重新签发一组临时 ICE servers，并在 `peer.joined` 与
`connected` 的 payload 中分别交给主机和加入端。信令 WebSocket 只接受以下帧：

```json
{
  "type": "description | candidate | peer.error | close",
  "protocolVersion": "4.0.0",
  "timestamp": 1787587200000,
  "requestId": "signal-id",
  "peerId": "服务端认证的 peer ID（仅 Host 路由时使用）",
  "payload": {}
}
```

`peer.error` 只允许 Host 发往对应的已认证 peer，用于保留 Authority 建立
`PeerConnection`、offer 或 candidate 失败的原始原因；Client 不能伪造该帧发往 Host。
服务端生成 `connected`、`peer.joined`、`peer.left` 和关闭信号。它不会解析
SDP/Candidate payload 的业务含义；消息大小、速率、房间人数、IP 并发和临时凭据 TTL
仍受限。主机与客户端信令连接使用心跳识别无 FIN/RST 的失联连接。

## 邀请和 DataChannel 首帧

公共邀请仍是 `https://server/j/{room}#inviteToken=...`。片段内承载
`playmesh.relay.invitation`、协议 `4.0.0`、签发/历史凭据时间、client path、Join capability、
Authority 入口、分享 token 与 32 字节流证明密钥。URL fragment 不会随 HTTP 请求发给
Go Server。`expiresAt` 为 4.0.0 wire 兼容字段，不再决定二维码/链接寿命；客户端必须以
服务端是否仍接受当前 tunnel capability 为准。主机信令持续在线时原邀请持续有效，主机
断开、主动停止分享或服务端关闭时，原二维码和原链接一起失效，重新分享会生成新邀请。

每条业务 DataChannel 打开后先发送长度前缀 JSON：

```json
{
  "type": "playmesh.relay.stream",
  "protocolVersion": "1.0.0",
  "timestamp": 1787587200000,
  "connectionId": "随机且在当前 peer 内唯一",
  "target": "web | core",
  "routeEpoch": 123,
  "proof": "HMAC-SHA256"
}
```

Authority 校验时间窗、目标、HMAC、同一 peer 固定的 `routeEpoch`、连接 ID 重放和并发上限，
再连接固定回环目标。远端不能提交任意主机/端口。

## ICE 与 TURN

### Authority 局域网 ICE

主 App 与 Runtime 在启动 Go Core 时，直接复用
`resolveBindableLanIpv4InterfaceAddresses(includeLinkLocal: false)` 的结果，并分别通过移动端
绑定参数或 Windows `-local-turn-addresses` 参数传入 Core。Core 不自行遍历网卡；无可用
地址时只跳过局域网 ICE，不阻止 Core 启动。

首次申请通用信令端点时，Core 在每个传入 IPv4 上按实际可绑定结果惰性启动 Pion STUN/TURN，
使用动态 UDP/TCP 端口，并把本机 ICE 配置放在公网配置之前返回。TURN 凭据按
`sessionId + Core 已认证 playerId + identifier` 隔离，最长 6 小时；每个凭据最多 4 个
allocation，Core 全局最多 256 个。多个玩家不会共享身份、配额或信令路由。

局域网 TURN 只允许回环、私网、运营商级 NAT 和基准测试网段中的 peer 地址，不能被当作
公网开放代理。它可以提供非 mDNS 的 IPv4 srflx/relay candidate，但不是防火墙穿透特权：
Windows 仍需允许当前 Go Core 可执行程序收发局域网 TCP/UDP，Wi-Fi AP 客户端隔离也会阻断
客户端到 Authority。此时只能修正网络策略或使用可到达的 Go Server 公网 TURN。

### Go Server 公网 ICE

Go Server 使用 Pion TURN，同时监听 UDP 与 TCP。部署至少配置：

- `relay.turnUdpListen`、`relay.turnTcpListen`；
- `relay.turnPublicIp`、`relay.turnPublicPort`；
- `relay.turnRealm`；
- `relay.turnMinPort`、`relay.turnMaxPort`，并在防火墙/NAT 开放该 UDP 端口段；
- 环境变量 `PLAYMESH_TURN_SHARED_SECRET`，至少 32 字节。

公网 TURN 用户名和密码在每个加入用户附着时重新临时生成，TTL 只约束该 peer 的 ICE/TURN
凭据，不约束在线房间或邀请。若候选对任一侧为 relay，Core 记录
`connectionMode=relay`；否则记录 `direct`。该结果来自 Pion 实际选中候选对，不采信 HTML
或加入请求自报。

Go Server 只校验配置结构和可绑定性，不在启动时按“公网、私网或回环”地址性质拒绝
`turnPublicIp`；NAT 映射与公开地址由部署者负责。配置地址不可达时，客户端 ICE 失败诊断会
报告连接/收集状态、候选类型与已脱敏 ICE URL，不包含 TURN 用户名、密码、邀请或共享密钥。

## 通用 HTML WebRTC 信令

App SDK `3.4.0` 新增：

```js
const endpoint = await playmesh.app.webrtc.getSignalingEndpoint("camera/main");
const pc = new RTCPeerConnection({ iceServers: endpoint.iceServers });
const socket = new WebSocket(endpoint.url);
```

端点绑定当前 `sessionId + identifier + Core 已认证 playerId`，票据 30 秒过期且只能使用
一次。信令帧必须带 `type`、`version`、`timestamp`、`requestId`、目标玩家和 JSON
`payload`。Core 只按 Authority 星形拓扑转发，并注入可信 `senderPlayerId`；HTML 自行管理
SDP、trickle ICE、轨道、DataChannel、码率、权限提示、前后摄像头、ICE restart 和关闭。
平台不会替 HTML 建立媒体源，也不会把媒体流送入 Session 数据通道。`iceServers` 优先包含
可用的 Authority 局域网 STUN/TURN；当前会话同时具备公网 Relay 时，再追加 Go Server
STUN/TURN。这里的“优先”是返回数组固定为本地在前、公共在后；浏览器最终仍按 ICE
candidate priority 与连通性检查选择候选对，并不把数组顺序当作强制路由。HTML 必须把完整
列表传给同一个 `RTCPeerConnection`，不能假设列表非空。

## 房间成员连接方式

Core 在宿主会话快照的内部 `Player.connectionMode` 返回：

- `lan`：请求直接从本地/LAN 入口进入；
- `direct`：远程加入 PC 使用非 relay ICE 候选对；
- `relay`：实际选中 TURN relay 候选。

该内部字段不进入公开 Game SDK。主 App 与 Runtime 的分享/邀请房间成员列表分别显示
“局域网”“直连”“中转”。已经打开的房间面板必须订阅后续 Session 快照，不能只在打开时
读取一次，也不能只按在线人数去重；昵称、在线状态或连接方式变化都要立即重建。断线成员
保留原模式和离线状态，重新通过现有入口加入后由 Core 重新判定。

## 安全和资源上限

- Host lease 与 Join capability 均随机并使用常量时间摘要比较，其有效性绑定当前在线房间；
  ICE/TURN、请求时间戳和一次性票据继续受各自 TTL 约束。
- SDP/ICE 信令与通用 SDK 信令都有消息大小、时间偏差和每秒消息上限。
- 通用 SDK 信令每个会话玩家最多占用 32 个待消费票据与活动标识符连接，Core 全局最多
  保留 4096 个未过期票据。
- Authority 局域网 TURN 使用进程内随机密钥和玩家/标识符隔离的短期凭据，只允许局域网
  peer；每凭据最多 4 个 allocation，Core 全局最多 256 个。
- 每用户一个 PC、每本地连接一个 DataChannel；每 peer 最多跟踪 4096 个活动连接 ID。
- TURN 只使用短期凭据；Go Server 不获得邀请 fragment 中的流证明密钥和分享 token。
- DataChannel 的 DTLS/SCTP 提供传输保护；Relay 4 不再重复实现应用层 AES 帧协议。
- 关闭 Host、Client、PC、信令或本地监听器时，关联连接显式回收；未附着房间由创建 TTL
  兜底，已附着房间由主机信令连接和心跳持有，不能按固定运行时长清除。

## 兼容和验收

Relay `3.0.0 -> 4.0.0` 为 MAJOR 更新，没有降级或双栈。升级时必须同时更新主 App、
Runtime、Go Core 与 Go Server。旧会话和旧邀请应自然失效，不能迁移到新协议。

自动验证覆盖：Relay 鉴权/限流/多客户端信令、公网 TURN 临时凭据、Authority 局域网 TURN
实际 allocation、两个玩家的隔离凭据、两个并发加入用户、Web/Core 独立大流、Binary
WebSocket、协议元数据和关闭。正式发布前仍必须手工验证 Android/Windows 同 LAN（含防火墙
放行与多个用户）、跨公网直连、强制 TURN UDP、强制 TURN TCP、NAT/防火墙映射、摄像头
权限和长时网络切换。
