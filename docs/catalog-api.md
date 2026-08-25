# Playmesh Catalog API 3.0.0

Catalog API 把本机或独立服务器上的游戏包公开为 Playmesh 游戏源。它与 Go Core、
游戏会话分享、Relay 和 Developer Gateway 相互独立；当前唯一受支持的契约版本为
`3.0.0`。

版本历史与当前破坏性边界：

- Catalog `2.0.0` 历史上引入单一 `publicURL`、每个游戏只列 latest offer、
  带 `gameId + version` 的下载、独立图标接口和上传能力声明；同时停止读取
  Catalog 1.x、旧 `{host, token}` 分离导入、`playmesh://catalog-source` 二维码、
  省略版本的“最新包”下载及旧源配置。
- Catalog `2.1.0` 历史上增加可选 `packageSizeBytes`，其余 2.0 规则保持不变。
- Catalog `3.0.0` 的 offer 和游戏 Manifest 入口统一相对于外层物理 `app/`，例如
  `index.html`、`controller/index.html`。安装后的外层物理目录仍是 `app/`，Web URL
  映射为 `/`；用户首段 `app` 合法，因此入口 `app/index.html` 对应物理
  `app/app/index.html` 和 URL `/app/index.html`，但不会把它别名到外层
  `app/index.html`。仅 `/playmesh/**` 与 `/bucket/**` 保留给平台。

App 对协议版本执行精确匹配，因此 2.x 源声明不会由 3.0 客户端转换或继续消费；
入口是否以 `app/` 开头不参与版本兼容判断。`main.json` 不定义 `icon` 或
`permissions`；只认游戏包根目录可选 `icon.png`，受保护能力只认同级
`capabilities.json`。

## publicURL 与鉴权

用户分享、复制、扫码和手工导入的唯一格式是：

```text
https://catalog.example.com?token=read-token
```

也可使用局域网 HTTP。URL 只允许一个可选 `token` 查询参数，路径必须为空或 `/`，
不得带 fragment 或其他查询参数。App 从 URL 解析出 Origin 和读取 Token，随后用：

```http
Authorization: Bearer read-token
```

请求 `/apps/**`。读取 Token 可以随源链接分享；上传密钥绝不能进入 publicURL、
二维码、Catalog 响应、JavaScript、日志或错误详情。

扫码和手工输入必须调用同一导入函数。保存前 App 必须成功请求 `/apps/info`，
验证 HTTP 200、JSON、`catalogApiVersion == "3.0.0"` 以及 Relay/上传能力内部一致；
失败时不得写入配置。

## `/apps/info`

```http
GET /apps/info
Authorization: Bearer optional-read-token
```

示例：

```json
{
  "catalogApiVersion": "3.0.0",
  "name": "Playmesh 公共游戏源",
  "author": "Source Builder",
  "homepage": "https://example.com",
  "supportsGameRelay": true,
  "relay": {
    "protocolVersion": "3.0.0",
    "transport": "playmesh-tcp-upgrade",
    "publicBaseUrl": "https://relay.example.com",
    "hostPath": "/relay/v1/host",
    "clientPath": "/relay/v1/client",
    "maxConnectionsPerTunnel": 64
  },
  "userUpload": {
    "supported": true,
    "protocolVersion": "1.0.0",
    "path": "/api/user/uploads",
    "maxUploadBytes": 67108864
  }
}
```

规则：

- `name` 是源官方名称，只在源详情辅助展示，不能覆盖用户维护的本地源名称。
- `author` 的界面标签是“建造者”；游戏 Manifest 的 `author` 标签是“发布者”。
- `supportsGameRelay` 与 `relay` 必须同时成立或同时不存在。
- `userUpload` 为必填对象；`supported=false` 时不得带协议、路径或大小字段。
- 所有协议版本使用严格 `MAJOR.MINOR.PATCH`。
- `publicBaseUrl` 只能是 HTTP/HTTPS Origin；端点路径由声明提供。

App 自带的只读分享源固定声明：

```json
{
  "catalogApiVersion": "3.0.0",
  "name": "{用户昵称}的游戏库",
  "author": "Playmesh App",
  "supportsGameRelay": false,
  "userUpload": { "supported": false }
}
```

## `/apps/list`

```http
GET /apps/list?page=1&size=10&s_name=星海&s_tag=party&s_desc=竞速
Authorization: Bearer optional-read-token
```

- `page` 从 1 开始，默认 1。
- `size` 默认 10，范围 1–100。
- 三个 `s_*` 参数分别匹配名称、任一标签和描述。
- 每个源对同一 gameId 最多返回该源当前最新版本一个 offer。
- Go Server 只选择语义版本最高的 `approved + published` 记录；若最新 approved
  版本已下架，不回退历史版本。

响应：

```json
{
  "total": 1,
  "current": 1,
  "size": 10,
  "data": [
    {
      "id": "com.example.game",
      "name": "示例游戏",
      "remarks": "游戏描述",
      "author": "发布者名称",
      "version": "2.0.0",
      "sdkVersion": "4.1.0",
      "appSdkVersion": "3.3.0",
      "orientation": "landscape",
      "modes": ["multiplayer"],
      "displayModes": ["multi_screen"],
      "players": { "min": 2, "max": 5 },
      "entries": { "game": "index.html" },
      "tags": ["party"],
      "packageSizeBytes": 73400320,
      "icon": "https://catalog.example.com/apps/icon?id=com.example.game&version=2.0.0"
    }
  ]
}
```

`icon` 可选，必须与源 Origin 同源。App 拒绝跨源图片，并在加载、解码或大小校验
失败时显示平台默认图标。

`entries.game` 对所有游戏显式必填；`entries.controller` 对
`single_screen_multiplayer` 显式必填；`authority.entry` 对 `multiplayer` 显式
必填。三者都相对于下载包外层物理 `app/`，缺失时不回退模板路径。它们不得带前导
`/`、查询、fragment、反斜线、外部 URL、`.`/`..` 段，也不得以不区分大小写的
`playmesh` 或 `bucket` 作为首段。`app` 是普通合法首段，并解析到外层物理 `app/`
内的同名子目录。Catalog 不重写入口，客户端在安装前按同一规则校验。

`packageSizeBytes` 使用 ZIP 的实际字节数，是 Catalog `2.1.0` 引入并在 3.0
继续保留的可选正整数字段。Go
Server 在接收并规范化游戏包时写入数据库，后续列表直接读取，不在每次请求时重新
读取文件。App 临时局域网分发源按需生成 ZIP，可以在列表中省略该字段；客户端下载
收到响应头后使用准确的 `Content-Length` 补充总大小。

## `/apps/icon`

```http
GET /apps/icon?id=com.example.game&version=2.0.0
Authorization: Bearer optional-read-token
```

仅返回该源当前公开版本的根 `icon.png`。安全边界为：

- PNG 签名、chunk、CRC 和解压结构有效。
- 压缩文件不超过 2 MiB。
- 宽高各不超过 8192，像素总数不超过 4M。
- 解码预算不超过 32 MiB。

不存在、无效、历史版本或已下架版本返回 404。

## `/apps/download`

```http
GET /apps/download?id=com.example.game&version=2.0.0
Authorization: Bearer optional-read-token
```

`id` 与严格三段式 `version` 都是必填项。成功返回 `application/zip`，并应携带准确
的 `Content-Length`；文件名为
`游戏名称-v游戏版本.zip`。包只包含：

```text
main.json
capabilities.json  # 可选
icon.png           # 可选
app/
```

历史版本、已下架版本和不存在的版本返回 404，不允许回退。客户端仍将内容视为不可信
输入，执行压缩/展开大小、条目数量、路径穿越、危险扩展名、Manifest、SDK、能力、
图标和入口校验后，才原子替换程序文件；`data/`、`cache/` 与本地使用统计不随升级删除。

## 用户上传声明

支持上传的源通过 `/apps/info.userUpload` 声明协议。App 发布请求：

```http
POST {origin}{userUpload.path}
Authorization: UploadKey account-upload-key
Content-Type: multipart/form-data

package=<zip>
```

上传密钥必须使用 `UploadKey` scheme，不接受 Bearer 别名。客户端：

- 只把“启用 + 支持上传 + 已配置上传密钥”的源列为候选。
- 保存项目后跳过项目语义校验，只生成一次宽松临时 ZIP；路径、容量、符号链接和生成上传
  请求所需的基础 Manifest 元数据边界仍保留。项目校验 Operation、既有 AI 提示、本地
  运行和重新导入不随发布路径放宽。
- 对选中源独立发起请求，30 秒超时，逐源展示结果并允许只重试失败源。
- 限制错误响应读取上限，不把凭据写入日志。
- 无论全成功、部分成功或异常都清理临时包。

Go Server 按账号 ID 管理 gameId 所有权，并要求新版本严格高于数据库中该 gameId
当前最高版本。首次有效上传在同一事务取得所有权；冲突或版本不递增返回 409 且不
留下包、版本或所有权残留。接收端不对 `app/` 内其他资源使用扩展名或文件类型白名单；
只读取 `main.json.entries.game` 声明的 `.html` 首页，去掉可选查询串后确认对应物理文件
是非空、合法 UTF-8、无 NUL 的网页文本。

## App 源配置 v2

源配置只保存本地字段和上次探测结果：

- `enabled`
- `showOnHome`
- `name`（本地源名称）
- `publicURL` 拆出的 Origin/读取 Token
- `uploadKey`（仅本机私密存储）
- 最近验证时间、错误和只读声明快照

新源默认启用并在首页展示；本地名称首次取官方名称，之后独立维护。分享源时只生成
publicURL，不包含上传密钥。

在线游戏库行为：

- 首页只请求 `enabled && showOnHome`，一个源一个独立区域，不跨源去重。
- 搜索请求全部启用源，按 `gameId + author.trim()` 聚合；发布者为空时以 sourceId
  隔离。
- 每个源只贡献自己的当前最新版本；版本下保留全部原始 offer。
- 一级结果按本机 `launchCount`、最近打开时间、最高版本、名称和 groupKey 稳定排序。
- 下载任务键为 `sourceId + gameId + version`。
- 每次进入本地库后台检查同 gameId、同发布者的更高版本；安装前再次校验，避免竞态。

## 安全与缓存

- 所有响应带 `X-Playmesh-Catalog-Version: 3.0.0`。
- 读取 Token 只提供 Catalog 读取能力，不能代替防火墙或可信网络边界。
- App 自带源绑定 `0.0.0.0`，默认关闭，不支持用户上传或 Relay。
- Catalog 导出使用流式 ZIP、串行任务和专用临时目录；启动、操作前和完成后清理。
- 源声明、图标、列表和下载不得泄漏上传密钥、管理员路径、会话 Cookie或待审核凭据。

Go Server 的账号、审核、上下架、删除和部署规则见
[Go Server 开发约定](platform/go-server-development.md)，包边界见
[游戏包格式](game/package-format.md)。
