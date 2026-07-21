# 第一阶段状态：Flutter 基础壳和静态 WebView

## 阶段信息

- 阶段：第一阶段
- 状态：已完成
- 完成日期：2026-07-15
- 路线图基线：`docs/02-roadmap.md`（2026-07-15 版本）
- 下一阶段：Go Core 和 Flutter-Go 基础通讯

## 目标与实际范围

本阶段目标是用最少依赖验证 Flutter 页面结构、游戏启动流程和本地 WebView 容器，不接 Go 与真实联机。

实际完成：

- Playmesh 首页、用户资料、游戏库、游戏详情、游戏页和设置页。
- `UserProfile`、`GameSummary`、`LocalGameEntry` 最小模型和假数据。
- 游戏库展示名称、版本、简介、人数与模式，并进入游戏详情。
- 游戏详情展示完整摘要，并提供唯一“开始游戏”入口。
- 游戏页使用全屏 `Stack` 让 WebView 占据整个页面主体。
- 右上角悬浮区提供返回详情、重新开始、退出到游戏库和更多操作。
- 重新开始通过更换运行时 Key 销毁并重建 `GameLauncher`/WebView 子树。
- `LocalGameWebView` 使用 `webview_flutter` 加载 `assets/demo_game/index.html`。
- 内置 HTML 使用本地 CSS 和生命周期计时脚本，不注入原生 JS Bridge。
- 不支持平台或测试环境使用明确的静态回退界面。

最终用户流程：

```text
首页
  -> 游戏库
  -> 游戏详情
  -> 开始游戏
  -> 全屏 WebView 游戏页
      -> 返回游戏详情
      -> 退出到游戏库
      -> 重新开始并刷新 WebView
```

## 未完成与排除项

以下内容按路线图明确排除，不属于第一阶段缺口：

- Go Core、Flutter-Go 通讯和 `/health`。
- 真实联机会话、联机码、二维码和浏览器加入。
- WebSocket、Game SDK 和真实游戏包系统。
- 原生键盘、USB、摄像头和传感器输入。
- iOS 发布、云端、创意工坊、体感和 AI 游戏生成。

当前资料和游戏均为假数据。昵称编辑、头像选择和唯一 ID 持久化尚未接入本地存储；二维码、链接和联机信息入口只显示后续阶段提示。

## 代码基线

```text
lib/
  main.dart
  app.dart
  models/
    user_profile.dart
    game_summary.dart
    local_game_entry.dart
  features/
    home/home_page.dart
    profile/profile_page.dart
    games/game_library_page.dart
    games/game_detail_page.dart
    game/game_page.dart
    game/game_launcher.dart
    game/local_game_web_view.dart
    settings/settings_page.dart

assets/demo_game/
  index.html
  style.css

test/widget_test.dart
```

## 调用链与边界

启动调用链：

```text
GameLibraryPage
  -> GameDetailPage
  -> GamePage
  -> GameLauncher
  -> LocalGameWebView
  -> WebViewController.loadFlutterAsset()
  -> assets/demo_game/index.html
```

生命周期调用链：

```text
返回
  -> Navigator.pop()
  -> GameDetailPage

退出
  -> Navigator.popUntil('/games')
  -> GameLibraryPage

重新开始
  -> runtimeGeneration + 1
  -> KeyedSubtree Key 改变
  -> 旧 LocalGameWebView dispose
  -> 新 LocalGameWebView 加载同一本地入口
```

页面只传递用户意图和 `GameSummary`，不直接创建 `WebViewController`、拼接网络地址或接触 Go。WebView 创建与本地入口加载集中在 `LocalGameWebView`。

## 重要决策

| 背景 | 选择 | 替代方案 | 影响与回滚 |
|---|---|---|---|
| 用户需要先了解游戏再启动 | 在游戏库和运行页之间增加独立详情页 | 游戏库直接启动 | 导航多一层但语义清晰；可删除详情路由并恢复直接启动 |
| 游戏内容应占据主要空间 | 游戏页使用全屏 `Stack` 和右上角图标控件 | AppBar + 固定状态卡 | WebView 空间最大化；可恢复普通 Scaffold 布局 |
| 重新开始必须刷新运行时 | 使用递增 Key 重建整个 WebView 子树 | 只调用页面 reload | 同时重置网页和 Widget 生命周期；可改为向 Launcher 暴露 reload 接口 |
| 内置页面需要展示生命周期 | 对可信内置 asset 启用 JavaScript，不提供原生桥接 | 禁用 JavaScript | 能运行计时脚本；若页面改为纯静态可重新禁用 |

## 依赖与环境

- Flutter 3.44.6 stable
- Dart 3.12.2
- `webview_flutter: ^4.13.0`
- 内置资源：`assets/demo_game/`

常用验证命令：

```powershell
flutter pub get
dart format lib test
flutter analyze
flutter test
```

## 测试与验收

2026-07-15 自动验收结果：

- `dart format lib test`：通过，14 个文件已检查。
- `flutter analyze`：通过，`No issues found`。
- `flutter test`：通过，共 4 条 Widget 测试。
- 覆盖首页入口、资料/设置导航、游戏库到详情再启动、重新开始后运行时重建、返回详情、退出到游戏库和全屏游戏表面。

附加构建检查：

- `flutter build windows --debug` 未完成。CMake、MSBuild 和编译器进程长时间无 CPU 变化后被终止，没有生成可作为通过证据的结论。
- 按 `docs/04-dev-env.md`，阶段归档不以 Android 模拟器结果为依据。

## 已知风险

- Widget 测试环境不创建 Android/iOS 平台 WebView，主要验证加载边界、导航和生命周期 Key；平台 WebView 的像素级渲染不在自动测试覆盖内。
- Windows 不属于 `webview_flutter` 当前启用平台，运行时会展示本项目定义的回退界面。
- 用户资料修改没有持久化，App 重启后仍使用假数据。
- 游戏声明目前是 `GameSummary` 假数据，不是 `main.json` 解析结果。
- 额外 Windows 原生构建挂起原因尚未诊断；开始桌面平台工作前需要单独排查工具链或残留进程。

## 与原计划差异

- 原计划写作“游戏库直接开始游戏”；最终按产品流程增加游戏详情页，改为“游戏库 -> 游戏详情 -> 开始游戏”。
- 原计划只要求返回后可再次进入；最终补充了显式返回、退出和重新开始三种不同动作，并为刷新建立了可测试的重建边界。
- 没有引入 `go_router` 或状态管理库。第一阶段路由和假数据规模较小，继续使用 Flutter 自带 Navigator，减少无必要依赖。

## 下一阶段起点

第二阶段从 `go-core/` 默认脚手架开始，不把现有示例程序视为 Core 实现。建议第一条垂直链路为：

```text
SettingsPage
  -> GoCoreStatusService
  -> GoCoreClient
  -> GET /health (requestId)
  -> Go HealthHandler
  -> HealthService
  -> 结构化状态或错误
```

开始前应先删除 `go-core/main.go` 的 IDE 默认模板逻辑，定义启动/停止边界、结构化日志和成功/失败测试；不要提前扩展 WebSocket、会话、二维码或 Game SDK。
