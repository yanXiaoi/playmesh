# Playmesh 1.6.2 全平台构建验证（2026-07-22）

## 验证范围

- App：`1.6.2+9`（开发中，尚未正式发布）
- 目标：Android 通用 APK、OpenHarmony API 12 arm64 HAP、Windows x64 便携 ZIP
- 构建模式：Release；显式传入 `-AllowDebugSigning` 的内部测试构建
- Android/Windows Flutter：标准 Flutter `3.44.6 stable`，目录 `D:\KaiFaTool\runtime\flutter`
- OpenHarmony Flutter：OpenHarmony SIG Flutter `3.22.3`，目录 `D:\KaiFaTool\runtime\flutter-oh-3.22.3`
- OpenHarmony Go：OpenHarmony SIG `go1.24.5.ohosv1r1`，固定 commit `2d8b23f6923100d8c90d8add9299da2c9d032a20`

## 问题与修复

首次执行全平台构建时，Android 阶段从当前 `PATH` 选中了 OpenHarmony Flutter fork，且 `android/local.properties` 的 `flutter.sdk` 也指向该 fork。Android Gradle included build 因而编译旧版 `flutter.groovy`，报错 `unable to resolve class groovy.xml.QName`。

`tool/build_release.ps1` 已改为：

- Android 默认固定解析 `D:\KaiFaTool\runtime\flutter`，也可用 `-AndroidFlutter` 或 `PLAYMESH_ANDROID_FLUTTER` 覆盖。
- 检测并拒绝把含 OpenHarmony 构建入口的 Flutter fork 用于 Android。
- Android 构建前同步修正 `android/local.properties` 的 `flutter.sdk`。
- OpenHarmony 阶段无论成功或失败都会恢复进程环境，避免 OHOS SDK、Flutter 和 `PATH` 污染后续 Windows 构建。

## 执行命令

```powershell
.\tool\build_release.ps1 -Target all -AllowDebugSigning
```

命令退出码为 `0`，Android、OpenHarmony、Windows 三个阶段均完成。

## 构建产物

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `Playmesh-1.6.2-build9-android-universal.apk` | 95,550,155 字节 | `109D998D312B5FBF4A6A95A45C5458E89CFB556443CAF1BF5FC4E77A7F236EDD` |
| `Playmesh-1.6.2-build9-harmonyos-arm64.hap` | 33,424,471 字节 | `1EDB6719AA2F8801FFDF24740606954251C9075F13C73395620D627A9EDD4A05` |
| `Playmesh-1.6.2-build9-windows-x64-portable.zip` | 23,490,296 字节 | `4EB65939D6514ECC5C8EAFF77CB51191F71988C9D3E58C4481C6FAD129A355F9` |

## 包结构与签名检查

- Android APK：`apksigner verify --verbose` 通过，使用 APK Signature Scheme v2，签名者数量为 1。
- OpenHarmony HAP：包含 `module.json`、`resources.index`、`libs/arm64-v8a/libapp.so`、`libplaymesh_core.so`、`libplaymesh_core_napi.so`、`libflutter.so` 与 `ets/modules.abc`。
- Windows ZIP：包含 `playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、`flutter_windows.dll`、`data/app.so` 和所需插件 DLL。

## 自动回归

- PowerShell 解析检查：通过。
- `node tool/test_harmony_release.mjs`：通过。
- `git diff --check`：通过，仅有现有 Windows 行尾提示。

## 已知边界

- 本次使用 `-AllowDebugSigning`：Android APK 为内部调试签名，OpenHarmony HAP 未配置生产签名；两者均不是应用市场正式发布物。
- Android 正式发布需要配置 `android/key.properties`；OpenHarmony 正式发布需要传入 `-HarmonySigningProfile`，并只接受签名 HAP。
- 尚未执行 Android 或 OpenHarmony/HarmonyOS 真机安装、网络、传感器、系统分享和 Go Core 生命周期验收。
- Android 构建仍会提示 `mobile_scanner` 采用旧式 Kotlin Gradle Plugin 应用方式；本次构建不受影响，后续升级 Flutter/插件时应迁移。
