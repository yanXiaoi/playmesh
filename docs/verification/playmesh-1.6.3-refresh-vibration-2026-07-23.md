# Playmesh 1.6.3 刷新与震动验证（2026-07-23）

## 版本

- App：`1.6.3+11`（开发中，尚未正式发布）
- Game SDK：`2.0.0`
- App Bridge SDK：`2.0.0`
- Developer API / OpenAPI：`1.5.0`

Game SDK、App Bridge SDK 和 Developer API 沿用既有通用能力插件与运行协议，本次没有改变其公开契约，因此不升级版本。

## 覆盖范围

- Android 游戏工具区刷新不再调用 Core `session.reset`，只通知旧页面退出、完成存储落盘并重建 WebView；当前会话、联机码、玩家、分享网关和 token 保留。
- Developer API 首次启动游戏时移除旧游戏路由后再创建 WebView，避免连续运行项目时多个 WebView 叠加。
- 新增 `device.vibration@1.0.0` 插件，支持 `selection/light/medium/heavy/vibrate`；工作区自检不主动震动。
- 移除旧的 `app.device.haptic` Bridge 命令和 `playmesh.app.device.haptic` SDK 成员，震动只通过通用插件实例调用。
- App、更新日志、开发文档、提示词、SDK 生成物和测试版本已对齐。

## 自动验证

以下测试均按要求在沙盒外执行：

| 命令 | 结果 |
|---|---|
| `dart analyze lib` | 通过，无问题 |
| `dart analyze test` | 通过，无问题 |
| `flutter test --no-pub` | 通过，138 项 |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `flutter build apk --debug --no-pub` | 通过 |
| `git diff --check` | 通过 |

Android 构建提示 `mobile_scanner` 仍应用 Kotlin Gradle Plugin，需在未来 Flutter 强制 Built-in Kotlin 前升级依赖。

## Android debug 产物

- 路径：`build/app/outputs/flutter-apk/app-debug.apk`
- 大小：`196,938,732` 字节
- SHA-256：`3E7519A63ABBD29B37C652C3CAFF8769B9BDA7A4E269F6523EDAB992A224CCDB`
- 包名：`top.zfjmm.playmesh`
- `versionName`：`1.6.3`
- `versionCode`：`11`
- `minSdkVersion`：`24`
- `targetSdkVersion`：`36`

## 真机待验证

- Android 联机游戏进入后点击“刷新游戏”，应保持原会话和联机码，且不再显示“会话 ID 不存在”。
- 从 Developer API 连续启动两个项目，屏幕中只能存在当前游戏 WebView，返回时不应回到旧游戏。
- 在 Android 和 iOS 真机声明 `device.vibration`，分别测试五种 style 的实际触感与系统设置影响。
- 普通局域网浏览器应把 `device.vibration` 标记为不可用，并保持游戏降级流程正常。
