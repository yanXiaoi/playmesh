# Playmesh 1.6.1 Android 发布构建验证（2026-07-21）

## 发布信息

- App：`1.6.1+8`
- Game SDK：`1.4.2`
- App Bridge SDK：`1.2.1`
- Android application ID：`top.zfjmm.playmesh`
- 本次按要求只构建 Android，没有生成 `1.6.1` Windows 产物。

## 修复验证

- Android/iOS WebView 宿主通过统一的 `gameSdkReceiveScript` 把 Bridge JSON 作为对象传给 `playmesh.__receive`，不再二次编码为字符串。
- Game SDK 接收端同时接受对象和 JSON 字符串；Node 回归测试使用字符串 `sdk.bootstrap` 成功完成 `playmesh.ready`。
- Game SDK、App Bridge SDK 和统一 `.d.ts` 生成/契约测试通过。
- `flutter analyze --no-pub` 通过，无诊断。
- Bridge、Developer Gateway、设置页和 Widget 相关 Flutter 回归共 23 项通过；Flutter 命令按项目约束在沙箱外串行执行。

## APK 产物

| 产物 | 大小 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-1.6.1-build8-android-universal.apk` | 95,465,703 字节 | `0A73F5EF367409404089E96BCBFE22928A7F4A7D2D437CE9ADB219310B8A0AD0` |

- `versionName=1.6.1`、`versionCode=8`、`minSdkVersion=24`、`targetSdkVersion=36`。
- APK Signature Scheme v2 验证通过，签名者数量为 1。
- 签名证书：`C=US, O=Android, CN=Android Debug`；证书 SHA-256 为 `1e4bfc405cd7e5f6e63ddc0327a4141aca7aa83d79d115bac716652d312ef9c2`。
- 项目未配置 `android/key.properties`，因此本次是 Debug 证书签名的内部 Release APK，不可作为应用商店生产签名包。
- 构建出现 `mobile_scanner` 关于未来 Kotlin Gradle Plugin 内置模式的兼容提示，不影响本次构建和签名验证。

尚未执行 Android 真机安装及 `zlxq` 的传感器/Bridge 实际运行验收。
