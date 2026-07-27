# 第五阶段完成归档

## 基本信息

- 完成日期：2026-07-17
- 对应路线图：`docs/02-roadmap.md` 第五阶段
- 前置基线：`docs/status/phase-04-web-dev-channel.md`
- 中间切片：`docs/status/phase-05-in-progress.md`
- 完整验证：`docs/verification/phase-05-complete-2026-07-17.md`
- 产品版本：Playmesh `1.0.0+1`
- Game SDK：`1.1.0`，开发者通道契约版本 `1.0.0`
- 状态：代码、资源、机器契约、开发文档和自动测试归档完成；平台构建与真机/WebView 手工验收仍由用户执行

## 阶段结论

第五阶段把 Playmesh 从已有联机与开发者通道基线收敛为可正式使用的 1.0 应用：游戏包、状态同步、存储、开发工作区、AI 接口、移动端界面、扫码加入、用户资料、分享、日志和全平台全屏形成同一条可验证链路。产品界面不再保留 Demo、测试或阶段占位文案。

最终边界固定为：

- 应用游戏包导入/导出只支持根目录包含 `main.json` 的 Playmesh 结构。
- 普通 HTML/ZIP 不提供应用侧独立导入口，只能上传到开发者工作区后使用解压、移动、复制和粘贴整理。
- 游戏只能通过 Game SDK 使用平台存储；游戏不负责显式 flush。App 在写入期间负责串行化、原子替换和退出收尾。
- “清理游戏数据”只删除当前包的 `data/`，永不删除 `cache/`，运行中的游戏拒绝清理。
- 游戏和控制器 HTML 的挂载不依赖全屏；App 与浏览器分享页都提供可选全屏操作，失败只提示并允许继续游玩。

## 代码归档地图

| 能力 | 主要代码与资源 |
|---|---|
| App 入口、主题、正式版视觉与动效 | `lib/app.dart`、`lib/ui/playmesh_ui.dart`、`lib/features/home/home_page.dart` |
| 用户资料持久化 | `lib/core/profile/user_profile_store.dart`、`lib/features/profile/profile_page.dart` |
| 扫码加入与邀请解析 | `lib/features/game/join_game_page.dart`、`lib/features/game/game_page.dart` |
| 全平台游戏会话全屏 | `lib/main.dart`、`lib/features/game/game_orientation_controller.dart`、`lib/features/game/game_page.dart` |
| 浏览器游戏/控制器全屏与 SDK | `assets/playmesh-library/public/sdk/v1/playmesh.js` |
| 游戏 WebView、入口和分享网关 | `lib/features/game/game_launcher.dart`、`lib/core/game_web/` |
| SDK Bridge、状态同步、性能与日志 | `lib/core/game_sdk/game_runtime_bridge.dart`、`lib/core/developer/developer_event_hub.dart` |
| 游戏数据存储与 App 收尾 | `lib/core/storage/game_storage_service.dart` |
| Playmesh 包扫描、导入与导出 | `lib/core/game_package/` |
| 开发项目、校验、文件操作和历史 | `lib/core/developer/developer_project_catalog.dart`、`developer_project_validation.dart`、`developer_file_operations.dart` |
| Developer API、运行/重启/停止、日志和数据清理 | `lib/core/developer/developer_web_gateway_io.dart`、`developer_run_controller.dart` |
| 开发者工作区 UI | `assets/playmesh-library/public/developer/workspace.html`、`workspace.js`、`workspace.css` |
| OpenAPI、Schema、SDK Manifest | `assets/playmesh-library/public/developer/contracts/` |
| AI 对话与 Agent 提示词 | `assets/playmesh-library/public/developer/prompts/`、`lib/core/developer/developer_ai_prompt_templates.dart` |
| Logo 与平台图标 | `assets/branding/playmesh-logo.png`、各平台 Runner/Web 图标、`tool/generate_app_icons.py` |
| Go Core 会话与路由 | `go-core/internal/session/`、`go-core/internal/server/`、`go-core/mobile/` |

## 已完成能力

### 游戏运行与 SDK

- `entries.game`、`entries.controller` 与 `authority.entry` 贯通 Manifest、扫描、校验、App/浏览器运行、模板和机器契约。
- Game SDK `1.1.0` 提供 `playmesh.sync`：Authority tick、动作输入、连续输入限频/合并、完整快照版本、观察接口和刷新后的最新快照恢复。
- Player → Core → Authority SDK → Core → Player 的往返延迟由 SDK 自动测量；FPS 与延迟在网页 Shadow DOM 性能层统一显示。
- 游戏悬浮工具固定提供运行日志，不以开发者项目身份为前提；App 内存保留最近日志，Developer API 可一次读取最近 50 条供非流式 AI 使用。
- 工作区和 API 可以读取当前游戏状态，并开始、重启或停止当前游戏运行时；对应接口已进入 OpenAPI 与 AI 接口清单。
- App 游戏页、Windows/macOS/Linux 桌面窗口、Android/iOS 系统 UI 与 Flutter Web 统一进入全屏。浏览器安全策略拒绝自动全屏时，先显示用户手势门禁，成功前不挂载运行时。
- 分享网关打开的普通游戏 HTML 和控制器 HTML 都提供可选全屏浮层；失败或跳过全屏不会阻断 SDK 和游戏。

### 存储与游戏包

- 游戏存储写入按 bucket 串行处理，并使用临时文件原子替换；Windows 文件短暂占用执行有限退避重试。
- 游戏不暴露或依赖显式 flush，WebView 退出和 App 生命周期收尾由宿主完成。
- 当前游戏数据可通过工作区按钮或 `DELETE /dev/api/projects/{projectId}/data` 清理；接口只处理 `data/` 并返回 `cachePreserved: true`。
- 应用游戏库支持 Playmesh ZIP 导入与导出；导入要求包根直接存在 `main.json` 和 `app/`，导出只包含 `main.json` 与 `app/`。
- 导入、解压和文件操作拒绝目录穿越、绝对路径、符号链接、重复路径、危险文件类型和越界目标，并限制文件数与展开大小。

### 开发者工作区与 AI

- 工作区支持文件/目录上传、拖拽到树节点、ZIP 条件解压、复制、剪切移动、粘贴、重命名、删除和项目级历史。
- 顶部高频操作保持精简，其余操作收纳到二级菜单；项目选择使用可搜索弹窗，文件树点击后自动跳转编辑区。
- 新建联机项目默认使用 `multi_screen`（多人多屏）。
- 只有压缩包显示解压；只有存在复制/剪切上下文时显示移动/粘贴相关操作。
- Diff 展示文件间逐行差异详情；CodeMirror 注入 HTML/CSS/JavaScript 与 SDK `1.1.0` 方法补全。
- 新建项目支持描述字段并写入 `main.json.remarks`；支持引入放在代码目录内的外部依赖。
- AI 入口位于快速操作旁并提高视觉层级；OpenAPI、SDK Manifest、JSON Schema、项目源码和模式化提示词保持同步。
- Developer API 提供运行状态、开始、重启、停止、最近日志、数据清理、项目/文件管理、校验和提示词导出，供浏览器与 AI 通过 token 调用。

### 正式版 App 与移动端

- 全局 Material 3 正式主题、响应式页面、进入动效和移动安全区已覆盖首页、资料、加入、设置、游戏详情、分享层和开发者工作区。
- 用户昵称和头像标记持久化到本机资料文件；首页游戏库入口收敛为一个。
- 加入对局支持邀请链接解析和二维码扫描；扫描主机分享二维码后直接打开主机游戏或控制器 WebView，无需预先安装游戏，SDK 由主机分享网关注入。
- Android 导出先生成标准 Playmesh 压缩包，再通过系统分享/保存面板选择目标位置；导入完成后的 App 状态更新保持同步回调，避免成功后误报失败。
- Android 可从其他应用的“打开方式/分享至”接收压缩包和 HTML：压缩包进入游戏包导入，HTML 使用无 SDK 注入的独立 WebView；WebView 悬浮工具提供按需进入和退出全屏。
- 分享链接区域在窄屏与低高度横屏之间自动切换布局，可选择地址、复制链接或扫码。
- 运行日志弹窗固定存在于所有游戏，不要求开发者模式。
- 新 Logo 已替换 App、Android、iOS、macOS、Windows、Web 和开发者工作区品牌资源。

## 接口归档

第五阶段新增或确认的 Developer API 以 `assets/playmesh-library/public/developer/contracts/openapi.json` 为权威，关键接口包括：

- `POST /dev/api/projects/{projectId}/run`
- `POST /dev/api/projects/{projectId}/run/restart`
- `POST /dev/api/projects/{projectId}/run/stop`
- `GET /dev/api/projects/{projectId}/run`
- `DELETE /dev/api/projects/{projectId}/data`
- `GET /dev/api/logs?limit=50`
- 项目、文件、校验、历史、Diff、上传、解压、复制和移动相关接口

所有 Developer API 继续使用独立 Gateway 和开发者 token，不复用 Core 会话凭证，不开放任意命令执行或项目沙箱外文件访问。

## 文档归档

- 项目事实与架构：`docs/00-context.md`、`docs/01-architecture.md`
- 路线图与后续边界：`docs/02-roadmap.md`、`docs/05-next-steps.md`
- 测试与防超时规则：`docs/04-dev-env.md`
- 工程规范：`docs/06-engineering-standards.md`
- 游戏开发文档：`docs/game/README.md`、`development-guide.md`、`package-format.md`、`sdk-v1.md`、`web-dev-channel.md`
- 阶段入口切片：`docs/status/phase-05-in-progress.md`
- 阶段完整验证：`docs/verification/phase-05-complete-2026-07-17.md`

## 安全与后续边界

- `data/`、`cache/` 与 `.playmesh/` 不参与静态映射或包导出。
- Go Core 只承载会话、路由、存储 RPC 和延迟探测，不解释具体游戏规则。
- 本阶段不包含局域网自动发现、云端账号、异地联机、创意工坊、生产级签名审核或完整原生硬件适配。
- 未执行 Android、iOS、Windows、macOS 或 Linux 平台构建；实际 WebView、窗口全屏、摄像头权限和系统文件选择器仍需按目标平台手工验收。
