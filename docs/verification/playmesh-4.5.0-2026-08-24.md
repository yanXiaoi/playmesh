# Playmesh 4.5.0 发布验证记录

## 验证信息

- 日期：2026-08-24
- App：`4.5.0+33`
- Runtime 底包：`1.0.2+7`
- Game SDK：`4.1.0`（不升级）
- App Bridge SDK：`3.3.0`（不升级）
- 目标平台：Android universal、Windows x64 portable；Runtime 另含 Android x86_64、
  Android arm64-v8a 和 Windows x64

## 源码与契约验证

| 验证 | 结果 |
| --- | --- |
| `node tool/generate_sdk.mjs` | 通过；Game SDK `4.1.0`、App Bridge SDK `3.3.0`，均未升级 |
| App Bridge、平台 UI、浏览器 SDK 与声明契约 | 通过 |
| `flutter test --no-pub`（主 App） | 通过，共 1076 项；主机/加入端/浏览器可见性、Bridge、Lifecycle 与 Runtime 清单均覆盖 |
| `flutter analyze --no-pub`（主 App） | 通过；无问题 |
| `flutter test --no-pub`（Runtime） | 通过，共 73 项 |
| `go test ./...`（Go Core） | 通过 |
| `git diff --check` | 通过；只有工作树换行转换提示 |

## Runtime 正式底包

执行 `runtime/src/tool/build_runtime_packages.ps1 -Force`，完整串行构建和验证三个底包：

| 制品 | 大小 | SHA-256 |
| --- | ---: | --- |
| `playmesh-runtime-x86.apk` | `51728025` | `e0c063dc57c951990f7a9739bfb35a3f6b419bd512725b18c81b0f0294240f05` |
| `playmesh-runtime-arm.apk` | `44682919` | `1815b88d90fc2d9ce033acb44be987d3a4cfa08e29f1e04f2a9d7a29f2961468` |
| `playmesh-runtime-win.zip` | `17584355` | `305ac851d16616f03fec24c4de76b16b195c3dd4d6e86ef069cad3a648776bbf` |

脚本验证 Android 单 ABI、APK v2 签名、16 KiB 对齐、PME1 加密包契约、四个主 App SDK
字节一致性，以及 Windows 私有 Go 解密宿主、包结构和密钥/源码泄漏门禁。

## App 正式构建

执行 `tool/build_release.ps1 -Target all`，重新生成但不升级两套 SDK。

### Android

- 文件：`Playmesh-4.5.0-build33-android-universal.apk`
- 固定镜像：`resources/app/playmesh.apk`
- 大小：`149229815` 字节
- SHA-256：`40f1c448777940bdeb73fe375fa357c799de06fc7c4e27e8ceb01eae861a7aba`
- 签名：正式证书 `CN=ZFJ`、RSA 2048；APK Signature Scheme v2 通过，签名者数量 1

### Windows

- 文件：`Playmesh-4.5.0-build33-windows-x64-portable.zip`
- 固定镜像：`resources/app/playmesh.zip`
- 大小：`29032519` 字节
- SHA-256：`b0061e9a92b0402a36e6ca42758b45da8e28100b539986ef729489d6a7d06e7e`
- HostX64 MSVC + Ninja 编译、链接和发布资源检查：通过（28 项发布资源检查）

## 人工验收边界

- 仍建议使用真实 Android 手势/返回键、扫码设备、两台局域网设备和 Windows WebView2 断网
  场景完成最终验收；自动化与包门禁不能替代这些外部环境。
- `mobile_scanner` 与 `speech_to_text` 的 Kotlin 迁移预警、Windows 依赖的 `/W3`/`/W4`
  覆盖提示为既有非阻断项，应在后续依赖升级中处理。
