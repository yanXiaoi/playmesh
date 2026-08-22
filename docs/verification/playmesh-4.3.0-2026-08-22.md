# Playmesh 4.3.0 发布验证记录

## 验证信息

- 日期：2026-08-22
- App：`4.3.0+30`
- Developer API / OpenAPI：`5.0.0`
- Game SDK：`4.1.0`（不升版）
- App Bridge SDK：`3.3.0`（不升版）
- GDevelop：`5.6.276` Playmesh revision `20`，Tool Contract `4.1.0` / 51 工具
- Runtime 底包：`1.0.1+4`
- 目标平台：Android universal、Windows x64 portable

## 源码与契约验证

| 验证 | 结果 |
| --- | --- |
| `node tool/generate_sdk.mjs` | 通过；Game SDK `4.1.0`、App Bridge SDK `3.3.0` |
| 8 组 SDK、浏览器、类型声明、本地化、Authority 与 CLI Node 契约 | 全部通过 |
| `flutter analyze --no-pub lib test` | 通过，无静态分析问题 |
| `flutter test --no-pub` | 通过，共 1062 项 |
| `flutter test --no-pub`（`packages/playmesh_ui`） | 通过，共 1 项 |
| `go test ./...`（`go-core`、`go-server`、`dev-cli`） | 全部通过 |
| GDevelop `release-check` | 通过；正式资源目录保持不变 |
| `git diff --check` | 通过；只有工作树 LF 将按 Git 配置转换为 CRLF 的提示 |

完整 Flutter 测试初次运行发现三处旧版本断言：Tool Contract 仍期待 `4.0.0` / 50 工具，
设置页仍期待 App `4.2.1`。只将版本断言对齐到当前实现的 `4.1.0` / 51 工具和 App
`4.3.0` 后，定向重测 31 项与完整 1062 项测试均通过；没有为通过测试修改功能实现。

GDevelop 隔离流水线从锁定的官方 `5.6.276` 源码 ZIP 重放补丁，验证 123 个字节一致覆盖、
138 文件双向所有权集合、93 个固定模块契约、真实 Game SDK / Go Core 多人 E2E 和故障清理，
最终生成 2349 文件、安装展开 `178449867` 字节的 ZIP。隔离制品大小 `42137282` 字节，
SHA-256 为 `9f1a723d8c61d3df7085f02de95b2b848018069c33f352ba51fa3ff26cc0b321`，
与 `resources/GDevelop/update.json` 和现有正式 ZIP 一致。

Go 测试、GDevelop 多人 E2E 和正式构建首次在受限环境中遇到系统 Go 编译缓存拒绝访问；
允许读取同一工具链缓存后通过。该失败来自执行环境权限，不是代码、测试或制品失败。

## 正式构建

执行 `tool/build_release.ps1 -Target all`。脚本重新生成但不升级两套 SDK，验证 28 项发布
资源，完成 Android Release、APK 签名验证和 Windows x64 portable 构建，并以同批字节覆盖
`resources/app/playmesh.apk` 与 `resources/app/playmesh.zip`。

### Android

- Release 文件：`Playmesh-4.3.0-build30-android-universal.apk`
- Git 固定镜像：`resources/app/playmesh.apk`
- 大小：`148963451` 字节
- SHA-256：`5da768c4a9235ecd28d943a35fa7f7a64a2fe52ca008e422d0face6f07a08749`
- 签名：仓库正式 keystore；APK Signature Scheme v2 验证通过；签名者数量 `1`
- 包内资源：28 项全部通过长度与 SHA-256 复核
- 固定镜像：与带版本号 APK 长度、SHA-256 和逐字节比较均一致

### Windows

- Release 文件：`Playmesh-4.3.0-build30-windows-x64-portable.zip`
- Git 固定镜像：`resources/app/playmesh.zip`
- 大小：`28980605` 字节
- SHA-256：`39c1c1f26d4d2e79e39416a5a5dabdb990bd31c76542c0a1ba74d3e37631b7af`
- 结构：Windows x64 portable bundle，包含 App、Go Core、Developer CLI、Runtime exporter
  与 APK signer
- 包内资源：28 项全部通过长度与 SHA-256 复核
- 固定镜像：与带版本号 ZIP 长度、SHA-256 和逐字节比较均一致

## 发布策略复核

- `resources/app/playmesh.apk` 与 `resources/app/playmesh.zip` 由 Git LFS 跟踪并随主分支提交。
- GitHub Release 上传带版本号 APK、ZIP 和 `SHA256SUMS.txt`。
- Gitee 只同步代码、标签和 Release 元数据；按本次要求不上传 APK、ZIP 或校验文件。

## 非阻断提示与人工验收边界

- Android 构建提示 `mobile_scanner` 与 `speech_to_text` 后续需要迁移 Flutter 内置 Kotlin
  支持；不影响本次 APK 构建、v2 签名或资源验证。
- Windows 编译器提示依赖在 `/W3` 与 `/W4` 间覆盖；portable bundle 仍成功生成并通过资源复核。
- Authority RPC、大 Blob/File 往返、网络切换、Authority 离线，及 Android/Windows 安装包
  导出向导、系统保存/分享、多网卡二维码仍需跨设备实机验收。
- Go Server 放宽内容扫描提高第三方包兼容性，也扩大主动内容能力；上传成功不等于安全审核
  通过，运营环境仍应限制为受信发布源。
