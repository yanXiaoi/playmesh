# Playmesh 1.2.0 正式发布构建验证（2026-07-18）

## 发布信息

- App：`1.2.0+3`
- Android application ID：`top.zfjmm.playmesh`
- Android：Release universal APK
- Windows：x64 Release 便携 ZIP，不生成安装程序
- 发布目录：`release/1.2.0/`

## 产物

| 产物 | 大小 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-1.2.0-build3-android-universal.apk` | 95,005,380 字节 | `C41D24AA39BDD5C3F70A6139C8EA6184D1ADDC133EBD87E6E0B59A8C8495D521` |
| `Playmesh-1.2.0-build3-windows-x64-portable.zip` | 20,541,143 字节 | `BD2588BB9792C9F20B942C2D95A2E47019780A32A19F93F5A655969D7318D5CF` |

## Android 验证

- `versionName=1.2.0`、`versionCode=3`、`minSdkVersion=24`、`targetSdkVersion=36`。
- APK Signature Scheme v2 验证通过。
- 本次产物使用当前项目已有的 Android Debug 证书：可内部安装，不可作为应用商店生产签名包。
- 后续生产发布由 `android/key.properties` 注入未提交的正式 keystore；统一脚本没有正式签名时默认拒绝构建，只有显式传入 `-AllowDebugSigning` 才允许内部包。

## Windows 验证

- `playmesh.exe` 文件版本和产品版本均为 `1.2.0+3`。
- Release bundle 共 135 个文件、45,249,385 字节。
- 便携 ZIP 已确认包含 `playmesh.exe`、`playmesh-core.exe`、`flutter_windows.dll`、`WebView2Loader.dll`、`data/app.so` 和 `data/icudtl.dat`。
- Windows Release 在沙箱外通过 HostX64 MSVC + Ninja 构建，绕过本机 Visual Studio 18 MSBuild 文件跟踪层的无响应问题。

## 可复用入口

- 统一发布：`tool/build_release.ps1`
- Windows x64 bundle：`tool/build_windows_release_ninja.ps1`
- 环境、签名、超时和产物规则：`docs/04-dev-env.md`

本记录只证明编译、打包、签名结构与静态入口完整；尚未执行 Android 真机安装/升级、Windows 解压运行、WebView2 实际渲染或防火墙交互验收。
