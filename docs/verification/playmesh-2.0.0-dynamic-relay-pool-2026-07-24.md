# Playmesh 2.0.0 公共中转动态连接池验证

## 范围

- Catalog API 从 `1.3.0` 升级到 `1.4.0`。
- Go Server 在现有 `/apps/info.relay` 中返回
  `maxConnectionsPerTunnel`，值直接来自当前 Relay 配置。
- App 不再固定创建 16 条 Host 连接，而是把服务器声明值作为动态池上限。
- 每个隧道最多保留 4 条热连接；热连接被配对后立即异步补充，活跃连接结束后
  对应槽位退出，池自动收缩。
- Go Server 的隧道配对、逐 IP 限流和单隧道限流仍是最终约束；没有新增接口或
  业务实体，Relay 数据面协议保持 `2.0.0`。

## 行为验证

定向测试使用声明上限 `6`：

1. 主机首次连接后只建立 4 条热连接，没有直接建满 6 条。
2. 客户端建立一条透明 HTTP 连接后，其中一条热连接转为活跃连接。
3. 主机立即新建一条 Host Upgrade，把热连接补回 4 条。
4. HTTP 连接结束后活跃槽位退出，主机重新稳定在 4 条热连接。
5. 实际 Host Upgrade 累计从 4 增加到 5，证明连接按需求补充。

声明上限小于 4 时，热连接数使用
`min(4, maxConnectionsPerTunnel)`，不会超过服务器声明容量。连接建立失败或
服务器限流时沿用指数退避。

## 自动验证

所有命令按 `docs/04-dev-env.md` 使用固定工具链并在沙箱外执行。

| 验证 | 结果 |
| --- | --- |
| Dart 格式化 | 通过 |
| Go 格式化 | 通过 |
| `flutter analyze --no-pub lib test` | 通过，无问题 |
| Catalog 与 Relay 动态池定向测试 | 通过，6 项 |
| `flutter test --no-pub` | 通过，165 项 |
| `go test ./...`（`go-server`） | 通过 |

## 未执行项

- 未重新构建 Android 或 Windows 安装包。
- 未连接真实公网 Go Server 进行多玩家并发及限流验收。
- 未执行长时间空闲 WebSocket、弱网重连和服务器容量动态修改的人工测试。
