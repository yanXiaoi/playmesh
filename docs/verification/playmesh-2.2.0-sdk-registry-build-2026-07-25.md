# Playmesh 2.2.0 SDK 注册表与平台构建验证

日期：2026-07-25

## 验证范围

- Playmesh App `2.2.0+21`
- Game SDK `2.2.2`
- App Bridge SDK `2.1.1`
- Developer API / OpenAPI `2.1.0`
- Dart feature 是 SDK 唯一手写源，运行和发布构建从同一注册表组装 SDK。
- Dart 执行器自行声明支持版本；`SdkVersionRange.last` 表示开放上界。
- 同一命令可以按不重叠版本范围注册，但同一版本不能命中两个执行器。
- 所有 SDK 网关、下载、提示词和 Bridge 入口禁止静态文件或测试注入旁路。

## 沙箱外自动验证

| 验证 | 结果 |
| --- | --- |
| `node tool\generate_sdk.mjs` | 通过，生成 Game SDK `2.2.2`、App SDK `2.1.1` |
| SDK 注册、无旁路和网关定向 Flutter 测试 | 25 项通过 |
| `node tool\test_game_sdk.mjs` | 通过 |
| `node tool\test_app_bridge_sdk.mjs` | 通过 |
| `node tool\test_game_sdk_browser.mjs` | 通过 |
| `node tool\test_sdk_declarations.mjs` | 通过 |
| `node tool\test_default_authority_service.mjs` | 通过 |
| `flutter analyze --no-pub` | 通过，无问题 |
| `flutter test --no-pub` | 175 项通过 |
| Go Core `go test ./...` | 通过 |
| Developer CLI `go test ./...` | 通过 |

版本范围断言包含以下成功与失败边界：

- `1.0.0-2.9.9` 与 `3.0.0-last` 可为同一命令注册两个执行器。
- `1.0.0-last` 与 `3.0.0-last` 因重叠而被拒绝。
- `last` 能承接后续已注册 bundle，但清单请求仍必须先命中 SDK 发行表；未知
  `2.2.3` 不会因为开放执行器范围而被接受。
- TypeScript 当前 bundle 发出的每条命令都必须存在一个且仅一个 Dart 执行器。
- `playmesh.session.start/finish` 的 `.d.ts` 明确断言业务条件由 Authority 判断。

## Android

- 构建命令：`tool\build_release.ps1 -Target android -AllowDebugSigning`
- 产物：
  `release\2.2.0\Playmesh-2.2.0-build21-android-universal.apk`
- 大小：98,433,444 bytes
- Application ID：`top.zfjmm.playmesh`
- Version name：`2.2.0`
- Version code：`21`
- ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`
- APK Signature Scheme v2：通过
- 签名类型：内部 debug key。工作区没有 `android/key.properties`，不能视为商店生产签名。
- 包内 SDK：Game `2.2.2`、App `2.1.1`
- SHA-256：
  `951042DB7C4378EE2726CA6DA1BC23A14822379372E6E9F415694AE2657D63D3`

构建过程重新生成 Go Core AAR，并在 Gradle `assembleRelease` 前自动生成 SDK。Flutter
提示 `mobile_scanner` 未来需要迁移到 Built-in Kotlin；该预警未影响本次构建。

## Windows

- 构建命令：`tool\build_release.ps1 -Target windows`
- 产物：
  `release\2.2.0\Playmesh-2.2.0-build21-windows-x64-portable.zip`
- 大小：23,794,809 bytes
- 架构：Windows x64 便携包
- 包内 SDK：Game `2.2.2`、App `2.1.1`
- SHA-256：
  `D0E5C18E60EA54EA76004CCC4228E749CD75211793DC3C8018FC81740B9B32C9`

ZIP 已验证包含：

- `playmesh.exe`
- `playmesh-core.exe`
- `playmesh-cli.exe`
- `flutter_windows.dll`
- `WebView2Loader.dll`
- `data/app.so`
- `data/icudtl.dat`

`playmesh.exe`、`playmesh-core.exe` 与 `playmesh-cli.exe` 的 Authenticode 状态均为
`NotSigned`，因此当前 ZIP 是未做 Windows 代码签名的内部便携构建。

## 尚未替代的人工验收

- 未在 Android 真机安装并验证后台 Developer Gateway、传感器、震动、扫码和多设备联机。
- 未在 Windows GUI 中启动便携包并完成 WebView2、Core、CLI 与多设备联机烟测。
- 未执行 Android 商店生产签名或 Windows Authenticode 签名。
