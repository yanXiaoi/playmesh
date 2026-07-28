# Playmesh 3.0.0 App SDK 与游戏工具悬浮窗验收

日期：2026-07-27

## 验收范围

- App 级 API 统一归入 `playmesh.app`：
  - `openSharePanel()`
  - `showToolDock()`
  - `hideToolDock()`
  - `exitGame()`
- SDK 显示悬浮游戏工具时，自动展开并把焦点移入工具栏。
- SDK 拉起的工具栏在执行实际工具操作后自动隐藏；“更多”仅负责展开二级操作，
  选中其中的实际操作后再隐藏。
- SDK 主动隐藏工具栏时，恢复显示前的游戏网页焦点。
- 本地游戏页与远程游戏页共用 App Bridge 命令语义。
- 旧 `playmesh.authority.openSharePanel()` 不保留兼容入口。

## 自动化结果

以下命令均在沙箱外执行：

| 命令 | 结果 |
| --- | --- |
| `flutter test` | 通过，`270/270` |
| `flutter analyze` | 通过，`No issues found` |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `node tool/test_platform_ui_localization_source.mjs` | 通过 |
| `git diff --check` | 通过；仅输出工作区既有 LF/CRLF 提示 |

## TV 遥控器边界

自动化已覆盖 App 首页初始焦点、方向键移动、Enter 激活，以及本次 SDK 拉起游戏工具
后的焦点进入和操作后收起。游戏 WebView 内部的键盘/遥控器事件由游戏开发者监听，
App 不替游戏实现具体操作。

“遥控器可操作所有 App 操作”仍必须在 Android TV 真机上逐页验收首页、游戏库、
在线游戏库、游戏源管理、加入对局、资料、设置、开发者工作区及所有弹窗。扫码、
文件选择和文本输入还依赖设备能力或系统界面，必须确认存在可用的非触摸路径后，
才能将 TV 全面覆盖标记为完成。
