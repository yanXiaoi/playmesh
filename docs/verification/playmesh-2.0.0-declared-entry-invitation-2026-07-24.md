# Playmesh 2.0.0 声明入口邀请验证

## 验证范围

本次验证收口局域网与公共中转邀请的页面入口规则：

- 局域网 HTML 链接保留 `main.json.entries.game` 或
  `main.json.entries.controller` 解析出的实际 `/app/**` HTML 入口。
- 普通浏览器直接打开 Authority 局域网链接。
- 局域网 App 解析同一链接，只把 Origin 改为本机回环地址，入口路径和
  `channelId + token` 保持不变。
- 公共邀请继续使用 `/j/{tunnelId}#inviteToken=...`；`/j/**` 只是 App 邀请
  标识，不是页面根路径。实际 `/app/**` 入口和 `channelId` 只封装在 fragment
  邀请令牌中，由 App 恢复到本机回环 Origin。
- Go Server 没有收到 `inviteToken`、Authority 分享 Token、页面入口或端点密钥，
  仍只负责临时隧道鉴权、配对和密文字节转发。

局域网链接示例：

```text
http://192.168.1.10:8080/app/index.html?channelId=...&token=...
http://192.168.1.10:8080/app/controller/index.html?channelId=...&token=...
```

公共邀请示例：

```text
https://relay.example/j/{tunnelId}#inviteToken={opaqueToken}
```

App 解包后的本地页面示例：

```text
http://127.0.0.1:{localPort}/app/controller/index.html?channelId=...&token=...
```

因此页面内的绝对路径 `/app/**`、`/bucket/**`、`/playmesh/**` 和受控 Upgrade
都从本地回环 Origin 解析，不会被拼接为 `/j/{tunnelId}/app/**`。

## 自动验证

所有命令按 `docs/04-dev-env.md` 使用固定工具链并在沙箱外串行执行。

| 验证 | 结果 |
| --- | --- |
| 本次 8 个 Dart 文件格式化 | 通过 |
| `flutter analyze --no-pub lib test` | 通过，无问题 |
| 邀请解析、局域网透明代理、Authority、公共中转、Catalog 与导航组合测试 | 通过，28 项 |
| `flutter test --no-pub` | 通过，164 项 |
| `go test ./...`（`go-server`） | 通过 |
| `git diff --check` | 通过；仅有现有行尾转换提示 |

定向测试包含：

- 游戏主页、控制器主页和自定义嵌套入口均原样进入局域网分享 URL。
- 局域网 App 能解析相同 `/app/**` URL。
- 旧 `/playmesh/join` 页面别名不再公开。
- 公共 `/j/**` 邀请解包后恢复真实 `/app/**` 本地入口。
- `inviteToken` 未进入模拟 Go Server 观察到的任何 HTTP 或 Upgrade 请求。
- 公共隧道传输内容保持端到端加密，Go Server 观察不到 HTTP 明文。
- 开发者工作区启动的游戏返回时恢复原工作区，而不是跳回主页。

## 未执行项

- 本次未重新构建 Android 或 Windows 发布包。
- 未执行真实公网中转服务器与多台实体设备联机。
- 未执行 Android WebView、Windows WebView2 和普通移动浏览器的人工扫码验收。

现有 `2.0.0+18` 发布包早于本次声明入口修正；如需分发包含本次改动的安装包，
必须重新执行对应平台的发布构建。
