# Playmesh 在线游戏源与 Catalog API

Catalog API 用于把当前设备已安装的 Playmesh 游戏包作为局域网游戏源分享，也为在线游戏源声明公共联机中转能力。它与 Go Core、游戏会话分享和 Developer Gateway 相互独立，当前契约版本为 `1.4.0`。

## 本机分享设置

设置页提供“分享本机游戏库”：

- 开关默认关闭，关闭或 App 退出时停止监听。
- 默认端口 `16668`，可配置为 `1` 至 `65535`。
- Token 可留空；留空时不鉴权，非空时所有 `/apps/*` 请求必须携带 `Authorization: Bearer <token>`。
- 开关、端口和 Token 持久化到 `playmesh-library/catalog/settings.json`。
- 开启后显示全部可用局域网地址、二维码和可复制的游戏源配置。

所有响应包含 `X-Playmesh-Catalog-Version: 1.4.0`。服务绑定 `0.0.0.0`，只应在可信局域网中启用；Token 不能替代系统防火墙或可信网络边界。

独立部署的 Go Server 使用两个不同的 App Token，而不是本机分享服务的单个可选
Token：

- 正式发布 Token 只返回 `approved` 游戏。
- 待审核 Token 只返回 `pending` 游戏，并在每个 Manifest 的 `tags` 中追加
  `待审核` 临时标签。
- `rejected` 游戏不会通过 Catalog 返回。

两个 Token 均由 `.env` 提供。Gin 鉴权中间件按 `server.json` 中精确的
`{method, path}` 白名单跳过 Token；业务 Handler 不自行实现白名单。

## 游戏源声明

```http
GET /apps/info
Authorization: Bearer optional-token
```

支持公共联机中转的游戏源返回：

```json
{
  "catalogApiVersion": "1.4.0",
  "name": "Playmesh 公共游戏源",
  "author": "可选作者",
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

`name`、`author`、`homepage` 可选；名称缺失时显示格式化后的 `host:port`，
HTTP 80 与 HTTPS 443 省略端口。`supportsGameRelay` 为 `true` 时必须返回
`relay`，为 `false` 时不得返回 `relay`。`publicBaseUrl` 由 Go Server 配置并返回，
只能包含 `http`/`https` 协议、主机和可选端口；App 必须以它作为中转连接及
二维码的 Host 前缀，不能再用游戏源 Host 推导。`hostPath`、`clientPath` 由
App 拼接到该 Origin。`publicBaseUrl` 使用 HTTPS 即启用外层 TLS，使用 HTTP
即不启用；不再提供独立 TLS 策略字段。端点间的内容加密始终存在，与外层 TLS
是否开启无关。`maxConnectionsPerTunnel` 由 Go Server 从当前 Relay 配置返回，
是 App 主机动态连接池的总上限；App 不复制或猜测该服务器配置，只维持最多 4 条
热连接，并在热连接被配对时按需补充。最终容量和限流仍由 Go Server 执行。

App 自带的游戏库分享服务器永远不提供公共中转，声明固定为：

```json
{
  "catalogApiVersion": "1.4.0",
  "name": "{用户昵称}的游戏库",
  "supportsGameRelay": false
}
```

该名称不可由用户另行配置，也不返回作者、主页或 `relay`。

## 分页搜索游戏

```http
GET /apps/list?size=10&page=1&s_name=星海&s_tag=party&s_desc=竞速
Authorization: Bearer optional-token
```

参数：

- `page`：从 `1` 开始，默认 `1`。
- `size`：每页数量，默认 `10`，范围 `1` 至 `100`。
- `s_name`：名称包含搜索，不区分大小写。
- `s_tag`：任一标签包含搜索，不区分大小写。
- `s_desc`：描述包含搜索，不区分大小写。

响应：

```json
{
  "total": 100,
  "current": 1,
  "size": 10,
  "data": [
    {
      "id": "com.example.game",
      "name": "示例游戏",
      "remarks": "游戏描述",
      "version": "1.0.0",
      "sdkVersion": "1.4.2",
      "appSdkVersion": "2.0.0",
      "orientation": "landscape",
      "modes": ["multiplayer"],
      "displayModes": ["multi_screen"],
      "players": { "min": 2, "max": 5 },
      "entries": {
        "game": "app/index.html",
        "controller": "app/controller/index.html"
      },
      "authority": { "entry": "app/static/js/service/index.js" },
      "permissions": [],
      "tags": ["party"]
    }
  ]
}
```

`data` 返回当前 `GameManifest` 的全部字段。服务每次请求重新扫描本机游戏库，不分享内置资源、`data/`、`cache/`、安装元数据或其他私有文件。

## 下载游戏包

```http
GET /apps/download?id=com.example.game
Authorization: Bearer optional-token
```

成功返回 `application/zip`，内容只包含根目录 `main.json`、可选 `capabilities.json` 与 `app/`。找不到游戏返回 `404`，Token 错误返回 `401`。接收端不能直接信任下载内容，必须继续经过 Playmesh 的压缩大小、展开大小、文件数量、目录穿越、危险扩展名、Manifest、能力声明和必需入口校验后才能原子安装。

## 服务端上传与分享

`/apps/info`、`/apps/list` 和 `/apps/download` 是供 Playmesh 客户端读取的 Catalog
契约。轻量 Go Server 还可以提供游戏包上传与管理面，使团队或公共游戏源能够接收、
校验、保存并分享游戏包。

上传管理面不属于匿名 Catalog 读取协议，具体方法和路径以当前服务端管理契约为准；
客户端和文档不得根据下载路径猜测上传路径。服务端实现必须：

- 对写操作启用鉴权、请求大小限制、限流和审计。
- 只接受 `main.json`、可选 `capabilities.json` 与 `app/`。
- 在临时目录完成压缩包、路径、Manifest、能力、入口和 SDK 版本校验。
- 校验成功后原子提交；失败时保留旧包并清理临时文件。
- 让上传、列表、搜索和下载读取同一个已提交包存储。
- 让下载端继续执行完整的不可信包校验，不能因来源是 Go Server 而跳过。

服务端内部结构、覆盖策略、配置与 Relay 隔离规则见
[Go Server 开发约定](platform/go-server-development.md)。

Go Server 的公开门户与 App Catalog 位于同一个外部监听；管理监听只承载安全路径
下的管理员功能。用户可以浏览已通过和待审核游戏并提交带
邮箱的 ZIP；待审核游戏只展示元数据，不提供下载链接，公开下载 Handler 也会强制
校验 `approved`。这不影响持有待审核 App Token 的审核客户端通过外部 Catalog
下载待审核包。平台默认显示快速添加当前源的二维码，由后端将显式
`publicBaseUrl`、正式发布 Token 和当前源名称编码为
`playmesh://catalog-source`；管理员可通过 `showPublicSourceQRCode` 关闭，关闭后
公开二维码端点返回 404。二维码公开分发的正式 Token 只能承担已发布游戏的只读访问。
公开首页同时显示浏览器当前访问地址、配置的 `publicBaseUrl` 与正式 Token，并提供
复制按钮供用户手动添加；待审核 Token 不会通过该页面或公开信息接口返回。

## 在线游戏库

在线游戏库可以持久化多个 `{host, token}` 源：

- 每个源可以单独启用、禁用、编辑、删除和分享。
- 手动添加支持 HTTP/HTTPS Host；扫码添加使用 `playmesh://catalog-source` 配置二维码，同时携带 Host、可选 Token 和显示名称。
- 每次进入和搜索会并发请求全部启用源，再按 `GameManifest.id` 去重；源顺序靠前的同 ID 游戏优先展示。
- 默认每个源请求 `5` 个游戏，可配置为 `1` 至 `100`。
- 单个源失败不取消其他源结果，界面会提示部分源不可用。

游戏分享弹窗中的“服务器”页签复用这些已启用源。App 并发请求各源
`/apps/info`，只显示 `supportsGameRelay == true` 的源，并按本次请求耗时展示
最新延迟；列表支持搜索和每页 5 项分页。游戏源列表延迟不是玩家会话 RTT。

在线结果支持多选下载。下载队列按顺序处理任务，显示等待、下载进度、已安装、已停止和失败状态；等待或下载中的任务可以停止，任意任务可以从队列删除。下载临时文件完成导入后立即删除，App 退出时先取消活动请求并等待队列结束，再释放资源。
