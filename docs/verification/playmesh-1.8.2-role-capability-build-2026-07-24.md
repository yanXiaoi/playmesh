# Playmesh 1.8.2 角色能力隔离与构建验证

## 范围

- App `1.8.2+15`
- Developer API / OpenAPI `1.6.1`
- Developer CLI `1.3.1`
- Game SDK `2.2.1`
- App Bridge SDK `2.1.0`

本次验证覆盖单屏多人权威显示端与控制器端的能力声明隔离。显示端只读取
`capabilities.json.required`，控制器端只读取 `controllerRequired`；任一角色的显式空数组都是最终声明，
不得回退或合并另一个角色的能力。

## 自动验证

所有 Flutter 命令均按 `docs/04-dev-env.md` 使用固定工具链，并在沙箱外串行执行。

| 验证 | 结果 |
| --- | --- |
| `dart format lib test` | 通过 |
| `flutter analyze --no-pub lib test` | 通过，无问题 |
| `flutter test --no-pub` | 通过，155 项 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |

回归断言包括：

- `required: []`、`controllerRequired` 非空时，权威显示端取得空能力列表，控制器取得完整控制器能力列表。
- 单屏多人权威显示端加载 `entries.game`，并向 WebView 注入空的当前页面能力声明。
- App Bridge `getDeclared()` 返回空数组时，即使旧的通用字段仍含控制器能力，Game SDK 也不会弹出能力确认。
- 普通多人多屏加入端不被误判为单屏控制器。

## Android

- 构建命令：`tool/build_release.ps1 -Target all -AllowDebugSigning`
- 产物：`release/1.8.2/Playmesh-1.8.2-build15-android-universal.apk`
- 大小：96,956,755 bytes
- SHA-256：`25E7F5AF68E11D14BBAC19F5265A9A6615A5EF20BC4F399817D569B61EC3DAD1`
- APK Signature Scheme v2：通过
- 签名者数量：1
- 签名证书：`C=US, O=Android, CN=Android Debug`

该 APK 仅供内部安装验证，不是生产签名包。

## Windows

- 构建命令：`tool/build_release.ps1 -Target windows`
- 产物：`release/1.8.2/Playmesh-1.8.2-build15-windows-x64-portable.zip`
- 大小：23,583,759 bytes
- SHA-256：`8B31052A4222C7E7B86D35DF976B92F44A84CB7DC3A45295894F16E397A2FB32`

发布脚本已检查 ZIP 根目录包含 App、Go Core、Developer CLI、Flutter 和 WebView2
运行所需文件，并在打包前清理不应随包分发的本地游戏与缓存内容。

## 仍需人工验证

- 在 Android 和 Windows 真机上打开仅声明 `controllerRequired` 的单屏多人游戏，确认权威显示端不出现能力授权提示。
- 连接控制器，确认控制器端仍按 `controllerRequired` 请求加速度计、陀螺仪和振动能力。
- Android 正式发布前使用非 Debug 的生产密钥重新构建。
