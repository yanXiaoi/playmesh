# Playmesh 4.2.0 发布验证记录

## 验证信息

- 日期：2026-08-21
- App：`4.2.0+28`
- Game SDK：`4.1.0`（本次不升版）
- App Bridge SDK：`3.3.0`（本次不升版）
- Developer API / OpenAPI：`4.3.0`
- 目标标签：`v4.2.0-build28`
- 目标平台：Android universal、Windows x64 portable

## 源码与契约验证

| 命令 | 结果 |
| --- | --- |
| `node tool/generate_sdk.mjs` | 通过；生成 Game SDK `4.1.0`、App Bridge SDK `3.3.0` |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `node tool/test_platform_ui_localization_source.mjs` | 通过 |
| `node tool/test_default_authority_service.mjs` | 通过 |
| `node tool/test_desktop_cli_packaging.mjs` | 通过 |
| `flutter analyze --no-pub lib test` | 通过，无静态分析问题 |
| `flutter test --no-pub` | 通过，共 1051 项 |
| `go test ./...`（`go-core`） | 通过 |
| `go test ./...`（`go-server`） | 通过 |
| `go test ./...`（`dev-cli`） | 通过 |
| GDevelop 锁定管线 `test --profile default` | 通过；命中与当前输入一致的有效验证回执 |
| `git diff --check` | 发行文档与版本改动通过；vendored WebView2 源码既有的两处注释行尾空格保留，未越权改动第三方代码 |

以上结果确认当前已升级完成的 Game SDK `4.1.0` 与主应用兼容。本次发行只推进主应用
`4.2.0+28`，没有再次修改 SDK 版本号。

## 正式构建

执行 `tool/build_release.ps1 -Target all`。Android 与 Windows 均完成正式构建，构建脚本
同时以覆盖方式写入 `resources/app/playmesh.apk` 和 `resources/app/playmesh.zip`。两份固定
镜像分别与对应的带版本号 Release 制品逐字节一致，并通过 Git LFS 跟踪和提交；其中 APK
大小超过 GitHub 普通 Git 的 100 MB 单文件限制，不能作为普通 Git Blob 推送。

### Android

- Release 文件：`Playmesh-4.2.0-build28-android-universal.apk`
- Git 固定镜像：`resources/app/playmesh.apk`
- 大小：`148509143` 字节
- SHA-256：`FC1E8599AA22F8FC7A49AEC72989C06D22949B05E9B578BDBEDC464206064ACC`
- 签名：正式 keystore；APK Signature Scheme v2 验证通过；签名者数量 `1`
- 包内资源：28 项全部通过长度与 SHA-256 复核

### Windows

- Release 文件：`Playmesh-4.2.0-build28-windows-x64-portable.zip`
- Git 固定镜像：`resources/app/playmesh.zip`
- 大小：`28920934` 字节
- SHA-256：`A10EBC1F7FBCBE8488C99123316418E470EFACE19A6BED7FE313CB6A5EFA84BB`
- 结构：Windows x64 portable bundle，必需运行文件验证通过
- 包内资源：28 项全部通过长度与 SHA-256 复核

## 非阻断提示

- Android 构建提示 `mobile_scanner` 与 `speech_to_text` 仍使用 Kotlin Gradle Plugin 应用
  方式；这是后续 Flutter 版本迁移提醒，不影响本次 APK 构建与签名验证。
- Windows 编译器提示部分依赖把警告级别从 `/W3` 覆盖为 `/W4`；正式 bundle 仍成功生成并
  通过资源复核。

## 人工验收边界

- Android、Windows、macOS、Linux 的 LAN 跨设备发布、发现、更新/丢失、权限拒绝、网络
  切换以及物理/虚拟网卡组合仍需实机验收；iOS 自动发现/发布按设计返回 `unsupported`。
- Android、iOS、Windows 的源码包和游戏安装包系统保存/分享界面仍需补充平台实机验收。
- App 内手动更新只负责解析渠道并交给系统浏览器打开下载地址，不在应用内校验或安装主
  应用。GitHub/Gitee Release 的 `SHA256SUMS.txt` 是正式附件完整性依据。
