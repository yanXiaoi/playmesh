# Playmesh 4.1.0 发布验证记录

## 验证信息

- 日期：2026-08-03
- App：`4.1.0+27`
- Developer API / OpenAPI：`4.1.0`
- 目标标签：`v4.1.0-build27`
- 目标平台：Android universal、Windows x64 portable

## 源码与契约验证

| 命令 | 结果 |
| --- | --- |
| `flutter analyze --no-pub lib test` | 通过，无静态分析问题 |
| `flutter test --no-pub` | 通过，共 381 项 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `git diff --check` | 通过 |

SDK 声明检查同时验证每个全局启用 locale 都声明了完整提示词集合、对应文件非空且位于
自身语言目录、文件已包含在 Flutter 资产清单中，以及所有 App locale 的动态提示词词条
集合一致。英文项目提示词集成测试验证生成内容不包含中文固定文案。

## 发行资源预检

`tool/verify_release_assets.ps1` 按
`assets/playmesh-localization/manifest.json` 的启用 locale 遍历
`prompts/manifest.json` 中的语言文件映射，不包含任何特定语言分支。预检与产物复核均覆盖：

- 14 个 `zh-CN` / `en-US` AI 提示词文件；
- AI 提示词清单；
- 全局本地化清单；
- 4 个 App / Go Server 全局语言包。

Android APK 与 Windows bundle 中的上述 20 项资产均与预检快照的字节长度和 SHA-256
一致。

## 构建结果

执行 `tool/build_release.ps1 -Target all`。Android 正式构建一次成功；Windows 首次配置时
NuGet 官方 CDN 连接中断。构建逻辑随后支持在 SHA-256 与固定 NuGet 7.6.0 哈希完全一致
时复用标准 Flutter Windows 构建缓存，再执行 `tool/build_release.ps1 -Target windows`
成功。NuGet 包依赖仍通过项目固定版本恢复。

### Android

- 文件：`Playmesh-4.1.0-build27-android-universal.apk`
- 大小：`140279200` 字节
- SHA-256：`f8d72aba4166ff49ec17590c69e20900ab12f841eb71f8162a803abc8587899a`
- 签名：正式 keystore；APK Signature Scheme v2 验证通过；签名者数量 `1`
- 包内资源：20 项全部通过长度与 SHA-256 复核

### Windows

- 文件：`Playmesh-4.1.0-build27-windows-x64-portable.zip`
- 大小：`26026156` 字节
- SHA-256：`04fbc10c8c0ebdb287ffac351bfc3e3e6652129d0a33724cdb1646dd055ccf48`
- 结构：Windows x64 Portable bundle，必需运行文件验证通过
- 包内资源：20 项全部通过长度与 SHA-256 复核

## 人工验收边界

- 自动化已覆盖 locale 解析、语言文件完整性、用户覆盖隔离、工作区 API 调用契约、英文
  提示词生成和最终制品资源一致性。
- App 内真实语言切换、提示词编辑/恢复/下载交互以及 Android/Windows 实机显示仍属于
  发布后的人工体验验收范围。
