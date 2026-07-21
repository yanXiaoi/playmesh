# 第六阶段移动端问题修复切片验证（2026-07-18）

## 修复范围

- 未安装本地游戏时仍可进入“加入对局”，扫描主机分享二维码后直接打开主机游戏或控制器 WebView。
- 主机分享网关向 App 页面注入本机桥接 SDK；普通浏览器只加载权威主机 SDK 和安全的 App 空实现。
- 修复游戏包导入成功后因 `setState` 回调返回 `Future` 而误报失败。
- Android 导出改为生成压缩包后调用系统分享/保存面板。
- 全屏与游戏运行、SDK 初始化和加入对局解耦；失败仅提示并允许重试或关闭。
- 手机开发者工作区改为两行工具栏，“更多”菜单限制在视口内并支持滚动。
- Android Manifest 与原生通道接收系统打开/分享文件；压缩包导入，HTML 进入无 SDK 注入的独立 WebView。
- 游戏、扫码远程和独立 HTML WebView 的右上角悬浮工具提供进入/退出全屏。
- 浏览器玩家 ID 与昵称持久化到 `localStorage`，App 玩家自动使用本机持久化身份；同 ID 只允许一个在线 WebSocket。
- SDK 暴露玩家加入、掉线和重连事件；Core 仅在运行或暂停状态保留离线成员，`session.finish()`、重置和重新开始自动清理离线席位。
- 全局页面转场移除缩放合成，内容首帧保持可见并缩短入场时间；开发者模式开关立即反映目标状态，后台完成端口启停。

## 自动验证

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze --no-pub` | 通过，0 个诊断 |
| Flutter 完整测试 | `flutter test --no-pub` | 通过，92 项，20.8 秒 |
| SDK 主机 Bridge 契约 | `node tool/test_game_sdk.mjs` | 通过，含 `session.finish()` |
| SDK App Bridge 契约 | `node tool/test_app_bridge_sdk.mjs` | 通过，身份和设备能力自动注入 |
| SDK 浏览器契约 | `node tool/test_game_sdk_browser.mjs` | 通过；ID/昵称持久化，加入/掉线/重连事件正确 |
| Go Core 全量测试 | `go test ./...` | 通过；覆盖运行中离线保留、结束清理和重复 WebSocket 拒绝 |
| JavaScript 语法 | `node --check` 检查 SDK、工作区和浏览器测试 | 通过 |

测试中出现的“游戏资源网关必须且只能指定一种包来源”和模拟“fullscreen requires a user gesture”日志来自错误路径注入用例，相关测试均通过，不是回归失败。

## 仍需真机确认

- 未执行 Android 平台构建或真机安装。
- 需要在 Android 真机确认扫码权限、局域网主机页面加载、系统打开/分享文件入口、系统导出面板以及不同屏幕宽度下的工作区菜单位置。
