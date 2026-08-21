# Playmesh 4.2.1 发布验证记录

## 验证信息

- 日期：2026-08-21
- App：`4.2.1+29`
- Developer API / OpenAPI：`4.4.0`
- Game SDK：`4.1.0`（不升版）
- App Bridge SDK：`3.3.0`（不升版）
- 目标平台：Android universal、Windows x64 portable

## 源码与契约验证

| 命令 | 结果 |
| --- | --- |
| `node --check assets/playmesh-library/public/developer/workspace.js` | 通过 |
| `node tool/test_platform_ui_localization_source.mjs` | 通过 |
| 聚焦工作区、安装包、Gateway、设置与 Widget 测试 | 通过，共 86 项 |
| `flutter analyze --no-pub lib test` | 通过，无静态分析问题 |
| `flutter test --no-pub` | 通过，共 1053 项 |
| `node tool/generate_sdk.mjs` | 通过；Game SDK `4.1.0`、App Bridge SDK `3.3.0` |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `node tool/test_default_authority_service.mjs` | 通过 |
| `node tool/test_desktop_cli_packaging.mjs` | 通过 |
| GDevelop 主页身份与 UI 契约 | 通过 |
| `go test ./...`（`go-core`） | 通过 |
| `go test ./...`（`dev-cli`） | 通过 |
| `git diff --check` | 通过；只有工作树 LF 将按 Git 配置转换为 CRLF 的提示 |

`go-server` 存在独立的未提交修改，不属于本次客户端任务，也不参与 APK 或 Windows portable
构建；本次提交和验证均不把这些修改计入发布结论。

## 正式构建

执行 `tool/build_release.ps1 -Target all`。首次在受限环境中因系统 Go 构建缓存拒绝访问而停止；
允许脚本读取工具链缓存后，同一私有 Runtime crypto 测试通过，Android 与 Windows 均完成
正式构建。脚本以同批字节覆盖 `resources/app/playmesh.apk` 与
`resources/app/playmesh.zip`，固定镜像与带版本号制品的长度和 SHA-256 分别完全一致。

### Android

- Release 文件：`Playmesh-4.2.1-build29-android-universal.apk`
- Git 固定镜像：`resources/app/playmesh.apk`
- 大小：`148508911` 字节
- SHA-256：`4D84B68E748017683DFE8ADE3494BB223B322A84B8DAAE706A36A78728CFC605`
- 签名：仓库正式 keystore；APK Signature Scheme v2 验证通过；签名者数量 `1`
- 包内资源：28 项全部通过长度与 SHA-256 复核

### Windows

- Release 文件：`Playmesh-4.2.1-build29-windows-x64-portable.zip`
- Git 固定镜像：`resources/app/playmesh.zip`
- 大小：`28419677` 字节
- SHA-256：`6DCB25A9FC94830ED604D1E6627D425F878611C068201BF2F8C9FAED4072046F`
- 结构：Windows x64 portable bundle，必需运行文件验证通过
- 包内资源：28 项全部通过长度与 SHA-256 复核

## 非阻断提示与人工验收边界

- Android 构建提示 `mobile_scanner` 与 `speech_to_text` 后续需要迁移 Flutter 内置 Kotlin
  支持；不影响本次 APK 构建和签名验证。
- Windows 编译器提示依赖把 `/W3` 覆盖为 `/W4`；bundle 仍成功生成并通过资源复核。
- 工作区 HTML/CSS/JavaScript、Android WebView 与 Windows WebView 共享实现已有自动化验证；
  Android 不同输入法下的软键盘、横屏和系统缩放组合仍需实机视觉验收。
- GDevelop revision 19 ZIP 已通过开发期 `dev-package` 构建、审计、封装和安装证明以及主页
  契约测试；本轮没有把开发期回执冒充新的 `release-check/all` 公开发布回执。
