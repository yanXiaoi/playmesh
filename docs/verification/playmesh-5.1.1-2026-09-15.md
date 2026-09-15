# Playmesh 5.1.1 build 38 正式构建验证（2026-09-15）

## 范围

按 `docs/04-dev-env.md` 的统一入口执行主 App Android universal 与 Windows x64 portable
正式构建。App 版本为 `5.1.1+38`；Game SDK `4.3.0` 与 App Bridge SDK `3.5.0` 按要求
保持版本号不变。构建前生成器重新生成四个 SDK 文件并确认版本常量未升级。

## 制品

| 制品 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-5.1.1-build38-android-universal.apk` | 170,616,761 | `6e18c3db9d77e3a2fdfab9fa543745a0a8c553b939c59c868ecf4f0d44363040` |
| `Playmesh-5.1.1-build38-windows-x64-portable.zip` | 33,929,371 | `a43f064fa8f09a74c1d8f124db76dd685c833fc26e6012a4e7dd99422637617e` |

版本化文件位于 `release/5.1.1/`。构建脚本用相同字节覆盖
`resources/app/playmesh.apk` 与 `resources/app/playmesh.zip`，长度和 SHA-256 逐项一致；
`resources/app/update.json` 已更新为 `5.1.1`。

## Android

- `flutter build apk --release --no-pub` 成功，产物为 universal APK。
- 28 项发布 Asset 在源码快照与包内逐字节一致。
- APK Signature Scheme v2 验证通过；v1/v3/v3.1/v4 未启用，签名者数量为 1。
- 签名证书 DN：`CN=ZFJ, OU=Unknown, O=Unknown, L=Unknown, ST=SC, C=ZH`。
- 签名证书 SHA-256：
  `21be46f5cedeaac65ecac832d0587a2015ae6653a431e5857cc5f0687f0d786b`；不是
  `CN=Android Debug`。
- 随包 `playmesh_core.aar` 从当前 `go-core/mobile` 源码重新生成。

## Windows

- HostX64 MSVC 19.50 + Visual Studio Ninja 干净 Release 构建成功。
- ZIP 根包含 `playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、
  `playmesh-apksign.exe`、`flutter_windows.dll`、`WebView2Loader.dll`、`data/app.so`、
  `data/icudtl.dat` 与默认 Runtime 导出证书。
- 28 项发布 Asset 在源码快照与包内逐字节一致；主 App 包未混入
  `resources/runtime/` 或 `runtime/resource/` 的独立 Runtime 底包。
- Go Core、Developer CLI、Runtime 导出器与 APK 签名工具均从当前源码构建。

## 相关回归

- 主工程 `flutter analyze`：零问题；`flutter test --no-pub`：1128 项通过。
- Runtime `flutter analyze`：零问题；`flutter test --no-pub`：91 项通过。
- Go Core `go test ./...`：通过。
- Game/App SDK 生成、Node、浏览器、声明与 File System Access 契约测试通过。
- Runtime 的 Game/App 宿主命令集合与主 App 注册表精确一致；独立 Runtime 按设计不对
  Core 健康响应做精确版本校验，以保留跨兼容版本使用能力。

## 发布边界

本次自动构建过程没有独立执行 Android/Windows 系统文件选择器、两台设备、长时在线、
接近 1 MiB 状态快照、大文件上传与公网 TURN 实机测试。发布人随后确认已完成目标发布
环境测试，并要求把 `v5.1.1-build38` 从 Pre-release 提升为当前稳定正式发行；具体设备、
网络矩阵和原始日志未纳入仓库，本记录只把该结论标为发布人验收。构建期间仅出现 Flutter
Built-in Kotlin 未来迁移警告及 MSVC 警告级别覆盖提示，均未造成构建或门禁失败。
