# Go Server 开发约定

本文面向维护 `go-server/` 的平台开发者。Go Server 是可选、轻量、可独立部署的
服务端实现，承担三类能力：

- 账号与游戏包源：邮箱账号、上传密钥、所有权、审核、发布、检索和下载。
- 公共 WebRTC 基础设施：为不同网络中的 App 签发短期会话、转发 SDP/trickle ICE，
  并提供 Pion STUN/TURN UDP/TCP。
- 用户/管理员 Web：只负责同一业务服务的可访问 UI，不改变 API 契约。

它不是 App 内置的 Go Core，不运行 HTML 游戏，不执行 Authority 规则，也不负责
计分、房间规则或游戏状态。

当前 Catalog API 为 `3.0.0`，Relay 协议为 `4.0.0`，SQLite schema 为 v6。v6 在游戏记录中持久化规范化
ZIP 的 `package_size_bytes`，避免列表请求重复读取包文件。完整部署说明见
`go-server/README.md`，本轮实现说明见
[Playmesh 3.0.0 本地功能实现说明](../implementation/playmesh-3.0.0-local-implementation.md)。

## 职责边界

```text
Go Server
  ├─ HTTP 基础设施
  │    Request ID / 日志 / CORS / 鉴权 / 限流 / 请求上限
  ├─ Catalog 与游戏包服务
  │    服务声明 / 列表与搜索 / 上传与校验 / 下载
  ├─ 用户与发布治理
  │    注册 / 验证 / Session / 上传密钥 / 所有权 / 审核 / 上下架 / 删除
  └─ Relay
       临时信令房间 / Host Lease / Join Capability / TURN REST 凭据 / Pion TURN
```

三个层次不得混合：

- HTTP 中间件只处理通用请求上下文，不解释游戏包和隧道业务。
- Catalog 与游戏包服务只处理可发布包，不读取游戏运行数据，不参与联机会话。
- 用户身份与所有权只使用稳定账号 ID；邮箱、展示名称和包内 author 不能代替账号 ID。
- Relay 只处理房间鉴权、配对、限制、超时和不透明 SDP/ICE 转发；TURN 转发 DTLS/SRTP/
  SCTP 数据包，不解析游戏业务、HTTP、WebSocket 或媒体内容。

Go Server 与 App 自带的本机游戏库可以实现同一 Catalog 读取契约，但两者不是同一
进程，也不共享存储路径。Go Core 只负责当前 App 的本地会话与消息路由。

## 双端口边界

Go Server 必须使用两个独立 Gin Engine 和监听器：

- App 外部端口注册公开门户、`/api/public/**`、`/health`、`/apps/**` 与
  `/relay/**`。
- 管理端口只注册 `PLAYMESH_ADMIN_PATH` 下的页面、静态资源、登录、管理员 CRUD、
  设置和负载接口。

后台端口应绑定回环或独立管理网络。不能只靠路由前缀把后台与 App API 暴露在同一个
公网监听器上。

## 当前公开协议

Catalog 读取面由 [Catalog API](../catalog-api.md) 定义：

```text
GET /apps/info
GET /apps/list
GET /apps/icon
GET /apps/download
```

公共中转由 [Relay 协议](../remote-game-relay.md) 定义：

```text
POST   /relay/v1/host
GET    /relay/v1/host
DELETE /relay/v1/host
GET    /relay/v1/client
```

以上 GET 是 WebSocket 信令握手。Go Server 不再接受 TCP Upgrade 数据流。服务启动时若
`supportsGameRelay=true`，还必须成功启动 Pion TURN UDP/TCP；任一监听失败都应使启动
失败，不能在声明 Relay 可用时静默缺少 TURN。

TURN 部署必须设置公网 IPv4、公共端口、UDP/TCP 监听、UDP 中继端口范围和 realm，
`PLAYMESH_TURN_SHARED_SECRET` 至少 32 字节。公网防火墙/NAT 必须同时开放 3478 TCP/UDP
及配置的 UDP 中继端口段。TURN 用户名和密码按 Relay 房间 TTL 动态生成，不能写入
Catalog 配置、日志或持久化数据库。

App 外部端口提供：

```text
GET  /api/public/games
GET  /api/public/games/:id/download
GET  /api/public/source-qrcode
GET  /api/public/source-info
GET/POST /api/user/auth/**
GET/PATCH /api/user/me
PUT  /api/user/upload-key
GET/POST/DELETE /api/user/games/**
POST /api/user/uploads
```

管理端口只提供：

```text
<ADMIN_PATH>/api/auth/captcha
<ADMIN_PATH>/api/auth/login
<ADMIN_PATH>/api/admin/**      全部要求管理员 Session
```

公开页面和 Catalog 只查询每个 gameId 当前语义版本最高的
`approved + published` 记录。pending、rejected、deleting、历史版本和已下架版本
不得进入公开元数据、图标或下载。若最高 approved 版本下架，不回退任何历史版本。
管理员页面可查看审核状态，但管理员下载也拒绝 deleting。

Catalog API、上传管理面和 Relay 协议分别评估版本。只修改其中一个领域时，不得
机械提升其他领域的版本。

## 游戏包存储约定

服务端只接受 Playmesh 可发布包：

```text
main.json
capabilities.json           可选
icon.png                     可选
app/
```

以下内容不得进入共享包：

```text
data/
cache/
playmesh/
开发者本地历史
工作区 Token 或配置
```

上传不能等同于解压覆盖目录。当前实现不执行上传内容，而是扫描原始 ZIP、流式读取
受限条目并保存通过检查的压缩包。实现必须：

1. 限制压缩包大小、展开后总大小、文件数量和单文件大小。
2. 拒绝绝对路径、目录穿越、反斜杠路径、符号链接、特殊文件、加密条目和重复路径；
   `app/` 内普通资源不使用扩展名或文件类型白名单。
3. 校验 `main.json` 可解析且包含服务端持久化所需的 `id`、`name`、`version`；从
   `entries.game` 读取首页声明，去掉可选查询串后要求路径指向 `.html`，且对应
   `app/{entryPath}` 是非空、合法 UTF-8、无 NUL 的网页文本。不限制 SDK 版本，也不把
   当前客户端的模式、Controller、Authority、能力或其他清单结构作为上传门槛。
4. 在临时目录完整校验，成功后原子提交新版本；失败时不产生版本或所有权残留。
5. 清理超时或失败的临时文件，并对同一游戏 ID 的并发写入串行化。
6. 列表、搜索、图标和下载必须读取同一个已提交包存储，不能各自维护事实副本。
7. 根 `icon.png` 执行 PNG 结构、CRC、尺寸、像素和解码预算校验；无效图标忽略，
   其他恶意包错误仍拒绝。
8. `main.json` 的未知键与未知嵌套结构在数据库及规范化 ZIP 中原样保留，避免 SDK 或
   Manifest 扩展要求服务端同步发布。

上传失败或版本冲突后的即时删除如果失败，必须返回可观察错误，并由持久化恢复路径
继续处理。当前实现以 SQLite 中全部 `stored_path` / `icon_path` 为引用白名单，
启动时及每 30 秒扫描一次：游戏目录只删除符合服务端随机命名规则且未被引用的常规
文件，隔离目录只删除 `upload-*` / `normalized-*` 临时 ZIP；不匹配的文件、目录和
符号链接一律保留。

默认使用 ClamAV 执行跨平台病毒扫描。`scanner.required == true` 时，扫描器缺失、
超时、病毒库错误或非明确干净结果都必须拒绝上传。ClamAV 之外仍执行可配置的活动
内容静态检查；默认仅保留可执行 HTML Data URL、`eval`、Service Worker 和活动 SVG。
外部 HTTP/WS、协议相对链接、动态 `Function`、`file:`、`javascript:` 及
`iframe/object/embed` 都不是默认拒绝项。危险原包立即删除，扫描哈希、命中项和
拒绝原因保存在 SQLite。

部署者可以通过 `.env` 的 `PLAYMESH_CLAMAV_ENABLED=false` 显式关闭 ClamAV。
该开关必须保持环境级只读，不能由管理 API 改写；关闭只跳过病毒签名扫描，不得关闭
ZIP 边界、声明首页、Manifest 或内容正则检查。公共生产源应保持默认开启。

活动内容规则由 `scanner.contentRules` 配置，每条包含稳定 ID、说明、正则、
适用扩展名和启用状态。后台保存和服务启动都必须编译校验全部正则，拒绝重复 ID、
无效表达式和不规范扩展名，并保证至少一条规则启用。ZIP 路径、展开大小、压缩比、
根目录和声明首页检查属于不可被正则替代的代码级基线。规则中的扩展名只用于选择需
扫描的活动文本，不构成上传文件类型白名单。

旧配置中精确匹配平台历史默认值的 `external-http-ws`、三条
`protocol-relative-*`、`function-constructor`、`file-protocol`、`javascript-url`
和 `embedded-document` 规则在加载时自动移除；仅复用旧 ID 但表达式不同的部署者
自定义规则保留。管理员此后显式配置的其他内容规则仍照常执行。

路径穿越必须在 ZIP 条目路径层按规范化结果阻断，不能用全局内容正则禁止 JavaScript
文本里的 `../`。包内模块和资源的相对导入属于正常内容；内容规则若要检查路径类风险，
必须绑定具体危险 API、协议或执行上下文。路径类旧配置只迁移删除项目曾发布的精确
`parent-path` 默认规则；所有迁移都不得删除表达式不同的部署者自定义规则。

## 移动端访问

用户门户必须以窄屏优先验证：表单控件保持至少 44px 触摸高度和 16px 输入字号，
筛选器、复制栏、游戏卡片及分页在手机宽度下不得产生页面级横向滚动。管理端表格在
窄屏应转换为带字段标签的记录卡片，不能要求管理员拖动 850px 宽表格才能审核。

App 外部监听默认允许局域网访问，但手机必须使用服务器局域网 IP 或生产域名，不能
使用手机自身的 `127.0.0.1`。`relay.publicBaseUrl` 也必须配置成手机可达的公开
Origin，二维码和 App Relay 都以该值为准。管理监听仍应默认绑定回环；仅在可信管理
网络和防火墙保护下，才可改成手机可达的独立地址。

后台保存 `relay.publicBaseUrl` 后，Catalog Handler 必须通过并发安全的运行时快照
立即更新 `/apps/info`，且该响应使用 `Cache-Control: no-store`。App 每次探测已启用
游戏源都会重新请求 `/apps/info`，不得把源 Host 当作 Relay 地址，也不得沿用进程
启动时的旧声明。Relay 容量、超时和监听器仍属于重启生效配置。

版本记录是存储主键，gameId 所有权单独存储。首次有效上传在事务中取得所有权；
同 gameId 的新版本必须由同一账号上传并严格高于数据库当前最高语义版本。不能根据
文件名、邮箱、展示名称或 author 猜测所有权。下载端仍把远程包视为不可信输入。

## 鉴权与访问控制

Source Token 由领域中间件处理，Handler 不自行比较。用户上传不接受匿名邮箱参数：
浏览器必须使用 HttpOnly/SameSite=Lax Session Cookie 与 CSRF；App/Workspace 必须
使用账号上传密钥：

```http
Authorization: UploadKey <key>
```

上传密钥只存 HMAC-SHA256，明文只在创建/轮换时返回一次。读取 Token 与上传密钥是
不同权限，不能复用或互相回退。

- `allowUserRegistration=false` 时注册 API 返回 `403 registration_disabled`，
  但已有账号登录和待验证账号完成验证不受影响。
- 密码长度 10–128；上传密钥必须含大小写、数字和特殊字符。
- App 上传与网页上传共享按 IP 计算的 2 秒限流，并受并发扫描和完整恶意包检查约束。
- App 包内 author 始终由账号展示名称覆盖，不能通过 ZIP 冒充发布者。
- `/relay/v1/client` 可以免 Source Token，但仍必须校验限定隧道的 Join Capability。
- Host Lease 只允许管理创建它的隧道，不能替代全局 Source Token。
- 日志不得记录完整 Source Token、Host Lease、Join Capability、邀请 Token 或端点密钥。
- 生产部署应在反向代理或服务入口使用 HTTPS，并设置防火墙、请求速率和存储配额。

管理员账号密码、App 双 Token 和 SMTP 凭证来自 `.env`。验证码支持数字计算与文字
点选两种模式：计算图使用 `mojocn/base64Captcha`，文字行为验证码使用
`wenlng/go-captcha/v2` 与其官方嵌入资源。接口只下发不透明 ID、图像与必要的点击
次数，严禁下发算式文本、答案、候选字符和目标坐标；答案或目标点只保存在后端。
点选坐标必须按原图尺寸换算并由库的区域验证处理。验证码两分钟过期、验证时一次性
消费；验证码和登录接口分别按 IP 限流，默认每秒一次。管理员 Session 只以哈希写入
SQLite，除验证码和登录外，所有 `<ADMIN_PATH>/api/admin/**` 接口必须鉴权。

管理页面路径使用 `.env` 的 `PLAYMESH_ADMIN_PATH`，不得保存到 `server.json`、
运行配置响应或公开页面。公开门户不得提供管理入口链接；静态资源 Handler 也不得
返回 `admin.html`。管理页面、后台脚本、登录/验证码和管理员 API 必须全部以该安全
路径为前缀，不能保留固定 `/api/auth` 或 `/api/admin` 旁路。自定义路径必须非空，
只允许 URL 安全的字母、数字、`-`、`_` 和分段 `/`，且不得占用 `/api`、
`/assets` 或 `/health`。路径隐藏只降低入口扫描噪声，不能替代管理员 Session、
登录限流和验证码。

## Relay 约定

Relay 的核心不变量：

- 客户端不能提交任意目标 Host、端口或 URL。
- `tunnelId`、Host Lease 和 Join Capability 只用于临时隧道定位与鉴权。
- 邀请 fragment 内的 Authority 分享凭据和 DataChannel 首帧证明密钥只存在于两端 App，
  不能进入 Go Server 请求、状态或日志。
- Go Server 只转发有大小、速率和路由约束的 SDP/trickle ICE JSON，并通过 TURN 转发
  WebRTC 数据包；不得恢复 raw TCP 字节复制，也不得解释 HTTP、WebSocket 或媒体业务。
- 每个加入用户只占一个独立 PeerConnection 名额；该用户的 web/core TCP 连接如何映射为
  独立 DataChannel 由两端 Go Core 负责，不进入 Go Server 信令状态。
- 已附着主机的隧道租约由当前信令 WebSocket 存活状态决定；心跳确认主机断开或宿主显式
  删除时，立即回收隧道和全部关联连接，使旧二维码与旧链接同时失效。
- `relay.tunnelTTLSeconds` 兼容保留原字段名，只限制主机创建后首次附着等待时间以及每个
  新 peer 的 ICE/TURN 临时凭据寿命；它不得再作为在线主机邀请的硬过期时间。
- 全局隧道数、单 IP 连接数、单隧道连接数、待配对时间和空闲时间都必须有上限。
- Relay 在 Source Token、Lease 或 Capability 校验前也必须有允许正常连接池突发的
  IP 窗口限流，避免公开正式 Token 被用于高频鉴权消耗。

Relay 无法检查 DTLS/SCTP 或 TURN 承载的加密内容是否属于游戏流量。Source Token、临时
Capability 和官方 App 流程构成当前产品边界；如果需要对客户端进行密码学证明，应单独
设计设备证明或客户端证书，不能通过让中转解释业务内容实现。

## 配置约定

`go-server/server.json` 是后台管理的非敏感运行配置持久化文件。管理员通过
`GET/PUT /api/admin/config` 的结构化表单读取和修改它，不要求部署者长期手工维护。
配置结构必须：

- 使用严格 JSON 解码，未知字段直接报错。
- 启动前完成全部范围、URL 和必填项校验。
- 对外地址使用显式 `publicBaseUrl`，不得从监听地址、请求 `Host` 或转发头猜测。
- `showPublicSourceQRCode` 默认开启。开启时公开门户由后端把 `publicBaseUrl`、
  正式发布 Token 编码为唯一 `publicURL?token=...` 二维码；关闭时
  公开端点返回 404 且前端不渲染模块。正式 Token 因此属于公开只读凭据，绝不能与
  待审核 Token、管理员 Session 或 SMTP 密钥复用。
- 匿名 `/api/public/source-info` 可以返回当前配置的 `publicBaseUrl` 与正式 Token，
  供首页手动复制；当前访问地址由浏览器 `window.location.origin` 显示。该接口不得
  返回待审核 Token、管理员路径或其他秘密。
- 密钥、生产域名和容量限制由部署环境提供，仓库示例不得携带真实凭证。
- 新字段提供安全默认值；删除或改变语义前评估配置兼容性。
- 后台保存前使用完整 Config 校验，并通过同目录临时文件原子替换。
- 监听端口、数据库路径、限流器和 Relay 容量等字段明确提示安全重启后生效。
- `maxConcurrentScans` 必须限制 ClamAV 与 ZIP 检查并发，避免多来源上传同时拉起
  无上限扫描进程。

当包存储能力引入目录、配额、上传大小或覆盖策略配置时，应归入独立的包服务配置
对象，不得塞入 Relay 配置。

### Web UI 国际化与主题

`server.json.webUI` 可覆盖默认 locale、启用 locale、语言切换、默认主题和主题切换。
配置只能引用统一清单中的 locale；未知、禁用默认语言、fallback 环、词典 key 漂移
或非法主题使服务拒绝启动。

Go Server 是独立部署产品，用户门户和管理后台只读取清单的 `goServer` bundle
（各 locale 的 `go-server.json`）。它不读取 App `app.json`，也不能把自身词条提供
给 App 内置 Developer Workspace；工作区归 App 所有并由宿主投影 App 词条。

用户和管理员页面共用 locale/theme loader。静态文本、动态状态、placeholder、
title、alt、label 和 aria-label 全部走词典；错误优先按机器 code 映射，不向界面
直接展示 API 原始 message。`/api/**`、`/apps/**` 和 Relay 不读取 locale，同一请求
在不同 UI 语言下返回完全相同的 JSON。

HTML 壳的 `data-i18n*` 节点和属性不得携带中英文 fallback；统一首帧遮罩必须持续到
`go-server.json` bundle 投影完成。Playmesh、ClamAV、协议路径、URL 示例等技术值
可原样保留，游戏名、账号、版本等动态/API 值不得登记为本地化 key。静态契约测试
同时校验 HTML 无 fallback 且每个引用 key 在所有启用 bundle 中非空。

Web 支持 system/light/dark，二维码保持白底；普通圆角不超过 8px，不使用渐变、
光晕、装饰阴影或 backdrop blur。表单和交互控件有可见 `:focus-visible`，reduced
motion 下禁用非必要动画。

## 删除状态机

版本删除不是单一数据库 DELETE：

1. 事务把记录标记为 `deleting` 并写入审计。
2. 删除 ZIP、图标和派生文件。
3. 第二个事务删除版本；若是最后一个版本，同步释放 gameId 所有权。

文件删除失败返回 `202 deletion_pending`。服务启动立即调用清理，运行时每 30 秒
重试；缺失文件视为已清理，流程幂等。审计表不得用会随游戏行删除的外键，最终删除
后仍保留操作记录。

当前 schema 的审计事件必须同时保存稳定 `actor_identifier`：用户使用十进制用户 ID，
管理员使用 `.env` 配置的管理员用户名，后台恢复任务使用 `system`。审核、自动或
手动上/下架、删除开始/完成及设置更新均保存角色、gameId/版本、`from`、`target`
和时间；设置事件以 `_server` / `settings` 作为稳定资源标识。schema 采用破坏式
边界，不提供旧数据库迁移。

## 新增服务端能力

新增 Handler、存储后端或协议字段时按以下顺序：

1. 判断它属于 Catalog 读取面、游戏包管理面、Relay，还是新的独立领域。
2. 先定义请求、响应、失败语义、权限、资源上限和版本影响。
3. 将业务实现放入对应模块，由 `internal/server` 统一组合和注册。
4. 通用策略进入中间件；领域鉴权保留为显式领域中间件。
5. 更新对应协议文档、根 README、平台目录和版本日志。
6. 分别验证协议行为、恶意输入、资源回收、并发和部署配置。

不得为了复用而创建能代理任意地址的通用转发接口，也不得把游戏源管理逻辑放进
Relay Manager。

## 发布检查

- Catalog、管理面和 Relay 的实际路由与文档一致。
- 包上传、替换、失败回滚、列表和下载使用同一存储事实。
- Catalog 只公开每个 gameId 当前最高 `approved + published` 版本且不回退。
- 所有权抢占、相同/较低版本和并发上传返回冲突且无文件/事务残留。
- deleting 状态可在启动和后台恢复，最后一版完成删除后释放所有权。
- 所有写操作的鉴权、大小限制、限流和审计已启用。
- 隧道凭证按角色隔离，Authority 分享凭据和 DataChannel 首帧证明密钥从未到达服务端。
- 连接、临时文件和失败上传可以在超时或关闭时回收。
- `server.json` 示例不含生产秘密，公网地址与 TLS 终止配置一致。
- 版本日志分别记录已验证内容和仍需完成的公网、压力与故障恢复验证。
- 两个启用语言的 Web 词典 key 集一致，嵌入副本与共享源逐字一致。
- 不同 locale/theme 下 API JSON 逐字段一致。
- 使用 `go.mod` 固定的已修复 Go 工具链完成 `go build`、`govulncheck` 与
  `gosec`；不得用存在已知标准库漏洞的旧工具链发布公网服务。
