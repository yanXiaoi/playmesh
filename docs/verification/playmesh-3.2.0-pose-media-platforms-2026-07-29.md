# Playmesh 3.2.0 空间位姿、媒体与能力平台验证

## 验证范围

- Android `sensor.pose6d@1.0.0` 的 ARCore 位姿、共享 Session、独立重置原点和按需
  视频源生命周期。
- `playmesh.app.media` 公共运行时、适配器注册表、WebRTC 具体适配器与同终端
  App Bridge 协商。
- `CapabilityPlatform.WINDOWS/ANDROID/HTML` 枚举及
  `CapabilityDescriptor.supportedPlatforms` 单一平台声明。
- App bootstrap、WebView 权限、普通浏览器分享网关、开发者能力自检与项目创建/修改
  能力选择器的平台门控。
- SDK 生成物、类型声明、本地化、版本记录和 Android 构建。
- Developer API `3.0.0` 与 Developer CLI `1.5.0` 的能力描述符列表契约。

## 自动验证结果

| 验证 | 结果 |
| --- | --- |
| `flutter analyze lib test` | 通过，0 个问题 |
| `flutter test --reporter compact` | 通过，324 项 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_app_bridge_sdk.mjs` | 通过，包含完整 WebRTC offer/answer 与关闭链路模拟 |
| `node tool/test_app_platform_ui_sdk.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `node --check assets/playmesh-library/public/developer/workspace.js` | 通过 |
| `node tool/generate_sdk.mjs` | 通过，生成 Game SDK `3.2.0`、App SDK `3.1.0` |
| `go test ./...`（`dev-cli`、`go-core`、`go-server` 各自模块） | 通过 |
| `go test -race ./...`、`go vet ./...`（`dev-cli`） | 通过 |
| `go build ./...`（`dev-cli`） | 通过 |
| `flutter build apk --debug` | 通过 |
| `git diff --check` | 通过 |

Android 构建产物：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

构建仅报告现有第三方插件仍使用 Kotlin Gradle Plugin 的迁移提醒，没有编译错误。

## 平台声明断言

- 内置能力注册处只使用 `CapabilityPlatform` 枚举，不传裸平台字符串。
- 摄像头、麦克风声明 `WINDOWS`、`ANDROID`。
- MIDI、震动、`sensor.pose6d` 声明 `ANDROID`。
- 注册表拒绝空或重复的 `supportedPlatforms`。
- 当前平台不在列表时，即使插件驱动报告可用，创建、权限和自检仍统一报告不可用。
- App bootstrap 不执行能力、硬件或原生服务预探测；Android ARCore 只在实际创建
  `sensor.pose6d` 时启动，创建异常直接返回。
- 开发者一键自检调用真实 `create({})`，成功后立即 `dispose()`；创建或释放失败即
  报告失败。
- Developer API 与 App bootstrap 只输出 `supportedPlatforms`，不再输出
  `appSupported/htmlSupported`。
- 项目创建/修改能力选择器只渲染列表中的支持平台，不渲染缺席平台的“不支持”徽标。
- 游戏包仍只保存能力 code；既有 `playmesh.app.platform` 和
  `playmesh.app.device.getPlatform()` 值没有改变。

## 仍需人工真机验收

- 支持 ARCore 的 Android 真机安装、AR 服务缺失/更新流程和相机权限拒绝路径。
- 行走、旋转、暂停/恢复后的 XYZ 与 XYZW 四元数稳定性。
- `recenter()` 后坐标原点与多个实例互不干扰。
- 打开与关闭视频后的画面方向、宽高偏好、帧率和资源回收。
- WebView 中反复打开/关闭 WebRTC 媒体会话，以及退出游戏、重载页面、切后台后的相机
  指示与资源释放。
- Windows 与 Android 开发者工作区中创建/修改项目时的平台徽标视觉显示。
