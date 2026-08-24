# Playmesh 4.4.0 发布验证记录

## 验证信息

- 日期：2026-08-24
- App：`4.4.0+32`
- Runtime 底包：`1.0.2+6`
- Game SDK：`4.1.0`（不升级）
- App Bridge SDK：`3.3.0`（不升级）
- 目标平台：Android universal、Windows x64 portable；Runtime 另含 Android x86_64、
  Android arm64-v8a 和 Windows x64

## 源码与契约验证

| 验证 | 结果 |
| --- | --- |
| Dart format（本轮 15 个 Dart 文件） | 通过；15 个文件均已符合格式 |
| `node tool/generate_sdk.mjs` | 通过；Game SDK `4.1.0`、App Bridge SDK `3.3.0`，均未升级 |
| App Bridge、声明、浏览器 SDK、GDevelop 存储/surface/facade/libGD、WebIDE 打包/来源策略和本地化共 17 项 Node 契约 | 全部通过 |
| 本轮主 App 定向 Flutter 测试 | 通过，共 37 项 |
| `flutter analyze --no-pub`（主 App、Runtime） | 通过，无静态分析问题 |
| `flutter test --no-pub`（主 App） | 通过，共 1074 项 |
| `flutter test --no-pub`（Runtime） | 通过，共 73 项 |
| `flutter test --no-pub`（`packages/playmesh_ui`） | 通过，共 1 项 |
| `go test ./...`（`go-core`、`go-server`、`dev-cli`） | 全部通过 |
| `git diff --check` | 通过；只有工作树换行转换提示 |

定向测试确认 App 同步 Bucket 的回环来源限制、逻辑名哈希 envelope 与读写语义；在线游戏库
分页失败保留已有结果并重试原页，首页与搜索结果都能打开详情且保留独立下载入口。Node 门禁
确认 GDevelop revision `21` 的 `storagetools` 迁移、99 个 SDK 调用成员、402 个锁定 libGD
函数和 WebIDE 确定性打包/来源策略仍一致。本地化门禁同步补充了新增动态按钮文案的显式键族。

## Runtime 正式底包

执行 `runtime/src/tool/build_runtime_packages.ps1`。x86_64 和 arm64 阶段各出现一次连续 60 秒
无输出，按文档中止并清理本轮子进程；随后重新构建并使用 `-Resume` 复核已完成的 x86_64，
最终完整串行构建和验证三个底包：

| 制品 | 大小 | SHA-256 |
| --- | ---: | --- |
| `playmesh-runtime-x86.apk` | `51725401` | `62b55d3b2525f1cbc87c48d7d19c02bdd59b483c8f0db1d05df3efd5acbac299` |
| `playmesh-runtime-arm.apk` | `44680295` | `9b16e52325e7fce9753c068a8ef96745a62efba5aec68b89bf2a2e5d5ab57cce` |
| `playmesh-runtime-win.zip` | `17581567` | `3a3f1bbe179d9e2a586b9f0a7b50fa7b81ee809b67e98ca18c1d33e286348263` |

脚本验证 Android 单 ABI、APK v2 签名、16 KiB 对齐、PME1 加密包契约、四个主 App SDK
字节一致性，以及 Windows 私有 Go 解密宿主、包结构和密钥/源码泄露门禁。三份固定镜像与
`resources/runtime/update.json` 的平台级 SHA-256 一致，专项清单测试 5 项通过。

## App 正式构建

执行 `tool/build_release.ps1 -Target all`，重新生成但不升级两套 SDK，完成 Android 正式签名
和 Windows x64 portable 构建，并在两个平台各验证 28 项发布资源。

### Android

- 文件：`Playmesh-4.4.0-build32-android-universal.apk`
- 固定镜像：`resources/app/playmesh.apk`
- 大小：`149144863` 字节
- SHA-256：`2fce9b2310730d0ce8d2e80d74d4ea0562eaf01594c68611b65367d105e25f7b`
- 签名：正式证书 `CN=ZFJ`，RSA 2048；APK Signature Scheme v2 通过；签名者数量 `1`
- 固定镜像与带版本号 APK 长度和 SHA-256 一致

### Windows

- 文件：`Playmesh-4.4.0-build32-windows-x64-portable.zip`
- 固定镜像：`resources/app/playmesh.zip`
- 大小：`29026544` 字节
- SHA-256：`96cc53b99b592e1df80185705a3ac71ce3a1ddf9c7b8a5b21979cecfb20d4c68`
- HostX64 MSVC + Ninja 编译、链接和 28 项包内资源检查通过
- 固定镜像与带版本号 ZIP 长度和 SHA-256 一致

GDevelop WebIDE `5.6.276` revision `21` ZIP 为 `42136911` 字节，SHA-256 为
`d461a1992291c9ee09297eb3d636a65b62347613ab0934639c0f01ed312522f2`，与
`resources/GDevelop/update.json` 一致。

## 非阻断提示与人工验收边界

- 自动化不能替代真实 Catalog 多来源网络、Android 真机、Windows WebView2、键盘/电视焦点、
  不同系统字体缩放和生产下载线路验收。
- Runtime 固定包的加密、签名与结构验证不能替代相机、麦克风、MIDI、Pose6D、扫码和跨设备
  联机的真实硬件验收。
- `mobile_scanner` 与 `speech_to_text` 仍提示未来需要迁移 Flutter 内置 Kotlin 支持；本次
  Android 正式构建、签名和包门禁不受影响。
- Windows 依赖仍存在 `/W3` 与 `/W4` 覆盖提示；主 App 与 Runtime 均成功链接并打包。
