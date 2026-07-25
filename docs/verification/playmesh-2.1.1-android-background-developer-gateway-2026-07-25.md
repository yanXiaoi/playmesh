# Playmesh 2.1.1 Android 后台开发者工作区验证

日期：2026-07-25

## 范围

- Android 开发者模式使用 `specialUse` Foreground Service 持有当前 FlutterEngine。
- Activity 切换后台或销毁后保留 Developer Gateway 与 Go Core。
- 锁屏期间使用 CPU WakeLock 和高性能 Wi-Fi Lock 继续处理局域网请求。
- 统一 Developer 操作元数据声明 `requiresForegroundView`。
- 后台、锁屏、熄屏、Activity 不存在或窗口失焦时，View 依赖操作返回
  `409 app_view_unavailable` 和机器可读状态。
- 项目、文件、校验、状态、日志等后台安全接口继续工作；停止运行允许后台执行。

## 自动验证

| 验证 | 结果 |
| --- | --- |
| `flutter analyze lib test` | 通过，无问题 |
| 开发者网关与运行控制器定向测试 | 15 项通过 |
| `flutter test --no-pub` | 168 项通过 |
| `flutter build apk --debug --no-pub` | 通过，生成 `build/app/outputs/flutter-apk/app-debug.apk` |

开发者网关测试覆盖：

- 锁屏状态下 `GET /dev/api/status` 与项目列表继续返回成功。
- 状态响应的 `appView.reason` 为 `device_locked`。
- 启动项目、能力自检和 WebView JavaScript 返回 HTTP 409。
- 错误码为 `app_view_unavailable`，详情包含
  `requiresForegroundView=true` 和完整 Activity/窗口/屏幕/锁屏状态。
- 后台停止当前运行仍返回成功。
- 开发者模式关闭后停止后台宿主。
- OpenAPI 版本为 `2.0.1`，View 依赖操作包含
  `x-requires-foreground-view=true`。

## 仍需 Android 真机验收

当前环境完成了代码级回归和真实 Android APK 编译，但没有替代以下真机测试：

1. 开启开发者模式后，从局域网电脑持续请求 `/dev/api/status`。
2. 依次切换到其他 App、返回桌面、熄屏并锁屏，确认后台安全接口持续响应。
3. 锁屏时请求项目启动、重启、能力测试和 WebView JavaScript，确认均返回
   `409 app_view_unavailable` 且 `reason=device_locked`。
4. 锁屏时请求停止当前运行，确认会话关闭且恢复 App 后位于游戏库。
5. 解锁并让 Playmesh 窗口重新获得焦点，确认 View 依赖操作恢复成功。
6. 关闭开发者模式，确认常驻通知消失、CPU/Wi-Fi 锁释放且端口立即不可访问。
7. 从最近任务划掉 Activity 后重新进入 App，确认复用同一个 FlutterEngine，
   工作区状态与端口没有生成第二份实例。
8. 在 Android 13 及以上分别允许和拒绝通知权限，确认系统仍按 Foreground
   Service 规则披露开发者模式运行状态。
