# 第六阶段与 Playmesh 1.1.0 完整验证（2026-07-18）

## 验证范围

- 第六阶段移动运行、远程加入、可选全屏、Android 文件入口与导出链路。
- Game SDK / App Bridge SDK 身份边界、浏览器身份持久化、重复 ID 拦截、离线成员和重连事件。
- App `1.1.0+2`、Go Core `0.2.0`、Game SDK `1.2.0` 版本常量、默认模板、机器契约和编辑器补全一致性。
- AI 对话/Agent 提示词的双 SDK、版本只读、会话结束和最近日志链路。
- App 设置页简略更新日志与 `docs/version/1.1.0.md` 详细日志入口。

## 自动验证

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| Dart 格式化 | 固定 SDK 的 `dart.exe format` | 通过，无剩余格式变化 |
| Flutter 静态分析 | `flutter.bat analyze --no-pub` | 通过，0 个诊断，4.4 秒 |
| Flutter 定向测试 | 设置页与 `developer_web_gateway_test.dart` | 通过，12 项，约 3 秒 |
| Flutter 完整测试 | `flutter.bat test --no-pub` | 通过，93 项，18.3 秒 |
| Go Core 全量测试 | 固定 Go 1.26.2 执行 `go test ./...` | 通过，含 session 与 mobile 包 |
| Game SDK 主机契约 | `node tool/test_game_sdk.mjs` | 通过，SDK 版本 `1.2.0` 与 `session.finish()` 正确 |
| App Bridge SDK 契约 | `node tool/test_app_bridge_sdk.mjs` | 通过，App 身份与设备能力边界正确 |
| 浏览器 SDK 契约 | `node tool/test_game_sdk_browser.mjs` | 通过，ID/昵称持久化及连接事件正确 |
| JavaScript / JSON | `node --check` 与 `JSON.parse` | 工作区脚本、SDK Manifest、SDK Schema、默认清单均通过 |

## 验证中修正

- 简略更新日志首次直接展开在设置页顶部，导致 600px 高度测试视口中的 Core 刷新按钮被挤出可点击区域。改为 About 卡片右侧“查看本次更新”按钮和可滚动弹窗后，原布局和更新日志均可访问。
- 首轮全量测试发现 `widget_test.dart` 仍断言旧文案 `Playmesh 1.0`。同步为 `Playmesh 1.1.0` 后，失败用例单独复测通过，再次全量测试 93 项全部通过。

测试中的“游戏资源网关必须且只能指定一种包来源”和模拟“fullscreen requires a user gesture”日志来自错误路径用例，测试结果为通过，不是回归失败。

## 防超时执行方式

- 使用 `docs/04-dev-env.md` 记录的 Flutter/Go SDK 绝对路径。
- Flutter 分析与测试统一使用 `--no-pub`，不重复依赖解析。
- 先运行设置页和 Developer Gateway 定向测试，再运行全量测试。
- 失败时保留首个失败测试，使用 `--plain-name` 单独复测后再重跑全量。
- 本次命令均在文档时限内持续输出，没有通过重复启动 Flutter 进程规避锁或等待。

## 未执行项

- 未执行 Android、iOS、Windows、macOS 或 Linux 平台构建。
- 扫码、系统打开/分享文件、系统导出面板、WebView 全屏及真实移动屏幕布局仍需用户在目标平台手工验证。
