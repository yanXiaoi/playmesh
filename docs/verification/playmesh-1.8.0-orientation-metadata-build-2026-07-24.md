# Playmesh 1.8.0 角色方向、发布元数据与双平台构建验证

## 验证范围

- App：`1.8.0+13`
- Game SDK：`2.2.0`
- App Bridge SDK：`2.1.0`
- Developer API / OpenAPI：`1.6.0`
- Developer CLI：`1.3.0`
- Go Core / Core 协议：`0.3.0` / `1.1.0`

本轮验证覆盖单屏多人主画面/控制器独立方向、App/WebView 原生全屏、普通浏览器无提示层尽力自动全屏和悬浮工具栏重试、角色化能力声明、只读作者与最后上传时间、设备时区展示、Agent/CLI/App 发布历史以及 Android/Windows 发布产物。

## 沙箱外验证

按 `docs/04-dev-env.md` 使用固定工具链串行执行：

- `dart analyze lib test`：通过，无问题。
- `flutter analyze --no-pub lib test`：通过，无问题。
- `flutter test --no-pub`：通过，`147` 项测试全部成功。
- `go-core` 执行 `go test ./...`：通过。
- `dev-cli` 执行 `go test ./...`：通过。
- `node tool/test_game_sdk.mjs`：通过。
- `node tool/test_game_sdk_browser.mjs`：通过。
- `node tool/test_app_bridge_sdk.mjs`：通过。
- `node tool/test_sdk_declarations.mjs`：通过。
- `node tool/test_default_authority_service.mjs`：通过。
- `node tool/test_desktop_cli_packaging.mjs`：通过。
- `node --check assets/playmesh-library/public/developer/workspace.js`：通过。
- `git diff --check`：通过，仅报告工作区既有的 LF/CRLF 转换提示。

关键回归确认：

- 单屏多人缺失 `controllerOrientation` 会被拒绝，其他模式声明该字段也会被拒绝。
- 非单屏多人声明 `controllerRequired` 会被拒绝；运行时只向当前页面角色暴露对应能力。
- App Bridge 的 `setFullscreen(true, orientation)` 会把角色方向传入原生宿主。
- 普通浏览器不会创建 `playmesh-browser-fullscreen` 提示层；SDK 直接尽力自动全屏并锁定方向，工具栏全屏按钮可再次请求。
- 上传时使用当前 App 昵称与 Unix 毫秒时间戳覆盖包内作者和最后上传时间。
- `id`、`author`、`lastModifiedAt` 不能通过项目设置修改。
- Agent/CLI/App 同 ID 发布进入项目本地历史，整包恢复会同时恢复 `main.json`、`capabilities.json` 与 `app/`，并保留 `data/`、`cache/`。

## Android

构建命令：

```powershell
.\tool\build_release.ps1 -Target android -AllowDebugSigning
```

机器未配置 `android/key.properties`，因此本次为明确允许 Debug 证书的内部安装版 Release APK，不是生产商店签名包。

- 产物：`release/1.8.0/Playmesh-1.8.0-build13-android-universal.apk`
- 大小：`96,923,127` 字节
- SHA-256：`B8660266E41EBCDD9A7E41E1E0BA364607D03CF4FCCBA83C1A9C8447517D7CDA`
- 包名：`top.zfjmm.playmesh`
- `versionName`：`1.8.0`
- `versionCode`：`13`
- `minSdkVersion`：`24`
- `targetSdkVersion`：`36`
- `apksigner verify --verbose`：通过，APK Signature Scheme v2 有效。
- 签名证书：`C=US, O=Android, CN=Android Debug`。

## Windows

构建命令：

```powershell
.\tool\build_release.ps1 -Target windows
```

- 产物：`release/1.8.0/Playmesh-1.8.0-build13-windows-x64-portable.zip`
- 大小：`23,569,630` 字节
- SHA-256：`FD905DE8D1A704F9945C0CEF5B1898B60B1C112FE3D1F6A0774C0396C2FDE81F`
- `playmesh.exe` 文件版本 / 产品版本：`1.8.0+13`
- `playmesh-cli.exe --version`：`playmesh-cli 1.3.0`
- ZIP 已核对包含 `playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、`WebView2Loader.dll` 和生成的 `public/sdk/v1/playmesh.js`。
- Windows Ninja 构建前会校验并清理工作区 `build/flutter_assets` 共享缓存；重建后已确认 ZIP 不再包含源码中不存在的旧 `fishing-demo` 资源。
