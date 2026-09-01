# Runtime 2.1.0+12 构建验证（2026-08-31，2026-09-01 发布重建）

## 范围与结果

按用户要求重新构建 Runtime Android x86_64、Android ARM64 和 Windows x64 底包，
把浏览器首次加入时自动生成并保存昵称的修改纳入安装包。已有昵称、手动改名、App 身份、
玩家 ID、重连与单机分享流程保持不变。

Runtime 从 `2.1.0+11` 递增构建号为 `2.1.0+12`；这是同一未发布语义版本的新构建，
Game SDK `4.3.0` 与 App Bridge SDK `3.5.0` 不变。2026-09-01 发布候选审计再次从当前
源码执行 `-Force` 全量重建；同轮另行重建并验证 GDevelop WebIDE 与主 App 正式包。

统一构建入口为 `runtime/src/tool/build_runtime_packages.ps1`。结果位于
`runtime/resource/v2.1.0-build12/`，旧 `v2.1.0-build11/` 归档保留；脚本已同步覆盖
`resources/runtime/` 的三个固定底包，并最后更新 `resources/runtime/update.json`。
该清单与归档中的 `runtime-packages.json` 均使用本次实际文件哈希。

## 产物

| 文件 | 平台/架构 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `playmesh-runtime-x86.apk` | Android x86_64 | 59,095,899 | `09606010e07c094753573c4d4fef20dae9c5e0220b88113a69e683eb6fae5fd9` |
| `playmesh-runtime-arm.apk` | Android ARM64 | 51,690,348 | `27e651b15df771799be0723dc0694a45d352ec2ca990592e93310e7e39cf0297e` |
| `playmesh-runtime-win.zip` | Windows x64 | 20,572,387 | `7bbd0e6d91e7d2e53ebe49c5e70c87f1de382a2a9faadf4f0b4883254e80e77e` |

三个包均核对了以下四个 SDK 文件，包内字节与主 App 当前生成物、构建清单记录一致：

| SDK 文件 | SHA-256 |
| --- | --- |
| `playmesh-main.js` | `c77cd7e343fb2eef200a85f5071ab26f74fa72d2fce9a236e714256dac50edc6` |
| `playmesh-main.d.ts` | `2cb65c19a606b88f601978581ef79626d6d88030d86d90b8af4e6863356ad2ca` |
| `playmesh-app.js` | `06344cfd91fb5e33b3f99820510e686ca2586b834ea98e7f67443886c0c9ed29` |
| `playmesh-app.d.ts` | `3c7806d835ebbd61346233a240834c58fa76c6a9b1a54b792e61fa706ad23123` |

各包内 `playmesh-main.js` 均包含“浏览器”加 4 位随机字母或数字的昵称生成，且不再包含
首次强制输入被取消的初始化分支。构建结束后临时 SDK 硬链接已清理，只保留目录标记。

## 已执行验证

- Runtime `dart analyze lib` 与 `dart analyze test`：通过，无问题。
- Runtime `flutter test --no-pub`：90 项通过。
- Go Core `go test ./...`：全部通过。
- `node tool/test_game_sdk_browser.mjs`：浏览器身份、自动昵称、刷新复用、手动改名、
  全屏、日志、重连和生命周期回归通过。
- Android build-tools `36.0.0`：单一 ABI、APK Signature Scheme v2、16 KiB ZIP 对齐、
  加密载荷结构、禁止私钥/源文件泄露和四份 SDK 哈希检查通过。
- Windows：HostX64 MSVC + Ninja、默认两路编译；原生私有 Go 解密桥测试、安装目录内
  载荷解密、必需 DLL/资源、可移植 ZIP 路径、私有文件排除和四份 SDK 哈希检查通过。
- 构建后再次从固定发布目录独立读取三个包，核对字节数、完整包 SHA-256、四份 SDK
  哈希和自动昵称代码；固定目录、版本归档、两份清单完全一致。

## 构建过程中的环境问题

1. 沙箱阻止 Go 工具链缓存写入；使用已授权的本机完整工具链权限重试后继续。
2. Java 在项目编译前出现 `Unable to establish loopback connection`，底层为
   `UnixDomainSockets.connect0: Invalid argument: connect`。仅为构建进程设置
   `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=F:/Project/flutter/playmesh/runtime/src/build/java-sockets`
   后，Gradle 诊断和 Android 编译通过。没有修改系统设置或防火墙；详细复现方法见
   [开发环境记录](../04-dev-env.md)。
3. 已有 Flutter/IDE 进程持有 SDK 批处理入口的全局文件锁，而 Runtime 包装器已经以
   `FLUTTER_ALREADY_LOCKED=true` 表示上层负责串行化。`flutter.bat` 在 Dart 启动前仍会
   重复等待该锁，因此构建入口增加可重入分支：仅在该显式标记存在时，使用同一 SDK 的
   Dart、`flutter_tools.snapshot` 与 package config 直接启动，不跳过 Flutter 构建逻辑。
4. Windows CMake 复用 Flutter 缓存中已核验的固定 NuGet `7.6.0`，WIL 与 WebView2 包均从
   本机 NuGet 缓存安装；没有更改依赖版本、下载地址、TLS 或完整性门禁。

三端制品属于同一次 2026-09-01 `-Force` 构建，期间 Runtime 源码与 SDK 未变化。统一脚本
完成全平台发布后才覆盖固定资源和清单，没有混入历史 APK。

## 限制与额外观察

- Android 底包沿用项目配置的 Android Debug 证书，v2 签名验证通过；它是供后续游戏
  导出流程处理的模板，不代表已使用生产发行签名。
- Windows 模板 EXE 的系统文件属性仍为 `1.0.0+1`，并未采用本次底包构建号；发行
  版本由 `update.json` / `runtime-packages.json` 标识为 `v2.1.0-build12`。
  `go-core/appnative/windows_runtime_executable.go` 在游戏导出时重写 FileVersion /
  ProductVersion 为游戏版本。本轮未顺带修改这一既有模板元数据问题。
- Kotlin/Gradle 的未来版本兼容性警告仍存在，本轮未升级相关插件。
- 未安装 Android 真机或模拟器，未运行 Windows 游戏窗口，未进行跨设备、长时在线或
  公网 TURN 手工验收；构建和包内检查不能替代这些验证。
- 该记录形成时尚未推送 Git 或发布远端资源；线上下载源只有在预发布流程成功推送后才会
  指向本次固定资源。
