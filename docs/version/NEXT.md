# Playmesh 下一版本临时更新日志

## 状态

- 状态：开发中，尚未发布。
- 当前正式基线：App `1.6.1+8`。
- 当前开发版本：App `1.6.2+10`、Game SDK `2.0.0`、App Bridge SDK `2.0.0`、Developer API / OpenAPI `1.5.0`。

## 发布与平台

- 新增 HarmonyOS 工程与 `harmony` 发布目标；统一脚本现在可选择构建 HarmonyOS arm64 HAP、Android 通用 APK、Windows x64 便携 ZIP，或用 `all` 串行构建全部目标。
- 鸿蒙构建使用隔离依赖清单；WebView、文件选择和路径插件固定到明确提交，系统分享由自研 HAR 适配。OpenHarmony Public SDK 不含 HMS `ScanKit`，扫码使用明确的手动输入回退。
- 新增 ArkTS 能力 HAR，接入全屏、触觉、加速度计和陀螺仪；Go Core 通过 C ABI、异步 N-API 和 `NativePlaymeshHarmonyCoreAdapter` 实际注入鸿蒙应用。
- 鸿蒙生产发布要求外部签名配置；脚本验证 HAP 关键运行时入口并输出 SHA-256。已在 API 12 Public SDK 上实际生成包含 Go Core 的 arm64 内部测试 HAP，证据见 [构建验证记录](../verification/playmesh-1.6.2-harmony-build-2026-07-22.md)。
- `all` 构建现在严格隔离标准 Flutter 与 OpenHarmony Flutter：Android 固定使用标准 SDK、拒绝 OHOS fork 并修正 `android/local.properties`，鸿蒙阶段结束后恢复进程环境。Android、OpenHarmony、Windows 三类内部测试产物已实际构建通过，见 [全平台构建验证](../verification/playmesh-1.6.2-all-build-2026-07-22.md)。

## 开发者工具

- 开发者工作区项目选择器现在展示统一游戏库中的全部本地项目，并持久化最近打开项；首次进入或历史项目不存在时强制选择项目。
- 平台能力测试增加持续数据日志，在用户手动关闭测试前循环回显实际能力返回值，而不再只显示一次通过或失败。
- 能力系统完成破坏性插件化：每个能力在 `lib/core/capabilities/{capability}/` 拥有独立目录和描述符、实例、自检、资源释放；开发者工作区自动展示全平台注册表的插件版本、方法、事件、平台状态和测试结果，不按当前项目声明过滤。
- AI 能力上下文按用途拆分：Agent 提示词提供全量能力注册表 API 与 GET/POST 测试 API，不直接内嵌全量声明；对话提示词只附带当前项目已勾选能力的完整声明。工作区新增“复制全平台能力”，可独立复制注册表 API 的全部插件契约。
- 能力插件的分析、134 项 Flutter 测试、JS SDK 契约与 Android debug APK 构建均已通过；命令、产物哈希和真机待验证项见 [能力插件验证记录](../verification/playmesh-1.6.2-capability-plugins-2026-07-22.md)。
- Developer CLI 升级到 `1.2.0`，新增 `playmesh-cli create` 交互式创建流程；选项与网页 Dev Tool 对齐，创建和下载继续复用既有 Developer API。

## 游戏工具与分享

- 主机与 App 扫码加入页统一使用可拖动、可收纳的游戏工具区；扫码加入除不显示分享入口外，其余 App 操作与主机一致。
- 主机二维码/链接提升为工具区一级入口，移除独立“退出游戏”按钮，只保留返回操作。
- 分享面板在屏幕内居中并动态适配宽高，内容超出视口时可整体滚动；二级菜单、游戏信息和运行日志固定使用高对比度配色。
- Game SDK 与 App Bridge SDK 升级到 `2.0.0`。能力统一使用 `capabilities.create(code, options)` 创建实例，再通过 `invoke/on/onError/dispose` 操作；旧 `DeviceType`、`onDevice`、`device.getCapabilities/getDeclaredCapabilities` 已移除且不提供兼容层。普通浏览器仍由 SDK 渲染可收纳功能区，并为原生能力插件提供明确的不可用实现。

## 兼容性与迁移

- 这是能力 SDK 的 MAJOR 破坏性更新。游戏必须把旧传感器订阅改为插件实例；`capabilities.json` 文件结构和既有两个能力 code 不变。
- 加速度计、陀螺仪插件 API 版本均为 `1.0.0`，创建时传 `{fps}`，方法为 `start/stop`，事件为 `reading`。未来录音、语音转写等能力可以在各自插件中定义需要用户主动触发的异步方法，无需修改通用 Bridge。

## 已知边界

- 鸿蒙 Core 强制使用固定的 OpenHarmony SIG Go `go1.24.5.ohosv1r1`（commit `2d8b23f6923100d8c90d8add9299da2c9d032a20`）和 `GOOS=openharmony/arm64`，不再使用 Linux runtime 兼容构建；正式发布前仍必须在目标 HarmonyOS 真机验证网络、线程和生命周期。
- 鸿蒙端暂不声明 Android `ACTION_VIEW` 对应的外部文件打开能力；应用内文件选择使用 `file_selector_ohos`。

详细说明见 [HarmonyOS 构建与适配](../harmony-release.md)。
