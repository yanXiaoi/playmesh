# Playmesh 1.4.0 验证记录

日期：2026-07-21

## 验证结果

| 验证项 | 命令/范围 | 结果 |
| --- | --- | --- |
| Dart/Flutter 静态分析 | `flutter analyze --no-pub` | 通过，0 问题 |
| Flutter 完整测试 | `flutter test --no-pub` | 通过，118 项 |
| WebView 与传感器定向测试 | 队列、能力自检、App Bridge、Sensor Hub | 通过，14 项 |
| Developer Gateway | 工作区、创建项目、能力 API、OpenAPI | 通过，6 项 |
| Game SDK 主机契约 | `node tool/test_game_sdk.mjs` | 通过，SDK `1.3.0` |
| App Bridge SDK 契约 | `node tool/test_app_bridge_sdk.mjs` | 通过 |
| 浏览器 SDK 契约 | `node tool/test_game_sdk_browser.mjs` | 通过 |
| 默认 Authority 模板 | `node tool/test_default_authority_service.mjs` | 通过 |
| Go Core | `go test ./...` | 通过 |
| 工作区/契约语法 | `node --check workspace.js`、OpenAPI JSON 解析 | 通过 |
| Android debug 构建 | `flutter build apk --debug --no-pub` | 通过 |

## Android 产物

- 文件：`release/1.4.0/Playmesh-1.4.0-build5-android-debug.apk`
- 大小：`196882574` 字节
- SHA-256：`208D7D1EF6D111205FBE3719168F484E25E2DA58229E00D4E8987679CC6DA9A0`
- 包名：`top.zfjmm.playmesh`
- `versionName`：`1.4.0`
- `versionCode`：`5`
- `minSdkVersion`：`24`
- `targetSdkVersion`：`36`

## 平台状态与限制

- 当前 `adb devices -l` 没有连接设备，因此没有在真实 Android 传感器上执行最终手工样本验证。
- 安装到真机后，在开发者工作区选择“更多 → 能力测试 → 测试全部”；加速度计和陀螺仪应返回 `passed` 与首个 X/Y/Z 样本。
- 构建提示 `mobile_scanner` 仍应用 Kotlin Gradle Plugin；当前 debug 构建成功，但后续 Flutter 升级前应跟进插件对 Built-in Kotlin 的迁移。
