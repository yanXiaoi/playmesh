# Playmesh 局域网与公共中转联机架构

状态：开发基线
适用版本：NEXT
范围：App 运行时、游戏分享、在线游戏源、`go-server`

## 1. 目标与破坏性边界

Playmesh 在保留现有局域网联机能力的基础上，增加仅供 Playmesh App
使用的公共服务器中转联机能力。

本次是分享运行时的破坏性架构更新。旧的分享 `/api/*` 路由直接删除，不保留
兼容分支、别名或迁移适配器。游戏包格式、Game SDK 游戏侧公共 API 和开发
模板不变；AI 提示词只同步游戏必须遵守的传输抽象。已有游戏继续只通过 SDK
访问平台能力，并从权威主机加载 `/app/**`、`/bucket/**` 和 `/playmesh/**`。

对游戏可观察到的变化只有：App 加入游戏时页面运行在本地回环 Origin 下，
因此可以使用安全上下文允许的浏览器功能。普通局域网浏览器仍直接访问主机
地址。

设计约束：

- 主机和客户端均不需要公网 IP。
- 局域网和公共中转可以同时提供加入能力。
- 局域网 App 使用本地回环入口并进行原始 TCP 透传，不增加加密。
- 公共中转由两个 App 终端完成端到端加密。
- Go Server 只提供临时 TCP 隧道；它没有端点密钥，密码学上无法解密游戏数据。
- 普通浏览器只能通过局域网 Authority 地址加入。
- 大型资源按需流式加载，不预下载完整游戏包。
- 不新增无必要的本地 HTTP API 实体。

公共中转首期不包含后台登录、管理控制台、通用反向代理、任意 TCP 端口转发和
普通浏览器公共中转。Go Server 的游戏包分享、上传与分发属于独立的 Catalog /
包管理领域，不进入 Relay 数据面。

## 2. 总体链路

### 2.1 局域网 App

```text
客户端 WebView
  -> 127.0.0.1 LocalTunnelGateway
  -> 局域网原始 TCP 透传
  -> 主机 Authority Gateway
  -> Go Core Session
```

局域网链路不加密、不封装。每条 WebView TCP 连接直接对应一条 Authority
连接。

### 2.2 局域网 HTML

```text
普通浏览器
  -> 主机公开的局域网 Authority 地址
  -> Go Core Session
```

普通浏览器不经过 LocalTunnelGateway，也没有 App Bridge 和公共中转能力。

### 2.3 公共中转 App

```text
客户端 WebView
  -> 127.0.0.1 LocalTunnelGateway
  -> 客户端端到端加密
  -> Go Server 原样转发密文
  -> 主机 Tunnel Endpoint
  -> 主机端解密
  -> Authority Gateway
  -> Go Core Session
```

外层 TLS 可选，App 终端间的认证加密强制启用。

## 3. 分享表现层

现有“二维码与链接”展开弹窗顶部提供三个同级页签：

```text
[ 局域网 ] [ 服务器 ] [ 房间状态 5 ]
```

默认显示“局域网”。页签切换只改变当前展示内容，不开启、关闭或切换实际
联机通道。

### 3.1 局域网

显示局域网地址、二维码、复制链接、系统分享入口和局域网服务状态。

局域网邀请固定为：

```text
http://<authority-host>:<port>/<declared-app-entry>?channelId=<channelId>&token=<shareToken>
```

其中 `<declared-app-entry>` 必须保留当前运行模式在 `main.json` 中声明的实际
页面，例如游戏主页 `/app/index.html` 或控制器主页
`/app/controller/index.html`；自定义嵌套入口也必须原样保留。链接只增加
`channelId` 与当前分享 Token，不携带 Core 端口、联机码、游戏 ID、游戏名称或
方向。Authority 同时校验入口路径、`channelId` 和 Token，再在返回 HTML 时注入
权威 Game SDK 所需上下文。

同一个二维码：

- Playmesh App 扫描后解析并保留同一个 `/app/**` 入口，在本地回环网关下加载。
- 普通浏览器打开后按原链接直接使用主机 Authority 地址。

### 3.2 服务器

服务器选择列表复用在线游戏库中已经启用的游戏源：

1. 并发获取每个源的 `/apps/info`。
2. 筛选 `supportsGameRelay == true`。
3. 异步测量本次请求延迟。
4. 分页显示并支持按名称、Host、建造者搜索。
5. 每个源右侧提供“连接”按钮。

连接后切换为当前服务器详情，显示服务器声明、最新延迟、连接状态、App
专用二维码/链接和断开按钮。状态为：

```text
连接中 / 已连接 / 重试中 / 已断开
```

关闭分享弹窗不会断开中转。首期同一游戏会话只连接一个中转源。中转断开
不影响局域网分享。

公共中转邀请固定为：

```text
https://relay.example/j/<tunnelId>#inviteToken=<opaqueToken>
```

`tunnelId` 只用于定位临时隧道。`inviteToken` 由 App 本地解析，封装客户端
Upgrade 路径、Authority 的实际 `/app/**` 入口、`channelId`、Join Capability、
当前分享 Token 和端到端密钥；它不会进入 Go Server 的 HTTP 请求目标。
`/j/**` 是 App 邀请标识，不是页面根路径或 Go Server 的数据面接口，页面中的
`/app/**`、`/bucket/**`、`/playmesh/**` 不会拼接到 `/j/**` 之后。普通浏览器
打开该地址也不能获得游戏页面。

### 3.3 房间状态

房间状态独立于具体分享通道，统一展示当前 Core 游戏会话中的已加入玩家：

- 昵称
- 实时延迟
- 来源
- 在线/重连状态

来源固定为：

```text
服务器 / 局域网 App / 局域网 HTML
```

来源由 App 运行时注入给权威 Game SDK，并在加入 Core 时归一化为固定枚举。
该字段只用于房间状态展示，当前没有远程 App 证明机制，不能作为鉴权、授权、
封禁或计费依据。玩家按 Core `playerId` 去重，多条 HTTP、资源或 WebSocket
连接不能重复计数。

玩家延迟由当前玩家的权威 Game SDK 通过 Session WebSocket 探测 Core/Authority
往返时间，再把结果报告给 Core 统一广播；Core 校验数值范围，但该值仍是客户端
报告的展示数据，不能参与权威游戏规则。游戏源列表中的服务器延迟仅代表
`/apps/info` 请求耗时，两者不能混用。

房间状态即使不在当前页签也持续订阅会话更新。页签标题实时显示当前玩家
数量，但玩家加入或离开不会强制切换页签。

## 4. 游戏源声明

新增：

```http
GET /apps/info
```

支持中转的游戏源示例：

```json
{
  "catalogApiVersion": "2.0.0",
  "name": "Playmesh 公共游戏源",
  "author": "服务器建造者",
  "homepage": "https://example.com",
  "supportsGameRelay": true,
  "relay": {
    "protocolVersion": "2.0.0",
    "transport": "playmesh-tcp-upgrade",
    "publicBaseUrl": "https://relay.example.com",
    "hostPath": "/relay/v1/host",
    "clientPath": "/relay/v1/client",
    "maxConnectionsPerTunnel": 64
  }
}
```

`name`、`author`、`homepage` 可选；`author` 在游戏源界面显示为“建造者”，不要
与游戏 Manifest 的“发布者”标签混用。名称缺失时客户端显示格式化后的
`host:port`，HTTP 80 和 HTTPS 443 省略端口。`publicBaseUrl` 是 Go Server
明确配置并返回的公共中转 Origin，只能包含 HTTP/HTTPS 协议、主机和可选端口；
App 的 Host Upgrade、Client Upgrade 和最终二维码都必须使用它，不能从游戏源
Host 或当前请求头推导。外层是否使用 TLS 直接由 `publicBaseUrl` 的 HTTP/HTTPS
协议决定，不另设策略字段。`maxConnectionsPerTunnel` 同样来自当前 Go Server
配置，App 用它作为主机动态连接池上限，不在客户端硬编码服务器容量。可选字段
不存在时直接省略。

Catalog `2.0.0` 的 `/apps/list` 对每个 `gameId` 只返回当前 latest offer；
`/apps/download` 必须携带 `gameId + version`，图标使用同源独立 URL。Relay 只读取
`/apps/info` 中的中转声明，不改变这些 Catalog 规则。

### 4.1 App 自带游戏源

App 自带的游戏库分享服务器不支持公共中转，声明固定为：

```json
{
  "catalogApiVersion": "2.0.0",
  "name": "{用户昵称}的游戏库",
  "supportsGameRelay": false
}
```

不返回建造者、主页或 `relay`，用户不能修改这些固定字段。

## 5. Authority 暴露面

游戏分享运行时采用严格的最小公开面，只允许向加入方提供：

```text
/app/**
/bucket/**
/playmesh/**
SDK 无法替代的底层连接能力，例如当前游戏受控的 WebSocket Upgrade
```

上述清单是 Authority 对加入方的完整公开边界，而不是接口示例。新增功能必须
遵循“SDK 优先”原则：凡是能够由 Game SDK 或 App Bridge SDK 表达、校验和
路由的能力，均应优先通过修改 SDK 实现，不得为了接入便利而新增分享 HTTP
业务接口。只有受浏览器沙箱限制、确实无法由 SDK 替代，且本质上属于连接或
传输层的能力，才允许扩展 Authority 的底层入口。

任何新增底层入口都必须同时满足：

- 固定绑定当前游戏和当前会话。
- 不能接受任意目标 Host、端口或 URL。
- 在建立连接前完成身份、分享授权和会话校验。
- 不向游戏代码暴露底层连接对象。
- 不重复实现 SDK 已有的身份、昵称、存储、能力或会话操作。
- 同步更新协议文档、失败语义和回归测试。

旧分享网关中的以下路由直接删除：

```text
/api/app-capabilities
/api/join
/api/storage
/api/player/nickname
/v1/sessions/** 普通 HTTP 代理
```

加入、昵称、存储和能力通过 Game SDK、App Bridge、App 加入流程和当前受控
Session WebSocket 完成。`app-capabilities` 不再是 HTTP 接口，而是客户端
本地 `playmesh-app.js` 根据本机插件注册表和授权状态提供的 SDK 能力。

## 6. SDK 所有权

> **AI 上下文最小披露原则：面向游戏开发 AI 的提示词，只提供完成当前任务所必需、可由游戏代码调用或必须遵守的公开契约。回环代理、内部路由、中转鉴权、密钥协商、加密通道和 Relay 协议均属于平台实现，不得进入游戏 AI 提示词。**

权威 Game SDK 必须来自主机：

```text
/playmesh/sdk/v1/playmesh.js
```

它包含全局数据、游戏状态、会话协议和公共 SDK 契约。

只有以下文件由加入方 App 本地提供：

```text
/playmesh/sdk/v1/playmesh-app.js
```

它提供客户端本地 ID、昵称、能力和 App Bridge。LocalTunnelGateway 不解析
HTTP；加入方 App 另行启动只绑定 `127.0.0.1`、只提供这一份脚本的本地静态
入口，Authority HTML 引用该本机绝对地址。其他 `/playmesh/**` 全部来自权威
主机。

## 7. LocalTunnelGateway

所有 App 客户端通过稳定的本地回环 Origin 加载游戏：

```text
http://127.0.0.1:<local-port>
```

本地不生成自签名证书。页面 LocalTunnelGateway 只负责监听回环端口、建立
上游连接、双向复制、背压、取消、超时和关闭，不解析 HTTP、URL、Header、
Cookie、Range、WebSocket 或 Game SDK。局域网 App 的 Core 回环端口在每条
连接开始前执行一次固定的 `/playmesh/core` 受控 Upgrade；Authority 校验当前
分享 Token 后只连接本局 Core。Upgrade 完成后同样只复制原始字节，不公开或
接受任意 Host、端口与 URL。

传输驱动：

```text
LanDirectTransport     原始 TCP 透传
RelayEncryptedTransport 端到端加密后经 Go Server 传输
```

Authority 必须接受回环形式的 Host、使用相对资源地址，并避免把页面重定向到
固定局域网 IP。

## 8. GameShareCoordinator

主机 App 使用一个统一协调器管理：

```text
GameShareCoordinator
  - LAN Share Channel
  - Relay Share Channel
  - Player Connection Context Registry
```

局域网和公共中转共用同一个 Core 分享授权。第一个通道开启时创建授权，
第二个通道复用；最后一个通道关闭时才释放。关闭分享弹窗不释放授权。

玩家在线状态、昵称和延迟以 Go Core 会话为权威，连接上下文只补充来源：

```text
playerId
source
relaySourceId（可选）
relayTunnelId（内部）
latencyMs
connectionState
lastSeenAt
```

这些是运行时投影，不新增持久化玩家实体。

## 9. Go Server

Go Server 是轻量、可独立部署的游戏包源与公共中转载体。游戏包分享、上传、列表
和下载遵循 [Catalog API](catalog-api.md) 与
[Go Server 开发约定](platform/go-server-development.md)，不复用 Relay 的隧道
凭证、连接状态或存储。

Relay 声明由 `server.json` 配置，其中 `relay.publicBaseUrl` 明确指定对外可访问的
HTTP/HTTPS Origin。反向代理、TLS 终止或公网域名部署时必须配置为客户端实际可访问
的地址，不能依赖监听地址、请求 `Host` 或转发头自动猜测。

### 9.1 控制面

主机创建隧道：

```http
POST /relay/v1/host
Authorization: Bearer <source-token>
```

返回临时 `tunnelId`、仅主机使用的 `hostLease`、限定该隧道的
`joinCapability` 和过期时间。端到端密钥不由 Go Server 生成或返回，而是由
主机 App 使用安全随机数在本地生成。Go Server 不返回完整邀请；App 使用声明中
的 `publicBaseUrl` 作为 Origin，生成 App 专用邀请：

```text
http[s]://relay.example/j/<tunnelId>#inviteToken=<opaqueToken>
```

`opaqueToken` 只放在 URL fragment，内部封装客户端 Upgrade 路径、Authority
实际 `/app/**` 入口、`channelId`、Join Capability、Authority 分享 Token 和
端到端密钥。fragment 不属于 HTTP 请求目标，不会随普通页面请求、创建隧道请求
或 Upgrade 请求发送给中转服务器；客户端 App 在本地解析后只向真正的
`/relay/v1/client` Upgrade 发送 `tunnelId` 和 Join Capability，再把真实入口
恢复为 `http://127.0.0.1:{localPort}/app/...?...` 并从本机回环加载。即使 Go
Server 完全不受信任，它也拿不到页面入口、Authority 分享 Token 或端到端密钥。

客户端不能提交 `targetHost`、`targetPort` 或 `targetURL`。

### 9.2 数据面

主机维持待接收连接：

```http
GET /relay/v1/host?tunnelId=<id>
Connection: Upgrade
Upgrade: playmesh-tunnel
Authorization: Bearer <source-token>
X-Playmesh-Host-Lease: <lease>
```

主机 App 不再固定预建 16 条连接。每个隧道初始只建立
`min(4, maxConnectionsPerTunnel)` 条热连接；某条热连接被客户端配对后立即
异步补回热连接，活跃 HTTP、资源或 WebSocket 连接结束后对应槽位自然退出。
总连接数始终不超过 `/apps/info` 声明的 `maxConnectionsPerTunnel`。连接建立
失败或 Go Server 返回限流时按指数退避重试，不绕过服务器最终限流。

客户端每条本地 TCP 连接建立：

```http
GET /relay/v1/client?tunnelId=<id>
Connection: Upgrade
Upgrade: playmesh-tunnel
X-Playmesh-Join-Capability: <capability>
```

鉴权和配对完成后，Go Server 只执行双向 `io.Copy`。它可以看到隧道协议的连接
元数据以及密文字节，但端点密钥从未发送给它，因此无法还原 HTTP、静态资源、
Game SDK 消息或 WebSocket 内容。游戏内部的 WebSocket Upgrade 只是加密流中的
普通字节。

### 9.3 端到端加密

只有公共中转链路强制加密。每条浏览器 TCP 连接建立一条持续的透明加密流；
HTTP 请求、Range 资源响应和 WebSocket frame 均自动通过该流，不由业务消息逐条
调用加解密 API。当前协议使用：

- 主机 App 本地生成的 256 位随机端点密钥
- 每条连接独立的 128 位随机 Salt
- HKDF-SHA256 派生双向独立密钥
- AES-256-GCM 认证加密
- 双向独立的单调计数器与 Nonce 空间
- 32 KiB 上限的加密记录分帧、长度校验和认证失败即断开

Go Server 只持有 `tunnelId`、Host Lease 和 Join Capability；这些字段用于隧道
鉴权与配对，不参与端点内容密钥派生。

外层 TLS 可选，但公共部署推荐启用，以额外保护隧道元数据和加入凭证。

## 10. Gin 鉴权中间件

Source Token 必须通过全局 Gin 中间件处理，Handler 不得自行实现 Token
比较：

```text
Recovery
-> Request ID
-> Access Log
-> CORS
-> Body/Handshake Limit
-> Rate Limit
-> Source Token Middleware
-> Host Lease / Relay Capability Middleware
-> Handler
```

`auth.token` 为空时关闭 Source Token 校验；非空时，除配置白名单外统一要求
`Authorization: Bearer <token>`。

默认白名单：

```text
GET /health
GET /relay/v1/client
```

`/relay/v1/client` 虽免 Source Token，仍必须经过独立的
Relay Capability 中间件。所有鉴权在 Upgrade/Hijack 前完成。

## 11. 安全边界

- Tunnel Endpoint 在主机创建分享时固定绑定当前游戏 Authority。
- 客户端不能选择目标地址。
- Capability 只能进入指定临时隧道。
- 主机断开或游戏结束后隧道立即失效。
- Go Server 没有端点密钥，无法解密游戏路径、内容、SDK 消息或玩家昵称。
- 普通浏览器不能把 App 邀请转换成公网游戏网页。
- 官方 App 协议没有任意目标参数，Go Server 也不提供目标选择或转发接口，
  因而普通调用方不能把它直接当作通用 HTTP/TCP 代理。
- 日志不得记录完整 Source Token、Host Lease、Join Capability 或
  `inviteToken`；Authority 分享 Token 和端点密钥不得进入任何 Go Server 请求、
  响应、内存状态或日志。

服务端必须限制隧道创建频率、单 IP/单隧道连接数、待配对连接数、空闲时间
和隧道生命周期，并在销毁隧道时关闭全部关联连接。

端到端加密也带来一项明确限制：Go Server 无法检查密文是否确实属于游戏流量，
因此当前“仅供 App 使用”是官方客户端流程、Source Token 和临时 Capability
共同形成的产品边界，不是远程 App 的密码学证明。持有有效 Host Source Token
的改造客户端理论上可以转发任意字节。若威胁模型需要阻止这类客户端，必须另行
引入设备证明、安装证明或客户端证书；不得通过把端点密钥交给 Go Server 来实现。

## 12. 大型资源

游戏资源不预下载，必须保持：

- 流式传输
- 请求取消
- TCP 背压
- 动态 `/bucket/**`
- 长连接和 WebSocket

LocalTunnelGateway 和 Go Server 均不得把完整响应读入内存，也不得改写或吞掉
Authority 已提供的 Range、206、ETag 或缓存语义；这些 HTTP 能力由 Authority
资源服务决定。

## 13. 验收基线

- 分享弹窗存在“局域网 / 服务器 / 房间状态”三个同级页签。
- 局域网与中转可以同时加入同一 Core 会话。
- 房间状态统一展示所有玩家的昵称、RTT、来源和连接状态。
- 玩家来源正确区分服务器、局域网 App、局域网 HTML。
- App 通过回环 Origin 运行，普通浏览器行为不变。
- 局域网邀请保留 `main.json` 声明的实际 `/app/**` 入口，查询参数只含
  `channelId + shareToken`；普通浏览器仍可直接加载并加入，App 解析同一链接后
  在本地回环 Origin 下加载。
- 公共邀请只含 `tunnelId + fragment inviteToken`，浏览器误扫不会把
  `inviteToken` 发送给 Go Server。
- 局域网链路不加密，公共中转数据始终端到端加密。
- `playmesh.js` 始终来自 Authority，只有 `playmesh-app.js` 来自客户端。
- Go Server 从未获得端点密钥，密码学上无法解密所转发的密文，因而也无法解析游戏协议。
- Token 由全局中间件验证，白名单可配置。
- 旧游戏包、SDK 公共契约和开发模板没有变化；AI 提示词仅增加传输透明、统一使用 SDK 的行为约束，并遵守最小披露原则。
