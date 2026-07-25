# Playmesh 1.7.0 Binary/Bucket 与构建验证

## 范围

- 日期：2026-07-23
- App：`1.7.0+12`
- Go Core：`0.3.0`
- Core 协议：`1.1.0`
- Game SDK：`2.1.0`
- App Bridge SDK：`2.0.0`
- 主机环境：Windows，固定 Flutter 3.44.6 与 Go 1.26.2 工具链

本轮验证覆盖独立 Binary WebSocket、多逻辑 Channel、Authority 审核与主动推送、`sendLatest`、Bucket 二进制上传、JSON 私有目录、清除整个游戏 `data/`、SDK/AI 契约同步，以及 Android/Windows 发布产物。

同日追加同版本修订，版本号和构建号均不变：Binary Channel 支持一个上行帧指定多个目标，`send(data)` 快捷可靠广播，`sendLatest(data)` 快捷最新广播；`sendLatest(id, data)` 与 `sendLatest([id...], data)` 继续保留。没有新增 `sendLast` 方法。Authority `onForward` 上下文统一使用 `targetPlayerIds: string[]`，一次多目标帧只审核一次。

随后补充 Agent 提示词的本地 CLI 说明：`agent-common.txt` 明确记录完整 workspace URL 结构；生成项目 Agent 提示词时，平台使用当前选择的 Agent Base URL、实际 workspace ID 与实际 token 动态输出可直接执行的 `playmesh-cli to "http://.../dev/.../workspace?token=..."`，不再要求 Agent 猜测或拼接参数。

## 自动验证

### Go Core

```powershell
& 'D:\KaiFaTool\runtime\go\go-1.26.2\bin\go.exe' test ./...
```

在 `go-core/` 执行通过。覆盖：

- relay 模式不透明字节定向路由。
- 固定 Authority ID `authority` 的双向发送。
- Authority 原样通过、替换和拒绝。
- 已经开始的旧、新 Authority 审核都继续且各自投递。
- 只有 Authority 能创建/关闭 Channel。
- Authority 断开释放全部 Channel。
- `sendLatest` 只保留尚未发送的最新帧。

### Flutter

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' analyze --no-pub lib test
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' test --no-pub
```

结果：

- `lib test` 静态分析：无问题。
- Flutter 全量测试：139 项通过。
- Bucket 测试确认 JSON 写入 `data/json`、原始文件流写入 `data/data`、私有 JSON 不可通过网页读取、分享上传需要 token、目录不可枚举。
- “清除游戏数据”仍递归删除当前游戏的整个根 `data/`，因此 `data/json` 与 `data/data` 同时删除；`app/` 与 `cache/` 不受影响。
- 不读取、不迁移、不删除旧地址 `data/{bucket}.json`。

### SDK 与 CLI

以下命令均通过：

```powershell
node --check assets\playmesh-library\public\sdk\v1\playmesh.js
node tool\test_game_sdk.mjs
node tool\test_game_sdk_browser.mjs
node tool\test_sdk_declarations.mjs
node tool\test_app_bridge_sdk.mjs
```

浏览器 SDK 测试额外确认：

- `upload(file)` 使用原始 File 请求体。
- 上传请求携带 `X-Playmesh-Share-Token`。
- 返回值为同源 `/bucket/{bucket}/{timestamp-file}`。

Developer CLI 在 `dev-cli/` 执行固定 Go 工具链 `go test ./...` 通过。

### 同版本修订定向验证

按修订要求，没有重复运行 Flutter/Go 全量测试；只在沙箱外运行本次新增多目标与快捷广播功能的定向验证：

```powershell
& 'D:\KaiFaTool\runtime\go\go-1.26.2\bin\go.exe' test ./internal/session -run TestBinaryChannelMultiTargetAndBroadcastFanOut -count=1
node --check assets\playmesh-library\public\sdk\v1\playmesh.js
node tool\test_game_sdk.mjs
node tool\test_sdk_declarations.mjs
```

结果全部通过，确认：

- `send([playerA, playerB, playerC], data)` 只产生一个上行 Binary 帧，Core 对去重后的目标数组扇出。
- `sendLatest([playerA, playerB, playerC], data)` 按规范化目标集合并尚未发送的旧帧。
- `send(data)` 广播给当前 Channel 中除发送者外的在线成员。
- `sendLatest(data)` 对同一 Channel 的尚未发送广播只保留最新值。
- 单目标 `send(id, data)` 与 `sendLatest(id, data)` 重载仍保留。
- Authority 审核上下文始终为 `targetPlayerIds: string[]`；多目标帧只进入一次审核，替换数据对全部目标生效。
- 生成声明、机器契约和 AI 提示词均包含新重载，并断言不存在 `sendLast()`。

CLI 完整工作区命令使用以下沙箱外定向测试验证，测试文件 7 项全部通过：

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' test --no-pub test\core\developer\developer_web_gateway_test.dart
```

## Android 内部安装包

构建命令：

```powershell
.\tool\build_release.ps1 -Target android -AllowDebugSigning
```

`android/key.properties` 不存在，因此本产物明确使用 Android Debug 证书，只适合内部安装测试，不是生产签名包。

- 文件：`release/1.7.0/Playmesh-1.7.0-build12-android-universal.apk`
- 大小：95,789,555 bytes
- SHA-256：`80840DB39F227E117694262E3473714DCA178D662DE4F652D087A7C6074A033E`
- `apksigner`：通过
- 签名方案：APK Signature Scheme v2
- 证书：`C=US, O=Android, CN=Android Debug`
- 证书 SHA-256：`1E4BFC405CD7E5F6E63DDC0327A4141ACA7AA83D79D115BAC716652D312EF9C2`

构建存在 `mobile_scanner` 仍使用 Kotlin Gradle Plugin 的未来兼容性警告，不影响本次 APK 生成和签名验证。

## Windows x64 便携包

构建命令：

```powershell
.\tool\build_release.ps1 -Target windows
```

- 文件：`release/1.7.0/Playmesh-1.7.0-build12-windows-x64-portable.zip`
- 大小：23,559,322 bytes
- SHA-256：`F64FBBEB57613B9D8DDA620B849973553BB0F88F4827DC0C1DEFA77C4A753035`

统一发布脚本验证 ZIP 包含：

- `playmesh.exe`
- `playmesh-core.exe`
- `playmesh-cli.exe`
- `flutter_windows.dll`
- `WebView2Loader.dll`
- `data/app.so`
- `data/icudtl.dat`

Windows 当前产品规则只发布便携 ZIP，不生成 EXE/MSIX 安装器。CMake 的 JNI 缺失探测和 MSVC `/W3` 被 `/W4` 覆盖警告不影响当前桌面目标。

## 尚需设备验证

- Android APK 实际安装、启动、前后台切换与卸载。
- Windows ZIP 在目标机解压启动及 WebView2 Runtime 可用性。
- 两台或更多局域网设备上的 Binary Channel 吞吐、断线重连、Authority 审核时序和长时间内存稳定性。
- `img/audio/video/fetch` 对不同上传文件类型的真机播放与缓存行为。
- 生产 Android 签名；当前 APK 明确不是生产签名。
