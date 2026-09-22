# Playmesh 5.2.0 build 39 正式构建验证（2026-09-22）

## 范围

按 `docs/04-dev-env.md` 使用 `tool/build_release.ps1 -Target all` 串行构建 Android
universal 和 Windows x64 portable。App 为 `5.2.0+39`，包含 Bucket HEAD/Range、WebView
原生下载、仅存内存的分游戏队列、任务详情、手动隐藏入口和关闭游戏取消下载。
Game SDK `4.3.0`、App Bridge SDK `3.5.0` 保持不变。

## 制品

| 制品 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-5.2.0-build39-android-universal.apk` | 171,109,089 | `8e4f3ac2f342ac10517ca47ca21daa9a91a7a701856464a6b1b9ce9887de7deb` |
| `Playmesh-5.2.0-build39-windows-x64-portable.zip` | 33,988,115 | `426fab240574922d52827302922697003d5850a791e0b2a18a3aeabbf190d77e` |

版本化制品位于 `release/5.2.0/`；`resources/app/playmesh.apk`、`playmesh.zip` 与对应
版本化文件的字节数和 SHA-256 一致。`resources/app/update.json` 指向 `5.2.0`。

## 平台检查

- Android 包名 `top.zfjmm.playmesh`，`versionName=5.2.0`、`versionCode=39`；包含
  `arm64-v8a`、`armeabi-v7a`、`x86_64`。APK Signature Scheme v2 校验通过，签名者 1 个。
  证书 DN 为 `CN=ZFJ, OU=Unknown, O=Unknown, L=Unknown, ST=SC, C=ZH`，SHA-256 为
  `21be46f5cedeaac65ecac832d0587a2015ae6653a431e5857cc5f0687f0d786b`，与上一稳定版一致，
  未使用 Android Debug 证书。
- Windows HostX64 MSVC 19.50 + Ninja 正式构建成功。EXE 的 FileVersion 和 ProductVersion
  均为 `5.2.0+39`；ZIP 必需的 App、Core、CLI、签名工具、Flutter/WebView2 运行库和资源
  检查通过。
- 两个平台的 28 项发布资源均与构建前快照一致，Windows 主 App 包没有混入 Runtime 底包。
  Android Go AAR、Windows Go Core、Developer CLI、导出器与签名工具从本次源码构建。

## 回归记录

- App、Runtime 及共享下载组件的 Dart 静态分析零问题；Runtime 全量测试 93 项通过。
- 无范围的 `flutter analyze --no-pub` 长时间无输出，按项目超时处置终止本轮进程。
  静态分析结论来自已完成的直接 `dart analyze lib test`（主 App 额外包含共享下载包），
  不将该次中止的 Flutter 命令记为通过。
- 主工程首轮全量 1197 项通过、1 项失败：新 Runtime 尚未构建时，其版本/制品清单门禁
  检测到旧 `v2.1.1-build13`。最终底包同步后全量重跑：1198 项全部通过；Runtime 最终
  全量重跑 93 项全部通过。该失败已由实际重建、同步与回归消除，没有跳过门禁。
- 8 组 Node 检查通过：网页下载、File System Access、Game SDK、App Bridge、App 平台 UI、
  SDK 声明、浏览器 Game SDK、Windows WebView SDK 导航。Go Core 全量测试通过。
- 手机和桌面 Widget/截图检查通过；覆盖列表、详情、来源脱敏、隐藏不取消任务、已有任务
  更新不唤醒入口、新增任务恢复入口。
- 本次修改的 Dart 文件格式检查通过。根目录整体格式检查另发现 4 个本轮未修改文件的
  历史格式差异：`ordinary_web_package_import_dialog.dart`、
  `game_share_source_contract_test.dart`、`runtime_base_package_asset_contract_test.dart`、
  `windows_speech_recognition_host_contract_test.dart`；未为本次发布重排这些文件。

## 验证边界

本轮未独立安装并操作 Windows/Android 系统保存框、覆盖写、媒体拖动和退出下载中断。
构建和自动测试不替代这些实机项目，用户要求正式发行不等于确认实机验收通过。
Android POST/自定义头/一次性 URL 下载等限制见
[原生下载说明](../implementation/webview-downloads.md)。

Runtime 三端底包另见 [Runtime build14 验证记录](runtime-2.2.0-build14-2026-09-22.md)，
版本说明、升级和回滚要求见 [5.2.0 版本日志](../version/5.2.0.md)。
