# Playmesh 1.6.2 能力插件验证（2026-07-22）

## 验证范围

- App：`1.6.2+10`
- Game SDK：`2.0.0`
- App Bridge SDK：`2.0.0`
- Developer API / OpenAPI：`1.5.0`
- 能力插件：`sensor.accelerometer@1.0.0`、`sensor.gyroscope@1.0.0`

本轮验证覆盖通用插件注册表、实例生命周期、Bridge 命令/事件、SDK 生成与类型、项目能力声明校验、开发者工作区全平台注册表展示和插件自检接口。旧 `DeviceType/onDevice` 契约不在兼容范围内。

## 自动验证

| 命令 | 结果 |
|---|---|
| `node tool/generate_sdk.mjs` | 通过；生成 Game SDK `2.0.0` 与 App SDK `2.0.0` |
| `node tool/test_app_bridge_sdk.mjs` | 通过；create/invoke/event/dispose 契约通过 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过；生成声明无旧 `onDevice` 签名 |
| `node tool/test_default_authority_service.mjs` | 通过 |
| 解析 OpenAPI、SDK Manifest 与 SDK Schema JSON | 通过 |
| `node --check` 工作区脚本及两份生成 SDK | 通过 |
| `flutter analyze --no-pub lib test` | 通过；No issues found |
| `flutter test --no-pub` | 通过；134 项测试全部通过 |
| `flutter build apk --debug --no-pub` | 通过；生成 Android debug APK |
| `git diff --check` | 通过；仅有仓库现有的 LF/CRLF 转换提示，无空白错误 |

Flutter 测试在受限沙箱中无法启动 `flutter_tester` 子进程并超时；使用同一工作区、同一 Flutter SDK 在允许启动子进程的外部执行环境中完成，定向测试与全量测试均通过。

## 构建产物

- 路径：`build/app/outputs/flutter-apk/app-debug.apk`
- 大小：`196,935,444` 字节
- SHA-256：`1BA104A637E3D7F648812E08DD9DDDBA44B6549C5580BA77BA00E63F07459165`
- 包内确认包含 `playmesh.js`、`playmesh-app.js` 及两份 `.d.ts`；包内 App SDK 常量为 `2.0.0`。
- 构建提示：`mobile_scanner` 仍应用 Kotlin Gradle Plugin；Flutter 提示未来需迁移到 Built-in Kotlin。本轮不影响构建成功。

## 已验证行为

- 全平台注册表从插件注册入口生成，每个插件公开 code、`apiVersion`、创建参数 Schema、方法参数/返回值 Schema、事件数据 Schema 和平台状态。
- 项目 `capabilities.json` 只控制该游戏的声明与运行时授权；开发者工作区“能力测试”展示并测试全平台注册表，不按当前项目过滤。
- App Bridge 只保留 `app.capability.create/invoke/dispose` 与 `app.capability.event/error` 通用协议。
- 加速度计和陀螺仪已迁移到独立插件目录；实例使用 `start/stop` 和 `reading`，同种传感器实例共享原生流，释放后停止采集。
- Game/App SDK 生成物、`.d.ts`、SDK Manifest、Schema、默认项目版本、AI 提示词和 Dart 版本常量来自同一次生成并对齐到 `2.0.0`。

## 尚需真机验证

本轮环境没有已连接的 Android/iOS 传感器真机，因此未验证实际加速度计/陀螺仪数值、系统权限 UI、页面切换时的硬件功耗以及厂商 WebView 生命周期差异。安装 debug APK 后，应在开发者工作区打开“更多 → 能力测试”，确认全平台注册表中的两个插件均能持续返回 `passed` 和真实 `reading` 样本，再进入声明对应能力的游戏验证 `start/stop/dispose`。
