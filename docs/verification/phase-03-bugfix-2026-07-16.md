# 第三阶段联机 Bug 修复验证（2026-07-16）

## 修复范围

- 钓鱼 Demo 完整五回合自动推进并进入最终结算。
- Authority 在倒计时、回合截止和回合间结算点使用精确定时，并保留周期 tick 兜底。
- 浏览器每次刷新重新加入，同昵称也生成全新的玩家 ID。
- 分享 URL 与 SDK 注入配置不再携带昵称；SDK 只在 `localStorage` 保存昵称偏好，首次缺失时显示输入层。
- 浏览器 SDK 统一提供悬浮改名按钮，改名保持玩家 ID、更新 Core 会话并广播；App 环境拒绝该 API。
- 旧玩家断线后从 Core 成员集合移除并释放人数名额。
- 成员变化后 Authority 主动同步最新游戏状态，大屏不保留离线旧玩家。
- 重新开始把同一 Core 会话重置为大厅，保留会话 ID、联机码、已连接玩家、分享网关和 token。
- Authority 回复中的玩家若恰好断线，Core 安全丢弃该目标，不中断 Authority 连接。
- 游戏库提供手动后台扫描按钮；刷新期间保留旧缓存，成功后原子替换，并缓存搜索与分页所需元数据。
- Windows Runner 向内置 Core 传递父进程 PID，Runner 退出后 Core 自动关闭，不再锁住下一次构建的安装目标。

## 自动检查

| 命令 | 覆盖 |
|---|---|
| `node tool/test_fishing_service.mjs` | 五回合、最终结算、同昵称新 ID 成员同步和准备状态 |
| `node tool/test_game_sdk_browser.mjs` | 首次昵称输入、本地昵称复用、悬浮改名、刷新新玩家 ID、主机 Bucket |
| `node tool/test_game_sdk.mjs` | App WebView SDK Bridge 契约及浏览器专属改名 API 隔离 |
| `go test ./...` | reset、断线移除、昵称更新、同昵称新玩家、替换连接、过期目标竞态和 Go Core 全量回归 |
| `flutter analyze` | Flutter/Dart 静态检查 |
| `flutter test` | 43 项测试，包括浏览器昵称代理、缓存原子替换、查询切片、游戏库后台刷新和重新开始流程 |

本次 `flutter analyze`、43 项 Flutter 测试、`go test ./...` 和三组 Node 合约测试全部通过。Windows Debug 构建由用户手动验证成功；常规自动任务不执行 `flutter build windows`。
