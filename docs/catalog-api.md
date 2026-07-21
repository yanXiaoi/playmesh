# Playmesh 在线游戏源与 Catalog API

Catalog API 用于把当前设备已安装的 Playmesh 游戏包作为局域网游戏源分享。它与 Go Core、游戏会话分享和 Developer Gateway 相互独立，当前契约版本为 `1.1.0`。

## 本机分享设置

设置页提供“分享本机游戏库”：

- 开关默认关闭，关闭或 App 退出时停止监听。
- 默认端口 `16668`，可配置为 `1` 至 `65535`。
- Token 可留空；留空时不鉴权，非空时所有 `/apps/*` 请求必须携带 `Authorization: Bearer <token>`。
- 开关、端口和 Token 持久化到 `playmesh-library/catalog/settings.json`。
- 开启后显示全部可用局域网地址、二维码和可复制的游戏源配置。

所有响应包含 `X-Playmesh-Catalog-Version: 1.1.0`。服务绑定 `0.0.0.0`，只应在可信局域网中启用；Token 不能替代系统防火墙或可信网络边界。

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
      "sdkVersion": "1.3.0",
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

## 在线游戏库

在线游戏库可以持久化多个 `{host, token}` 源：

- 每个源可以单独启用、禁用、编辑、删除和分享。
- 手动添加支持 HTTP/HTTPS Host；扫码添加使用 `playmesh://catalog-source` 配置二维码，同时携带 Host、可选 Token 和显示名称。
- 每次进入和搜索会并发请求全部启用源，再按 `GameManifest.id` 去重；源顺序靠前的同 ID 游戏优先展示。
- 默认每个源请求 `5` 个游戏，可配置为 `1` 至 `100`。
- 单个源失败不取消其他源结果，界面会提示部分源不可用。

在线结果支持多选下载。下载队列按顺序处理任务，显示等待、下载进度、已安装、已停止和失败状态；等待或下载中的任务可以停止，任意任务可以从队列删除。下载临时文件完成导入后立即删除，App 退出时先取消活动请求并等待队列结束，再释放资源。
