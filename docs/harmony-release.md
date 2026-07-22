# HarmonyOS 构建与适配

## 支持范围

Playmesh 的鸿蒙目标基于 OpenHarmony SIG Flutter 3.22.3 与 OpenHarmony 5.0.0 Release Public SDK（API 12），工程目录为 `ohos/`，发布架构为 `ohos-arm64`。统一发布入口不会修改主项目依赖，而是把应用和鸿蒙工程复制到 `build/harmony-release/` 后构建。

| 能力 | 实现 |
|---|---|
| 本地游戏 WebView | `webview_flutter_ohos` |
| 文件选择与应用目录 | `file_selector_ohos`、`path_provider_ohos` |
| 系统分享 | 自研 HAR 通过 `ohos.want.action.sendData` 与只读 URI 授权接入 |
| 扫码 | Public SDK 不含 HMS `@kit.ScanKit`；鸿蒙包显示手动输入回退，不声明虚假的扫码能力 |
| 全屏与触觉 | `@playmesh/harmony_capabilities` ArkTS HAR |
| 加速度计与陀螺仪 | HAR 实现 `sensors_plus` 标准 EventChannel |
| 多人主机 Core | Go C ABI → AArch64 ELF → 异步 N-API → MethodChannel |

Android 的外部 `ACTION_VIEW` 文件接收桥接尚无鸿蒙等价实现，因此鸿蒙清单不声明该入口。应用内选择并导入文件不受此限制。

## 工具链

需要：

1. OpenHarmony 5.0.0 Release Public SDK（API 12）；生产签名可用 DevEco Studio 配置。
2. 支持 `flutter build hap` 的 OpenHarmony SIG Flutter 3.22.3 SDK。
3. OHOS Native SDK，其中必须有 `native/llvm/bin/clang.exe`、`llvm-nm.exe`、`llvm-readelf.exe` 和 `native/sysroot/`。
4. OpenHarmony SIG Go `go1.24.5.ohosv1r1`，必须支持 `openharmony/arm64` 和 `c-shared`。
5. 生产证书、Profile、私钥和签名配置。

所有下载型运行环境统一放在 `D:\KaiFaTool\runtime`，目录沿用上游发布包/分支的官方名称：

| 组件 | 默认目录 |
|---|---|
| OpenHarmony Public SDK | `D:\KaiFaTool\runtime\ohos-sdk-windows_linux-public` |
| OpenHarmony SIG Flutter | `D:\KaiFaTool\runtime\flutter-oh-3.22.3` |
| OH command line tools / OHPM / Hvigor | `D:\KaiFaTool\runtime\oh-command-line-tools` |
| OpenHarmony SIG Go | `D:\KaiFaTool\runtime\go\go-1.24.5-openharmony` |

统一发布脚本默认解析这些目录，无需每次传参。自定义路径可以用参数或环境变量提供：

```powershell
$env:PLAYMESH_HARMONY_FLUTTER = 'F:\sdk\flutter-ohos'
$env:PLAYMESH_HARMONY_SDK = 'F:\sdk\openharmony-public'
$env:PLAYMESH_HVIGOR_HOME = 'F:\sdk\oh-command-line-tools\hvigor'
$env:PLAYMESH_OHPM_BIN = 'F:\sdk\oh-command-line-tools\ohpm\bin'
$env:PLAYMESH_HARMONY_NDK = 'F:\sdk\harmony\native'
$env:PLAYMESH_HARMONY_GO = 'D:\KaiFaTool\runtime\go\go-1.24.5-openharmony'
```

首次准备 Go 工具链时执行：

```powershell
.\tool\install_harmony_go.ps1
```

该脚本从 OpenHarmony SIG 仓库的 `go1.24.5.ohosv1r1` tag 构建，并校验固定 commit `2d8b23f6923100d8c90d8add9299da2c9d032a20`，默认安装到 `D:\KaiFaTool\runtime\go\go-1.24.5-openharmony`。构建使用普通 Go 1.26.2 作为 bootstrap，但打包鸿蒙 Core 时不能使用 bootstrap Go。

`-HarmonySdk`、`-HarmonyFlutter`、`-HarmonyHvigor` 和 `-HarmonyOhpm` 可覆盖默认运行时目录。`-HarmonyNdk` 可以指向 `native/`，也可以指向包含多个 SDK 版本的父目录，脚本会寻找最新可用的 Native SDK。`-HarmonyGo` 可以指向工具链根目录或 `bin\go.exe`；未传入时依次读取 `PLAYMESH_HARMONY_GO`、`D:\KaiFaTool\runtime\go\go-*-openharmony` 和工作区构建目录，并拒绝不支持 `openharmony/arm64` 的 Go。

## Go Core 集成链

`go-core/harmony/main.go` 将现有 `go-core/mobile` 导出为稳定 C ABI：

- `PlaymeshCoreStart`：启动 Core，返回系统实际分配的监听地址。
- `PlaymeshCoreStop`：关闭服务器并释放端口。
- `PlaymeshCoreFree`：释放跨 ABI 返回的字符串。

`tool/build_go_core.ps1 -Target harmony` 强制使用 OpenHarmony SIG Go，设置 `GOTOOLCHAIN=local`、`GOOS=openharmony`、`GOARCH=arm64`、`CGO_ENABLED=1`，再通过 OHOS Clang/sysroot 生成 `libplaymesh_core.so`。鸿蒙构建使用独立的 `go-core/go.harmony.mod`：它只保留 Core 运行时依赖并声明 Go 1.24，不会因主模块用于 gomobile 的 Go 1.26.2 工具依赖而自动切换回普通 Go。构建后必须同时满足：

- 文件是 ELF；
- Machine 为 AArch64；
- SONAME 为 `libplaymesh_core.so`；
- 三个 C ABI 符号全部导出。

能力 HAR 的 `libplaymesh_core_napi.so` 使用 Node-API 异步工作队列调用 Go，避免 Start/Stop 阻塞 ArkUI 线程。ArkTS 的 `NativePlaymeshHarmonyCoreAdapter` 再把它接入 `playmesh/go_core_host`。`EntryAbility` 显式创建并注入这个 Adapter，Flutter 端因此与 Android 共用同一 MethodChannel 契约。

普通 Go 发行版没有该目标，不能用 `GOOS=linux` 的 runtime 替代。OpenHarmony SIG 分支包含 OpenHarmony arm64 runtime/cgo 适配；即使交叉编译成功，仍需在目标 HarmonyOS 真机验证网络、线程、TLS、前后台切换和退出生命周期。

## 构建与签名

内部测试包：

```powershell
.\tool\build_release.ps1 -Target harmony -AllowDebugSigning
```

生产包：

```powershell
.\tool\build_release.ps1 `
  -Target harmony `
  -HarmonySigningProfile F:\secure\playmesh-harmony-build-profile.json5
```

`-HarmonySigningProfile` 必须指向一份完整、可独立构建的 `ohos/build-profile.json5`。证书路径和密码只能放在安全目录或 CI secret 中。

成功产物：

```text
release/{VERSION}/Playmesh-{VERSION}-build{BUILD}-harmonyos-arm64.hap
```

生产构建只接受 `entry-default-signed.hap`；只有显式传入 `-AllowDebugSigning` 时，内部测试构建才接受 `entry-default-unsigned.hap`。两种模式都会检查：

```text
module.json
resources.index
libs/arm64-v8a/libapp.so
libs/arm64-v8a/libplaymesh_core.so
libs/arm64-v8a/libplaymesh_core_napi.so
```

任何 Core 库缺失都会使发布失败，最后才输出 HAP SHA-256。

## 验证

代码和发布契约：

```powershell
node tool\test_harmony_release.mjs

$env:GOCACHE = "$PWD\build\go-cache"
Set-Location go-core
go test ./...
```

安装真机后必须验证：

1. `start("0.0.0.0:0")` 返回非零动态端口。
2. `GET /health` 正常，并能创建、加入和停止多人会话。
3. WebSocket 消息转发和 Authority 路由正常。
4. App 前后台切换后 Core 仍符合产品生命周期。
5. 退出游戏和退出 App 后端口释放。
6. 连续启动/停止 100 次无崩溃、线程泄漏或残留监听端口。

本机已用上述默认运行时完成真实 arm64 HAP 构建及包内条目校验，产物大小、SHA-256、原生库和未执行项目见 [Playmesh 1.6.2 OpenHarmony 构建验证](verification/playmesh-1.6.2-harmony-build-2026-07-22.md)。该结果不替代目标设备上的签名安装、网络、传感器、分享和 Core 生命周期验证。
