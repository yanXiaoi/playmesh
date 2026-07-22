# Playmesh 1.6.0 正式发布构建验证（2026-07-21）

## 发布信息

- App：`1.6.0+7`
- Game SDK：`1.4.1`
- App Bridge SDK：`1.2.1`
- Developer API / OpenAPI：`1.4.0`
- Developer CLI：`1.1.0`
- Android application ID：`top.zfjmm.playmesh`
- 发布目录：`release/1.6.0/`

## 发布产物

| 产物 | 大小 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-1.6.0-build7-android-universal.apk` | 95,465,631 字节 | `664FD223F8794EE13449A4D7C49027663364A32F9E798E3C243D6B445F228C8E` |
| `Playmesh-1.6.0-build7-windows-x64-portable.zip` | 23,459,885 字节 | `10DF93658E02512654057B7101F37EAAE3EDF1C4E56612E32C4311C8D789B044` |

## 自动验证

- Dart 静态分析通过，无诊断。
- 本次相关 Flutter 单元与 Widget 回归测试通过；Flutter 测试按项目约束在沙箱外执行。
- Game SDK、App Bridge SDK、统一 `.d.ts` 声明和桌面 CLI 跟随构建的 Node 校验通过。
- Developer Gateway 测试确认 AI/Agent 提示词包含同次生成的完整 `playmesh.d.ts`、`playmesh-app.d.ts`，并以声明中的方法、参数、返回值、类型、版本和中文 JSDoc 为唯一 SDK 接口事实源。
- 单机 Bridge 回归测试确认 `sdk.ready` 无需多人 Session 即可完成；Widget 预览不再提前打开本地存储。
- Developer CLI `--version` 输出 `playmesh-cli 1.1.0`。
- CLI SDK 安装目录为 `playmesh/sdk`，并经测试确认不会清理旧 `.playmesh/sdk` 内容。

## Android 验证

- Release universal APK：`versionName=1.6.0`、`versionCode=7`、`minSdkVersion=24`、`targetSdkVersion=36`。
- APK Signature Scheme v2 验证通过，签名者数量为 1。
- 签名证书：`C=US, O=Android, CN=Android Debug`；证书 SHA-256 为 `1e4bfc405cd7e5f6e63ddc0327a4141aca7aa83d79d115bac716652d312ef9c2`。
- 项目没有 `android/key.properties`，因此本次通过 `-AllowDebugSigning` 生成内部 Release APK。该 APK 可供内部安装验证，不可作为应用商店生产签名包。

## Windows 验证

- HostX64 MSVC + Ninja Release 构建成功。
- `playmesh.exe` 的 FileVersion 与 ProductVersion 均为 `1.6.0+7`。
- Ninja 发布脚本从 `pubspec.yaml` 显式向 CMake 注入版本，避免 Flutter ephemeral 配置残留旧版本。
- Bundle 共 139 个文件、52,297,299 字节；内置 `playmesh-cli.exe --version` 输出 `playmesh-cli 1.1.0`。
- ZIP 已确认包含 `playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、`flutter_windows.dll`、`WebView2Loader.dll`、`data/app.so` 和 `data/icudtl.dat`。

## 构建入口与限制

- 统一发布命令：`tool/build_release.ps1 -Target all -AllowDebugSigning`
- Windows 构建命令：`tool/build_windows_release_ninja.ps1`
- 构建期间出现 `mobile_scanner` 关于未来 Kotlin Gradle Plugin 内置模式的兼容提示，不影响本次产物。
- 尚未执行 Android 真机安装/升级与传感器输入、Windows 解压启动、局域网多设备日志隔离、WebView2 防火墙交互及生产签名验收。
