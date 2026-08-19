# Playmesh 4.2.0 手动检查更新实现

## 范围与边界

本功能只检查并展示 App 更新，不下载、不校验安装包、不安装，也不在 App 内打开下载页。
用户选择下载线路后，App 只把经过校验的 HTTPS 地址交给系统默认浏览器。

打包资源只有统一资源渠道目录 `assets/app/App.json`。`assets/app/app_update.json` 只是远端
动态数据格式示例，不进入 Flutter 资源清单，也不作为运行时回退数据。

## 调用链

```text
设置页“检查更新”
  -> SettingsPage / _AppUpdateDialog
  -> AppUpdateChecker.checkForUpdates()
  -> AppUpdateService 读取 assets/app/App.json
  -> AppResourceSourceCatalog 只投影存在 app 字段的渠道
  -> NamedDownloadEndpointList 校验实际使用的 App 清单源
  -> EndpointDocumentLoader 并发请求全部远端 JSON
  -> AppUpdateManifest 严格解析版本、说明和各平台 downloads
  -> SemanticVersion 选择版本最大的有效清单
  -> 按当前 TargetPlatform 选择 downloads
  -> EndpointProbeService 并发检测下载线路延迟
  -> UI 展示当前版本、远端版本、更新说明、线路名称和延迟状态
  -> 用户点击“浏览器打开”
  -> url_launcher LaunchMode.externalApplication
  -> 系统默认浏览器
```

版本选择先于平台选择。最高版本即使没有当前平台字段，也仍是结果源，界面明确显示当前
平台没有下载信息；不会退回较旧但有当前平台下载的清单。同版本按 `App.json` 中 `app`
投影后的原始渠道顺序稳定选择第一个有效源。

## 数据模型与校验

- `App.json` 是 `{name, <resourceKey>: <manifest URL>, ...}` 渠道数组；资源键不设白名单，
  后续可以直接增加其他资源的远端 JSON 入口。
- App 更新只读取 `app` 字段，缺少该字段的渠道跳过；其他资源字段和值不在这条链路校验。
- 投影出的 App 清单源最多 16 项，名称、URL 不允许重复；清单源和下载线路只接受无凭据、
  无 Fragment 的 canonical HTTPS URL。
- 远端版本使用严格 `MAJOR.MINOR.PATCH`，并复用项目 `SemanticVersion` 比较。
- 远端清单只接受 `version`、`releaseNotes` 和已支持的平台字段；未知字段拒绝。
- 平台字段只包含 `downloads`，下载线路继续复用 `NamedDownloadEndpointList` 的数量、名称
  和 URL 安全校验。
- 更新说明最多 20000 字符，拒绝不安全控制字符；Flutter 只以纯文本显示。
- 支持的平台键为 `windows`、`android`、`ios`、`macos`、`linux` 和 `web`。

## 成功、失败与日志

- 全部清单源同时请求；单源超时、网络失败或格式错误只淘汰该源。
- 至少一个清单有效时继续选择最高版本，并在界面显示有效源数量。
- `App.json` 不是有效 JSON、没有任何 `app` 渠道或实际使用的 App 端点无效，与“全部远端
  清单无效或不可达”使用不同错误状态。
- 下载线路测速失败不会隐藏线路，用户仍可选择由浏览器尝试打开。
- 每次检查生成 `app-update-{microsecondsSinceEpoch}` 请求 ID；日志记录开始、坏源淘汰、
  最终来源、版本、有效源数量和下载线路数量，不记录响应正文。
- 外部浏览器启动失败返回 `false` 并显示明确提示，不尝试 App 内下载或安装。

## 验证入口

- `test/core/update/app_update_models_test.dart`：清单模型、未知字段和 HTTPS 边界。
- `test/core/update/app_update_service_test.dart`：并发请求、坏源隔离、最大版本优先、平台
  选择顺序和外部浏览器调用。
- `test/features/settings/settings_page_test.dart`：版本号、更新说明、线路名称、延迟和浏览器
  打开交互。
- `flutter analyze lib test`
- `flutter test`

本功能只增加 App 内部模型、服务、设置页 UI、文案与测试，不调整 Game SDK、App Bridge
SDK、Go Core、Catalog、Relay 或 Developer API 契约版本；归入未发布 App `4.2.0+28`。
