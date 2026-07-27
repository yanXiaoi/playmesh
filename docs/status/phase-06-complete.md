# 第六阶段完成归档

## 基本信息

- 完成日期：2026-07-18
- 对应路线图：`docs/02-roadmap.md` 第六阶段
- 前置基线：`docs/status/phase-05-complete.md`
- 问题修复切片：`docs/verification/post-1.0-mobile-fixes-2026-07-18.md`
- 完整验证：`docs/verification/phase-06-complete-2026-07-18.md`
- 产品版本：Playmesh `1.1.0+2`
- Go Core：`0.2.0`
- Game SDK：`1.2.0`
- App Bridge SDK、Developer API、Core 协议：`1.0.0`
- 状态：代码、当前文档、机器契约、默认模板、编辑器补全和 AI 提示词已归档；平台构建与真机/WebView 手工验收仍由用户执行
- 归档制度：第六阶段为最后一个阶段；后续改用 `docs/version/` 详细版本日志与 App 内简略日志

## 阶段结论

第六阶段把第五阶段后的移动端运行问题和跨设备身份模型收敛为一条正式链路。加入 App 不需要预装主机游戏；全屏不再决定游戏能否启动；Android 外部文件、包导入导出和独立 HTML 运行各自使用明确入口；联机与存储使用权威主机 SDK，本机身份与硬件使用当前 App Bridge SDK。

浏览器玩家 ID 与昵称持久化到当前浏览器来源，App 玩家身份由 App 自动注入。Core 拒绝同一玩家 ID 的并发在线连接，允许旧连接掉线后的同 ID 重连。Game SDK 提供首次加入、离开和重连事件；离线席位只在对局运行或暂停时保留，`session.finish()`、重置和重新开始会清理旧局离线成员。

## 版本归档

本阶段按当前语义版本规则完成版本影响评估：

- App 新增移动文件处理、可选全屏、远程加入和工作区体验能力，升级 `1.0.0+1` → `1.1.0+2`。
- Go Core 新增同 ID 连接约束、离线成员保留与结束清理行为，升级 `0.1.0` → `0.2.0`。
- Game SDK 新增玩家连接事件和 `session.finish()` 等兼容能力，升级 `1.1.0` → `1.2.0`。
- App Bridge SDK 在本阶段首次形成并保持 `1.0.0`；Developer API 与 Core 协议未改变既有公开版本，保持 `1.0.0`。

后续所有变更必须继续遵循 `docs/06-engineering-standards.md` 的“版本与升级策略”，按需升级受影响组件，并同步代码常量、模板、机器契约、测试和开发文档。

## 代码与资源归档地图

| 能力 | 主要代码与资源 |
| --- | --- |
| App 扫码远程加入与远程 WebView | `lib/features/game/join_game_page.dart`、`lib/features/game/remote_game_page.dart` |
| 可选全屏与 WebView 悬浮工具 | `lib/features/game/game_page.dart`、`game_fullscreen_controller.dart`、`standalone_html_page.dart` |
| Android 外部文件接收 | `android/app/src/main/AndroidManifest.xml`、`android/app/src/main/kotlin/`、`lib/core/platform/incoming_file_service.dart` |
| Playmesh 包导入导出 | `lib/core/game_package/`、`lib/features/games/game_library_page.dart` |
| 权威主机 Game SDK | `assets/playmesh-library/public/sdk/v1/playmesh.js`、`lib/core/game_sdk/game_runtime_bridge.dart` |
| 本机 App Bridge SDK | `assets/playmesh-library/public/sdk/v1/playmesh-app.js`、`lib/core/game_sdk/app_webview_bridge.dart`、`lib/core/platform/app_device_service.dart` |
| 浏览器持久身份与加入网关 | `assets/playmesh-library/public/sdk/v1/playmesh.js`、`lib/core/game_web/` |
| 同 ID 约束、离线成员与会话结束 | `go-core/internal/session/`、`lib/core/session/` |
| 移动开发工作区与 SDK 补全 | `assets/playmesh-library/public/developer/workspace.html`、`workspace.js`、`workspace.css` |
| 响应式页面与切换动效 | `lib/app.dart`、`lib/ui/playmesh_ui.dart`、`lib/features/settings/settings_page.dart` |
| 机器契约与 AI 提示词 | `assets/playmesh-library/public/developer/contracts/`、`assets/playmesh-library/public/developer/prompts/` |

## 固定运行边界

- `playmesh.js` 唯一负责 Authority 主机的日志、会话、联机、状态同步和游戏存储。
- `playmesh-app.js` 只由 App WebView 自动注入，只负责当前 App 身份与已声明、已授权的本机设备能力。
- 普通浏览器不加载 App Bridge；`playmesh.app` 空实现仅用于安全能力检测，不提供伪原生权限。
- App 玩家使用自动注入的 `u_...` 身份；浏览器玩家使用自身 `localStorage` 中的 `p_...` 身份和昵称，游戏 JavaScript 不手动设置玩家 ID。
- 同一玩家 ID 同时只能有一个在线 WebSocket；旧连接仍在线时拒绝后连接，旧连接离线后才允许重连。
- Core 只在 `running` 或 `paused` 保留离线成员；`lobby` 离线直接释放，`stopped` 不保留旧局离线成员。
- 全屏是可选显示能力。游戏、控制器、远程加入和独立 HTML 页面都不能等待或依赖全屏成功。
- 独立 HTML 不注入 Game SDK、App Bridge、存储或联机能力；Playmesh 压缩包仍必须通过根目录 `main.json` 校验。

## 文档与提示词归档

- 项目事实、架构与路线：`docs/00-context.md`、`01-architecture.md`、`02-roadmap.md`、`05-next-steps.md`
- 工程和版本规则：`docs/06-engineering-standards.md`
- 游戏开发文档：`docs/game/README.md`、`development-guide.md`、`package-format.md`、`sdk-v1.md`、`web-dev-channel.md`
- AI 提示词：`assets/playmesh-library/public/developer/prompts/common.txt`、`agent-common.txt`、`solo.txt`、`multiplayer.txt`、`multi-screen.txt`、`single-screen-multiplayer.txt`
- 机器契约与补全：SDK Manifest、SDK Schema、OpenAPI、`workspace.js` 的 SDK completion context

AI 提示词已统一说明：`main.json` 只读；版本由平台发布流程管理；联机/日志/存储使用 Authority 主机 SDK；本机 App 能力必须先检查 `playmesh.app.isAvailable()` 和设备能力；浏览器身份由 SDK 持久化；玩家等待与重连使用正式连接事件；一局结束由 Authority 调用 `session.finish()`。

> 后续版本更正（Playmesh 1.3.0）：`main.json` 原文仍禁止普通文件写入，但现在可通过“项目设置”或 manifest API 修改除稳定 `id` 外的字段；加速度计与陀螺仪已通过 `capabilities.json`、SDK 能力确认和 `playmesh.app.onDevice()` 接入。能力元数据由统一注册表提供，当前 AI 提示词以 1.3.0 契约为准。

## 已知限制与后续起点

- 尚未执行 Android、iOS、Windows、macOS 或 Linux 平台构建和真机验收。
- App Bridge 当前只开放契约已声明的身份、平台、全屏、触觉和输入入口；相机、传感器、手柄等能力必须在真实实现和权限链完成后再加入契约。
- Core 不进行 Authority 自动迁移；Authority 断开后的选举或托管需要独立协议设计。
- 后续新功能从 Playmesh `1.1.0+2`、Go Core `0.2.0`、Game SDK `1.2.0` 基线开始，不恢复旧版本兼容层。
