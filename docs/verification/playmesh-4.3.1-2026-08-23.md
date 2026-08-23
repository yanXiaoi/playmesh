# Playmesh 4.3.1 发布验证记录

## 验证信息

- 日期：2026-08-23
- App：`4.3.1+31`
- Runtime 底包：`1.0.2+5`
- Game SDK：`4.1.0`（不升版）
- App Bridge SDK：`3.3.0`（不升版）
- 目标平台：Android universal、Windows x64 portable；Runtime 另含 Android x86_64、
  Android arm64-v8a 和 Windows x64

## 源码与契约验证

| 验证 | 结果 |
| --- | --- |
| `node tool/generate_sdk.mjs` | 通过；Game SDK `4.1.0`、App Bridge SDK `3.3.0` |
| App Bridge、声明、GDevelop surface/facade、生成物和本地化 6 组 Node 契约 | 全部通过 |
| `flutter analyze --no-pub`（主 App、Runtime） | 通过，无静态分析问题 |
| `flutter test --no-pub`（主 App） | 通过，共 1068 项 |
| `flutter test --no-pub`（Runtime） | 通过，共 73 项 |
| `flutter test --no-pub`（`packages/playmesh_ui`） | 通过，共 1 项 |
| `go test ./...`（`go-core`、`go-server`、`dev-cli`） | 全部通过 |
| `git diff --check` | 通过；只有工作树换行转换提示 |

语音定向测试确认自检会实际调用 `create({})`，语音插件先初始化引擎，只有初始化失败才执行
平台诊断；命令和异步错误均保留稳定错误码。Windows 主 App 与 Runtime 的 C++ 诊断宿主均
在正式 MSVC/Ninja 构建中通过编译。更新弹窗测试覆盖独立版本说明、`36ms` 状态、图标打开
操作，以及 360×780 窄屏下超长线路名称不溢出。

## Runtime 正式底包

执行 `runtime/src/tool/build_runtime_packages.ps1`，完整串行重建并验证三个底包：

| 制品 | 大小 | SHA-256 |
| --- | ---: | --- |
| `playmesh-runtime-x86.apk` | `51724149` | `b912cf7d4928a3900ec3112c0d6053c8899a4628c01df1cb62c567f1df53b893` |
| `playmesh-runtime-arm.apk` | `44679043` | `9cacd443e55ef87d4ea148b4f2db24de7432c453c3629aba773dbf1e4c485226` |
| `playmesh-runtime-win.zip` | `17580325` | `5ec2e896ae8d018055aea7aa3c4966ae576700e0f36a4947b46233086f166fe5` |

脚本验证 Android 单 ABI、APK v2 签名、16 KiB 对齐、PME1 加密包契约、四个主 App SDK
字节一致性，以及 Windows 私有 Go 解密宿主、包结构和密钥/源码泄露门禁。三份固定镜像与
`resources/runtime/update.json` 的平台级 SHA-256 一致。

## App 正式构建

执行 `tool/build_release.ps1 -Target all`，重新生成但不升级两套 SDK，完成 Android 正式签名
和 Windows x64 portable 构建，并验证 28 项发布资源。

### Android

- 文件：`Playmesh-4.3.1-build31-android-universal.apk`
- 固定镜像：`resources/app/playmesh.apk`
- 大小：`148962843` 字节
- SHA-256：`f81fbd48f4c9ea255c1853d1f0ccd46a320bda87562288b9a411197bc6503709`
- 签名：仓库正式 keystore；APK Signature Scheme v2 通过；签名者数量 `1`
- 固定镜像与带版本号 APK 长度和 SHA-256 一致

### Windows

- 文件：`Playmesh-4.3.1-build31-windows-x64-portable.zip`
- 固定镜像：`resources/app/playmesh.zip`
- 大小：`29010681` 字节
- SHA-256：`4ee7810f5467eda57f97e20dbc97153a7449220518e0db17ce058ffa556d1012`
- 新增 SAPI 诊断宿主以 UTF-8、`/W4 /WX` 编译通过
- 固定镜像与带版本号 ZIP 长度和 SHA-256 一致

## 非阻断提示与人工验收边界

- `mobile_scanner` 与 `speech_to_text` 仍提示未来需要迁移 Flutter 内置 Kotlin 支持；本次
  Android 正式构建、签名和包门禁不受影响。
- Windows 依赖仍存在 `/W3` 与 `/W4` 覆盖提示；主 App 与 Runtime 均成功链接并打包。
- 本轮没有处理麦克风权限。连接的 Android 15 设备缺少系统 RecognitionService，本机
  Windows 的默认 SAPI 录音输入不可用，因此没有把“原生桥可编译”误记为真实语音识别成功。
- 更新弹窗已由组件测试覆盖窄屏布局；不同系统字体缩放、实际浏览器启动和下载线路网络质量
  仍需目标设备交互验收。
