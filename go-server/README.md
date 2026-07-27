# Playmesh Go Server

Go Server 是 Playmesh 可独立部署的轻量游戏包平台与公共联机中转。它使用 Gin
提供两个相互隔离的 HTTP 入口：

- App 外部端口：提供公开游戏门户、用户上传、Catalog、下载与 Relay。
- 管理端口：只提供隐藏路径下的管理员登录、审核 CRUD、设置与负载面板。

Go Server 不是 Go Core，不运行游戏规则，也无法解密公共中转中的端到端内容。

## 启动

1. 安装 Go 1.26.5 或更高的已修复版本；`go.mod` 已固定安全工具链。
2. 按 [ClamAV 官方安装文档](https://docs.clamav.net/manual/Installing.html)
   安装并更新病毒库。Windows、Linux 与 macOS 均可使用官方发行包。
3. 复制 `.env.example` 为 `.env`，替换管理员密码、App Token 与上传密钥 Pepper。
4. 启动：

```powershell
go run .
```

默认地址：

```text
公开门户 / App / Catalog / Relay  http://0.0.0.0:16668
管理后台                         http://127.0.0.1:16669<PLAYMESH_ADMIN_PATH>
```

手机访问公开门户时，请使用服务器在当前局域网可达的 IP，例如
`http://192.168.1.20:16668`，不能使用手机自身的 `127.0.0.1`。同时在后台把
`publicBaseUrl` 设置为该局域网地址或生产 HTTPS 域名，否则二维码中的地址只对服务
器本机有效。公开页面和管理页面均采用移动端响应式布局；如确需从手机管理，应只在
可信管理网络把 `admin.listen` 改为可达地址，并配合防火墙限制来源。

生产环境应把管理端口绑定到回环或独立管理网络；不要把它与外部端口映射到同一公网
入口。

`server.json` 是后台管理的运行配置持久化文件，不要求部署者长期手工编辑。首次
启动使用仓库中的安全默认模板；登录后台“运行配置”后，可通过结构化表单修改端口、
SQLite 路径、游戏包限制、验证码、ClamAV、鉴权白名单和 Relay 参数。后台先验证
完整配置，再以临时文件原子替换 `server.json`。

内容扫描规则、ClamAV 路径/策略和 `publicBaseUrl` 在保存后立即热更新；
`/apps/info` 明确使用 `no-store` 并立即返回新地址。监听端口、数据库路径和 Relay
容量/超时等运行级配置不能在保留现有连接的同时安全热切换，因此后台保存后会明确
提示重启生效。游戏源名称、作者、主页与 Relay 声明使用独立表单和 SQLite 存储，
可以即时反映到 `/apps/info`。

Web 语言与主题由 `server.json.webUI` 配置。可用语言只来自仓库统一清单
`assets/playmesh-localization/manifest.json`；发布前运行
`node tool/generate_localization.mjs` 更新 Go 嵌入副本。服务启动会拒绝未知 locale、
未启用默认语言、词典 key 漂移、回退环和非法主题模式。UI 词典通过 `/i18n/**`
提供，`/api/**` 与 `/apps/**` 不读取 locale，JSON 契约不会随界面语言改变。
用户页和管理页的 HTML 壳不内嵌固定文案或本地化属性 fallback；首帧在统一
`go-server.json` bundle 投影完成前保持隐藏。Playmesh、ClamAV、URL 示例等技术值
可以保留原样，动态游戏名、账号和 API 数据从不进入词典。

## Token、账号与游戏可见性

`.env` 中必须配置两个不同 Token：

```text
PLAYMESH_PUBLISHED_TOKEN  正式游戏 Token
PLAYMESH_REVIEW_TOKEN     Relay/管理兼容凭据，不进入 Catalog 展示
PLAYMESH_UPLOAD_KEY_PEPPER 用户上传密钥 HMAC Pepper
```

两个 Token 必须非空且互不相同，不能使用示例占位值或复用其他凭据。

外部端口使用统一 Gin 中间件解析 Bearer Token：

- `/apps/list` 每个 gameId 只返回语义版本最高的 `approved + published` 记录。
- 最新 approved 版本下架后不回退历史版本。
- `/apps/download` 与 `/apps/icon` 必须指定同一个当前公开版本。
- `pending`、`rejected` 与历史 approved 版本不进入任何 App Catalog。
- `auth.whitelist` 是精确的 `{method, path}` 白名单；命中后跳过 App Token。
- Relay Client 即使在 Token 白名单中，仍必须通过 Join Capability 鉴权。

用户使用邮箱账号登录门户；App/工作区使用每账号独立上传密钥。上传密钥只保存
HMAC-SHA256，明文只在创建或轮换时返回一次。`allowUserRegistration` 关闭后注册
接口返回 `403 registration_disabled`，已有用户登录、验证、上传和游戏管理不受影响。
注册成功和重复注册统一返回 `202 {"status":"registration_received"}`，客户端只根据
公开的邮箱验证开关提示下一步，不通过响应判断邮箱是否已存在。
上传客户端固定使用 `Authorization: UploadKey <upload-key>`，不接受 Bearer 别名；
ZIP 使用 multipart 的 `package` 字段。

## 管理端

管理后台入口只从 `.env` 读取，不写入 `server.json`，公开门户也不显示跳转按钮：

```text
PLAYMESH_ADMIN_PATH=/manage-replace-with-a-long-random-path
```

从配置文件启动时必须显式设置该变量；默认 `/admin` 会被拒绝。路径必须非空、
不可预测且不与 `/api`、`/assets`、`/health` 冲突。管理 HTML、脚本、验证码、
登录和全部后台 API 都位于该路径下，不再暴露固定 `/api/auth`、`/api/admin` 或
后台静态资源入口。隐藏入口只是纵深防御，所有管理员接口仍强制验证 Bearer Session。

登录使用 `.env` 中的管理员账号密码。密码可以是非空明文，也可以是 bcrypt
哈希。验证码图像不由项目自绘：数字计算模式使用 Apache-2.0 的
[`mojocn/base64Captcha`](https://github.com/mojocn/base64Captcha)，文字点选模式使用
Apache-2.0 的 [`wenlng/go-captcha/v2`](https://github.com/wenlng/go-captcha) 及其
官方嵌入资源。验证码模式在 `server.json` 中配置：

```json
{ "captchaMode": "math" }
```

或：

```json
{ "captchaMode": "text" }
```

`GET <ADMIN_PATH>/api/auth/captcha` 只返回不透明 ID、模式、图像和点选次数；不返回算式文本、
答案、候选字符或目标坐标。算术答案和文字目标点只保存在后端，文字模式由前端按
提示缩略图提交主图坐标，再使用开源库的区域校验；验证码两分钟过期且无论成功失败
只消费一次。

验证码与登录接口分别按客户端 IP 限流，默认每秒一次。除验证码和登录外，
`/api/admin/**` 的每一个接口都必须携带管理员 Bearer Session。

主要接口：

```text
GET    <ADMIN_PATH>/api/auth/captcha
POST   <ADMIN_PATH>/api/auth/login

POST   <ADMIN_PATH>/api/admin/logout
GET    <ADMIN_PATH>/api/admin/games
GET    <ADMIN_PATH>/api/admin/games/:id
PATCH  <ADMIN_PATH>/api/admin/games/:id
DELETE <ADMIN_PATH>/api/admin/games/:id
POST   <ADMIN_PATH>/api/admin/games/:id/publish
POST   <ADMIN_PATH>/api/admin/games/:id/unpublish
GET    <ADMIN_PATH>/api/admin/games/:id/download
GET    <ADMIN_PATH>/api/admin/settings
PUT    <ADMIN_PATH>/api/admin/settings
GET    <ADMIN_PATH>/api/admin/config
PUT    <ADMIN_PATH>/api/admin/config
GET    <ADMIN_PATH>/api/admin/relay/stats
```

管理员可以分页、搜索、查看扫描报告、下载服务端覆盖发布者信息后的干净包、通过、
拒绝、上下架或删除记录，通过表单编辑 `/apps/info`，并通过“运行配置”表单管理
`server.json`。

## 公开门户

App 外部端口的 `/` 是游戏源与用户门户：

- 匿名用户只浏览每个 gameId 当前公开的最新版本。
- 注册用户登录后管理展示名称、上传密钥、版本审核状态和上架状态。
- 网页上传使用 HttpOnly/Secure/SameSite=Lax 会话 Cookie 与 Secure CSRF Cookie，
  所有写操作同时校验会话绑定的 CSRF Token。Cookie 始终带 Secure，因此匿名
  Catalog 可继续通过纯 HTTP 浏览，但账号登录和用户门户必须部署在 HTTPS 上。
- App 上传与网页上传共用同一 IP 的 30 秒窗口；限流发生在读取请求体之前，
  `Retry-After` 返回当前窗口的剩余整秒。两个入口共享所有权和严格递增版本事务。
- 默认显示“快速添加当前游戏源”二维码；管理员可通过
  `showPublicSourceQRCode` 开关隐藏。二维码由后端使用 `publicBaseUrl`、正式发布
  Token 生成唯一的 `publicURL?token=...` 链接；二维码和复制文本逐字一致。

公开 API 使用独立的严格 IP 限流：

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

源二维码面向匿名用户分发，因此其中的正式发布 Token 应被视为公开的只读源凭据，
不能复用管理员密码、待审核 Token 或其他高权限秘密。

首页通过 `/api/public/source-info` 返回唯一的 `publicURL?token=...`。该接口与
二维码具有相同的公开只读凭据边界，不返回上传密钥、待审核 Token 或管理员路径。

## 上传安全模型

所有上传文件按恶意输入处理：

1. 使用服务端随机文件名写入非 Web Root 隔离目录。
2. 限制请求大小、ZIP 文件数量、单文件大小、展开总大小和压缩比。
3. 拒绝绝对路径、目录穿越、反斜杠路径、隐藏文件、大小写冲突路径、Windows
   设备名、符号链接、特殊文件、重复路径和加密 ZIP 条目。
4. 只允许 `main.json`、可选 `capabilities.json`、可选根 `icon.png` 与 `app/`，并使用 Web 资源扩展名
   白名单。
5. 使用 ClamAV 扫描原始 ZIP；默认扫描器缺失、超时或报错都会拒绝上传。
6. 静态检查 HTML、JavaScript、CSS 与 SVG 中的外部 HTTP/WS 地址、`file:`、
   `javascript:`、动态代码执行、Service Worker 和嵌入文档元素。
7. 完整校验 `main.json` 后才把原包原子写入游戏包目录；`id` 只接受 1–64 个
   安全字符。解析器对所有未知字段一律静默忽略，不产生 finding、告警、错误或兼容
   分支；规范化使用当前已知 Manifest 字段投影，因此数据库和 ZIP 中统一丢弃所有
   未知字段。`permissions`、`icon` 只是普通未知键；能力只读取独立
   `capabilities.json`，图标只读取包根 `icon.png`。
8. 敏感或感染文件立即删除，不创建版本、所有权或审核记录。
9. 并发扫描数默认限制为 4；可在后台通过 `maxConcurrentScans` 调整。
10. 下载和删除时把 SQLite 路径重新视为不可信值，解析符号链接并强制目标仍是
    游戏包目录中的常规 ZIP；持久化写入使用目录范围文件 API。

版本删除先在 SQLite 事务中标记为 `deleting` 并写入审计，再删除 ZIP、图标和派生
文件，最后在第二个事务中删除版本记录并在必要时释放 gameId 所有权。`deleting`
不会进入 Catalog、公开下载或用户门户；启动时会立即重试未完成清理，运行期间也会
每 30 秒继续清理，文件暂时被占用或数据库瞬时失败不会恢复公开状态。

同一后台任务还会执行数据库引用安全扫描：只清理由服务端命名规则明确识别、且没有被
任何版本记录引用的游戏目录文件，以及隔离目录中的 `upload-*` / `normalized-*`
临时 ZIP。用户或运维自行放置的文件、目录、符号链接和不符合服务端命名规则的内容
不会被扫描器删除。上传冲突或失败时若即时删除失败，错误会被记录并由启动任务及每
30 秒的后台任务持续重试。

ClamAV 是纵深防御的一层，不替代 ZIP 边界、扩展名白名单和静态分析。生产环境应让
ClamAV 使用低权限服务账号，并定期通过 `freshclam` 更新签名库。

无法安装 ClamAV 的开发或受控内网环境可以在 `.env` 显式关闭：

```text
PLAYMESH_CLAMAV_ENABLED=false
```

该开关默认 `true`，只从 `.env` 读取，不允许通过后台远程修改。关闭后上传仍会执行
ZIP 路径、文件类型、大小、压缩比、Manifest 和内容正则检查，但缺少病毒签名扫描，
因此不建议用于公共生产游戏源。

活动内容正则不硬编码在扫描器中。后台“运行配置”以规则数组维护：

```json
{
  "id": "external-http-ws",
  "description": "外部 HTTP/WS 地址",
  "pattern": "(?i)(?:https?|wss?)://",
  "extensions": [".html", ".js"],
  "enabled": true
}
```

`extensions` 为空表示应用于全部活动文本。保存和启动时会编译每条规则并拒绝无效
正则、重复 ID 或不规范扩展名；至少必须保留一条启用规则。后续新增风险只需在后台
增加规则并安全重启，不需要修改 Go 源码。

ZIP 条目路径穿越由归档路径校验直接阻断，不使用内容正则扫描 JavaScript 文本中的
`../`。这是因为 `import "../service/index.js"`、`fetch("../data.json")` 等是包内
合法相对引用；旧版本默认的 `parent-path` 宽泛规则会在启动时自动迁移移除。若部署
者需要新增路径类内容规则，应限定具体危险 API 与调用上下文，避免重新引入这一误报。

## SQLite

服务端使用无 CGO 的 `modernc.org/sqlite`。默认数据库：

```text
data/playmesh-server.db
```

数据库保存：

- 游戏包、上传者邮箱、状态与 Manifest 摘要。
- 病毒扫描和静态检测报告。
- 审核、上架、下架、删除和设置变更事件；每条事件包含稳定账号标识、角色、
  gameId/版本、前后状态与时间。
- `/apps/info` 可编辑设置。
- 只存哈希的管理员 Session。

游戏 ZIP 保存在数据库外的受控目录，SQLite 只保存服务端生成的路径。

当前 SQLite schema 版本为 3。服务端采用破坏式 schema 边界，不执行旧数据库迁移；
版本不匹配时会拒绝启动，部署者应备份后创建全新数据库。

## 邮件

SMTP 在 `.env` 配置。启用邮箱验证后用于发送一次性验证链接；管理员审核也可向
上传账号发送结果。审核结果先写入 SQLite，邮件发送失败不会回滚审核事务。
验证邮件重发在同一 SQLite 写事务中检查 60 秒间隔和每小时 5 次上限、作废旧
Token 并预留新 Token；来自不同 IP 的并发请求也只有一个请求能取得有效链接。

隐式 TLS SMTP 使用：

```text
PLAYMESH_SMTP_TLS=true
```

`false` 表示普通 SMTP，不会自动升级 STARTTLS。生产环境应优先使用隐式 TLS 和
专用发信账号。连接、读写均有超时，邮件服务器异常不会无限挂住审核请求。

## 发布前安全检查

项目要求使用 Go 1.26.5 或更高安全补丁版本。发布前至少执行：

```powershell
go build ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 -show verbose ./...
go run github.com/securego/gosec/v2/cmd/gosec@v2.25.0 -exclude-generated ./...
```

`auth.whitelist` 只允许精确的只读 Catalog/Relay Client 路径，不能把上传、Relay
Host 创建或任何管理员接口加入免鉴权列表。

## 公开协议

- [Catalog API](../docs/catalog-api.md)
- [公共联机中转](../docs/remote-game-relay.md)
- [Go Server 平台开发约定](../docs/platform/go-server-development.md)
- [ClamAV 官方安装文档](https://docs.clamav.net/manual/Installing.html)
- [OWASP 文件上传安全清单](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)
