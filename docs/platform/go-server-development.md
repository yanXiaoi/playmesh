# Go Server 开发约定

本文面向维护 `go-server/` 的平台开发者。Go Server 是可选、轻量、可独立部署的
服务端实现，承担两类能力：

- 游戏包源：分享、上传、检索和下载 Playmesh 游戏包。
- 公共联机中转：为不同网络中的 App 配对临时连接并复制加密字节。

它不是 App 内置的 Go Core，不运行 HTML 游戏，不执行 Authority 规则，也不负责
用户账号、计分、房间规则或游戏状态。

## 职责边界

```text
Go Server
  ├─ HTTP 基础设施
  │    Request ID / 日志 / CORS / 鉴权 / 限流 / 请求上限
  ├─ Catalog 与游戏包服务
  │    服务声明 / 列表与搜索 / 上传与校验 / 下载
  └─ Relay
       临时隧道 / Host Lease / Join Capability / 字节复制
```

三个层次不得混合：

- HTTP 中间件只处理通用请求上下文，不解释游戏包和隧道业务。
- Catalog 与游戏包服务只处理可发布包，不读取游戏运行数据，不参与联机会话。
- Relay 只处理隧道鉴权、配对、限制、超时和字节复制，不解析加密后的游戏内容。

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
GET /apps/download
```

公共中转由 [Relay 协议](../remote-game-relay.md) 定义：

```text
POST   /relay/v1/host
GET    /relay/v1/host
DELETE /relay/v1/host
GET    /relay/v1/client
```

App 外部端口提供：

```text
POST /api/public/upload
GET  /api/public/games
GET  /api/public/games/:id/download
GET  /api/public/source-qrcode
GET  /api/public/source-info
```

管理端口只提供：

```text
<ADMIN_PATH>/api/auth/captcha
<ADMIN_PATH>/api/auth/login
<ADMIN_PATH>/api/admin/**      全部要求管理员 Session
```

公开页面可以查询 `approved` 与 `pending` 元数据，但公开下载 Handler 必须再次校验
记录是 `approved`。隐藏按钮不是安全边界，待审核包即使被手工构造 URL 也不能从公开
下载接口获得。

外部 App 端口使用正式 Token 和待审核 Token 分流。正式 Token 只读取 `approved`；
待审核 Token 只读取 `pending`，并在返回 Manifest 的 `tags` 中追加 `待审核`。
`rejected` 永不进入 Catalog。

Catalog API、上传管理面和 Relay 协议分别评估版本。只修改其中一个领域时，不得
机械提升其他领域的版本。

## 游戏包存储约定

服务端只接受 Playmesh 可发布包：

```text
main.json
capabilities.json           可选
app/
```

以下内容不得进入共享包：

```text
data/
cache/
playmesh/
开发者本地历史
工作区 Token 或配置
原生可执行文件和危险扩展名
```

上传不能等同于解压覆盖目录。当前实现不执行上传内容，而是扫描原始 ZIP、流式读取
受限条目并保存通过检查的压缩包。实现必须：

1. 限制压缩包大小、展开后总大小、文件数量和单文件大小。
2. 拒绝绝对路径、目录穿越、符号链接和危险扩展名。
3. 校验 `main.json`、能力声明、入口和受支持的 SDK 版本。
4. 在临时目录完整校验，成功后原子替换；失败时保留旧版本。
5. 清理超时或失败的临时文件，并对同一游戏 ID 的并发写入串行化。
6. 列表、搜索和下载必须读取同一个已提交包存储，不能各自维护事实副本。

默认使用 ClamAV 执行跨平台病毒扫描。`scanner.required == true` 时，扫描器缺失、
超时、病毒库错误或非明确干净结果都必须拒绝上传。ClamAV 之外仍需执行活动内容
静态检查，至少覆盖外部 HTTP/WS 地址、本地文件协议、动态代码执行、Service
Worker 与嵌入文档元素。危险原包立即删除，扫描哈希、命中项和拒绝原因保存在
SQLite。

部署者可以通过 `.env` 的 `PLAYMESH_CLAMAV_ENABLED=false` 显式关闭 ClamAV。
该开关必须保持环境级只读，不能由管理 API 改写；关闭只跳过病毒签名扫描，不得关闭
ZIP 边界、扩展名、Manifest 或内容正则检查。公共生产源应保持默认开启。

活动内容规则由 `scanner.contentRules` 配置，每条包含稳定 ID、说明、正则、
适用扩展名和启用状态。后台保存和服务启动都必须编译校验全部正则，拒绝重复 ID、
无效表达式和不规范扩展名，并保证至少一条规则启用。ZIP 路径、展开大小、压缩比、
根目录和扩展名白名单属于不可被正则替代的代码级基线。

路径穿越必须在 ZIP 条目路径层按规范化结果阻断，不能用全局内容正则禁止 JavaScript
文本里的 `../`。包内模块和资源的相对导入属于正常内容；内容规则若要检查路径类风险，
必须绑定具体危险 API、协议或执行上下文。加载旧配置时只迁移删除项目曾发布的精确
`parent-path` 默认规则，不得静默删除部署者的其他自定义规则。

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

包 ID 是存储主键。覆盖、保留多版本或禁止重复必须由服务端配置和管理契约明确，
不能根据文件名猜测。下载端仍必须把远程包视为不可信输入并重新校验。

## 鉴权与访问控制

Source Token 由领域中间件处理，Handler 不自行比较 Token。独立 Go Server 的正式
Token 与待审核 Token 均不得为空；只有 App 本机局域网分享服务保留可选单 Token
语义。

- 匿名公开上传是受限例外：它只能创建 `pending` 记录，必须经过邮箱、严格限流、
  并发扫描上限和完整恶意包检查，不能覆盖、批准或删除游戏。管理员上传、状态修改
  和删除必须验证管理员 Session，不能进入 App Token 白名单。
- `/relay/v1/client` 可以免 Source Token，但仍必须校验限定隧道的 Join Capability。
- Host Lease 只允许管理创建它的隧道，不能替代全局 Source Token。
- 日志不得记录完整 Source Token、Host Lease、Join Capability、邀请 Token 或端点密钥。
- 生产部署应在反向代理或服务入口使用 HTTPS，并设置防火墙、请求速率和存储配额。

若未来引入账号或多租户，必须作为独立身份与授权层设计，不能把单个 Source Token
扩展成隐式用户系统。

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
- 端点内容密钥只存在于两端 App，不能进入 Go Server 请求、状态或日志。
- 配对完成后只执行有背压的双向复制，不缓存完整响应，不解释 HTTP 或 WebSocket。
- 主机退出、TTL 到期或显式删除时，回收隧道和全部关联连接。
- 全局隧道数、单 IP 连接数、单隧道连接数、待配对时间和空闲时间都必须有上限。
- Relay 在 Source Token、Lease 或 Capability 校验前也必须有允许正常连接池突发的
  IP 窗口限流，避免公开正式 Token 被用于高频鉴权消耗。

Relay 无法检查端到端加密内容是否属于游戏流量。Source Token、临时 Capability 和
官方 App 流程构成当前产品边界；如果需要对客户端进行密码学证明，应单独设计设备
证明或客户端证书，不能通过让中转持有内容密钥实现。

## 配置约定

`go-server/server.json` 是后台管理的非敏感运行配置持久化文件。管理员通过
`GET/PUT /api/admin/config` 的结构化表单读取和修改它，不要求部署者长期手工维护。
配置结构必须：

- 使用严格 JSON 解码，未知字段直接报错。
- 启动前完成全部范围、URL 和必填项校验。
- 对外地址使用显式 `publicBaseUrl`，不得从监听地址、请求 `Host` 或转发头猜测。
- `showPublicSourceQRCode` 默认开启。开启时公开门户由后端把 `publicBaseUrl`、
  正式发布 Token 与当前源名称编码为 `playmesh://catalog-source` 二维码；关闭时
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
- 所有写操作的鉴权、大小限制、限流和审计已启用。
- 隧道凭证按角色隔离，端点密钥从未到达服务端。
- 连接、临时文件和失败上传可以在超时或关闭时回收。
- `server.json` 示例不含生产秘密，公网地址与 TLS 终止配置一致。
- 版本日志分别记录已验证内容和仍需完成的公网、压力与故障恢复验证。
- 使用 `go.mod` 固定的已修复 Go 工具链完成 `go build`、`govulncheck` 与
  `gosec`；不得用存在已知标准库漏洞的旧工具链发布公网服务。
