# 第二阶段状态：Go Core 和 Flutter-Go 通讯

## 基本信息

- 完成日期：2026-07-15
- 对应路线图：`docs/02-roadmap.md` 第二阶段
- 前置基线：`docs/status/phase-01-flutter-webview.md`
- 阶段目标：实现本地 Go Core 生命周期、`GET /health` 和 Flutter 基础调用链，并将 Core 随应用打包。

## 实际完成范围

- Go 默认示例已替换为可启动、可停止的 HTTP Core。
- `GET /health` 返回协议版本、Core 版本、启动时间、时间戳和 `requestId`。
- 未知路由和服务错误使用统一的 `core.error` 结构。
- Go 与 Flutter 使用结构化日志和同一 `requestId` 关联请求。
- Flutter 设置页展示 Core 的加载、在线、离线和错误状态，以及当前地址、版本、启动时间和请求 ID。
- Core 使用 `127.0.0.1:0` 监听系统分配端口；宿主启动后上报实际地址，Flutter 再创建 Client。
- Android 通过 gomobile AAR 和 MethodChannel 管理内置 Core。
- Windows 通过 Runner 同目录的 `playmesh-core.exe` 管理内置 Core，并从 `core.started` 日志读取实际地址。
- 游戏声明模型新增必填屏幕方向；进入 GamePage 后先切换方向再创建 WebView，退出后恢复系统方向。
- Windows 游戏容器新增 WebView2 实现，可从打包后的 Flutter assets 加载本地 HTML、CSS 和脚本。

## 代码对应关系

| 能力 | 主要代码 |
|---|---|
| Go 进程入口与生命周期 | `go-core/main.go`、`go-core/internal/server/` |
| 健康检查协议与业务 | `go-core/internal/health/` |
| Android gomobile API | `go-core/mobile/core.go` |
| Flutter 宿主生命周期 | `lib/core/lifecycle/`、`lib/core/services/go_core_runtime.dart` |
| Flutter HTTP Client | `lib/core/network/go_core_client.dart` |
| 状态协议与映射 | `lib/core/protocol/go_core_status.dart`、`lib/core/services/go_core_status_service.dart` |
| 设置页状态展示 | `lib/features/settings/settings_page.dart` |
| Android 原生桥接与依赖 | `android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java`、`android/app/libs/playmesh_core.aar` |
| Windows Core 打包 | `windows/CMakeLists.txt`、`tool/build_go_core.ps1` |
| 屏幕方向声明与生命周期 | `lib/models/game_summary.dart`、`lib/features/game/game_orientation_controller.dart`、`lib/features/game/game_page.dart` |
| Windows WebView2 | `lib/features/game/windows_local_game_web_view_io.dart` |

## 关键调用链

```text
SettingsPage
  -> GoCoreRuntime.check()
  -> GoCoreHost.start(127.0.0.1:0)
  -> Android Mobile.start() / Windows playmesh-core.exe
  -> 实际监听地址上报
  -> GoCoreClient(baseUri: actualAddress)
  -> GET /health + X-Request-ID
  -> Go HealthHandler
  -> HealthService
  -> core.health / core.error
  -> SettingsPage 状态展示
```

```text
游戏详情 -> 开始游戏
  -> GamePage
  -> GameOrientationController.enter(game.orientation)
  -> 方向切换完成
  -> GameLauncher -> 平台 WebView
  -> 返回或退出
  -> GameOrientationController.restore()
```

## 接口和所有权

- `GoCoreHost` 只管理打包 Core 的启动、停止和当前 endpoint，不发送业务请求。
- `GoCoreRuntime` 负责先启动宿主，再按上报 endpoint 创建 `GoCoreClient`。
- `GoCoreClient` 的 `baseUri` 必填，不提供固定端口默认值。
- `GoCoreStatusService` 负责把 Client 的状态与错误映射为 UI 可展示结果。
- Android `Mobile.Start` 和 Windows `core.started` 事件是实际地址的唯一来源。
- `GameOrientationController` 隔离平台方向 API，GamePage 只编排方向和 WebView 生命周期。

## 与原计划差异

- 原计划只要求 Flutter 连接 Core；实际补充了 Android AAR 和 Windows 进程打包，避免依赖用户安装 Go 或单独启动服务。
- 固定调试端口会与用户已有服务冲突，因此改为系统分配端口并建立启动地址上报契约。
- 最新产品要求游戏明确横屏或竖屏，因此在真实 `main.json` 解析器之前先把必填方向落实到 `GameSummary` 和 GamePage 生命周期。
- 第一阶段的 Windows 回退页不满足当前 Windows 验证标准，因此第二阶段收尾新增 WebView2 本地资源实现。

## 未完成和已知边界

- `main.json` 解析、安装和完整校验尚未实现；当前方向来自内置 `GameSummary` 假数据。
- Core 当前由设置页按需创建并在页面销毁时停止；后续联机会话需要提升为 App 级生命周期。
- 尚未实现 WebSocket、房间、联机码、二维码、浏览器加入和 Game SDK。
- 屏幕方向切换只在 Android/iOS 设备生效；Windows 桌面窗口没有设备旋转语义。
- Windows WebView2 依赖目标机器已安装 Microsoft Edge WebView2 Runtime。
- 构建、测试和实际运行结果记录在 `docs/verification/phase-02-2026-07-15.md`，不写入本阶段事实归档。

## 第三阶段起点

1. 将 `GameOrientation`、`modes`、`displayModes` 等规则落到真实 `main.json` 模型和校验器。
2. 将 Core 生命周期提升到 App 级，并通过受控上下文向 Game SDK 提供会话能力。
3. 定义版本化 WebSocket 协议和 TypeScript Game SDK。
4. 按 `docs/game/fishing-demo.md` 实现游戏包、主画面、控制端和完整联机闭环。
