# 第四阶段归档：网页开发者通道

## 基本信息

- 开始日期：2026-07-16
- 归档日期：2026-07-17
- 对应路线图：`docs/02-roadmap.md` 第四阶段
- 前置基线：`docs/status/phase-03-game-sdk-fishing.md`
- 状态：已完成，可进入第五阶段

## 验证约定

自动任务只执行静态分析、代码级测试和与平台编译无关的资源/语法检查。Windows、Android、iOS、macOS 和 Linux 的实际构建、安装、真机 WebView 与系统 UI 验证由项目维护者处理，本阶段归档不把平台编译结果作为自动验收结论。

## 阶段目标

在不改变动态 Go Core 端口和游戏 SDK 边界的前提下，为 App 内置 WebView、手机端和局域网电脑浏览器提供同一套开发者工作区；让开发者或 AI 能完成项目创建、文件编辑、校验、运行、日志诊断和再次修改的闭环。

## 实际交付

- 独立 `DeveloperWebGateway` 固定绑定 `0.0.0.0`，默认端口 `16666`；设置页可修改端口，端口、token 和工作区路径持久化到 `playmesh-library/developer/settings.json`。
- token 可自定义或首次安全随机生成。关闭开发者模式或 App 退出时只停止监听；重新开启或 App 重启后复用相同端口、token 和工作区路径，使局域网设备可以直接重连。
- 开发者链接与游戏分享链接使用一致的地址切换、二维码和复制交互，所有链接支持长按或拖选复制。
- App 内置 WebView 与外部浏览器使用同一响应式工作区；移动端提供项目、编辑和运行视图，工作区不嵌入游戏主页面预览。
- 项目直接位于统一 `playmesh-library/packages/{gameId}/` 游戏库，新建项目支持随机生成项目 ID；开发项目与普通游戏共用扫描、运行和删除流程。
- 默认项目骨架、工作区页面和 CodeMirror 均属于开发工具资源，统一放在 `playmesh-library/public/developer/`；Dart 不嵌入 HTML 或骨架模板。
- 工作区提供 IDEA 风格文件树、文本编辑、图片预览、二进制列出、上传、新建与删除文件/文件夹、Diff 和快速操作；`main.json` 由平台管理且禁止修改或删除，项目根 `app` 禁止删除。
- 快速操作支持 `create_file`、`replace_file`、`insert_lines` 和 `replace_lines`，可预览 Diff 并按修订原子应用；创建与完整替换会递归创建缺失目录。
- 项目级本地历史位于 `packages/{gameId}/cache/developer/local-history/`，使用初始基线加变更后快照，按 5 分钟窗口合并，支持文件、文件夹和工作区 Diff 与全量恢复。
- 运行前执行结构化游戏包校验，诊断包含稳定代码、严重级别、文件、行列和修复建议；存在错误时阻止运行。工作区运行按钮请求 App 启动对应游戏，多人显示正确联机入口，单机分享只进入 `app/index.html` 且不加入 WebSocket 会话。
- `run.status`、文件变化、历史恢复和 `runtime.log` 通过统一 SSE 通道同步。工作区在运行期间补充低频状态确认，恢复从游戏 WebView 返回后可能错过的停止事件。
- Game SDK 保留原生 `console` 输出，同时捕获 Console、未处理脚本错误、Promise 拒绝和资源加载错误并复制到日志总线；App 始终缓存最近 500 条，工作区和游戏内调试日志层均可一键复制。
- 主工作区“AI”按钮直接进入统一 AI 开发页；接口、鉴权、权限、风险和 AI 可用性文档作为只读项与提示模板同页展示。机器契约提供 OpenAPI、SDK Manifest、Game/SDK/Developer Session/Validation Schema 和请求示例。
- AI 提示模板按公共、游戏模式和显示模式配置，公共分类包含可编辑的“自定义想法”。当前项目分别生成对话提示词与 Agent 提示词：两者都包含相关 SDK、角色语义、用户想法和当前源码，Agent 额外包含 Gateway、Bearer token 及开发 API；复制与 UTF-8 BOM TXT 下载集中在“预览当前项目”。
- 游戏库提供不可逆删除游戏操作，删除整个项目目录及其 `data/`、`cache/` 和元数据。
- 所有非移动端的 `playmesh-library` 位于当前运行可执行文件同级；Android 与 iOS 使用系统应用支持目录，移动端不提供该路径设置。

## 主要代码

| 能力 | 路径 |
|---|---|
| 开发者会话、默认端口与偏好接口 | `lib/core/developer/developer_channel.dart` |
| 端口偏好持久化 | `lib/core/developer/developer_preferences.dart` |
| HTTP Gateway、鉴权、API 和机器文档 | `lib/core/developer/developer_web_gateway*.dart` |
| 项目创建、文件操作和游戏库边界 | `lib/core/developer/developer_project_catalog.dart` |
| 项目校验 | `lib/core/developer/developer_project_validation.dart` |
| 项目级本地历史 | `lib/core/developer/developer_local_history.dart` |
| SSE 与最近 500 条日志缓存 | `lib/core/developer/developer_event_hub.dart` |
| 开发运行状态 | `lib/core/developer/developer_run_controller.dart` |
| Runtime 生命周期 | `lib/core/services/go_core_runtime.dart` |
| 设置页和内置工作区入口 | `lib/features/settings/settings_page.dart`、`lib/features/developer/developer_workspace_page.dart` |
| 工作区、编辑器、契约、提示词和骨架 | `assets/playmesh-library/public/developer/` |
| 游戏 SDK 日志捕获 | `assets/playmesh-library/public/sdk/v1/playmesh.js` |

## 关键调用链

```text
SettingsPage
  -> GoCoreRuntime.loadDeveloperPortPreference()
  -> GoCoreRuntime.enableDeveloperMode(port, token)
  -> DeveloperWebGateway 绑定 0.0.0.0:{port}
  -> 持久工作区路径 + 持久开发者 token
  -> App WebView / 局域网浏览器加载同一工作区
```

```text
Workspace Developer API
  -> GameLibraryDeveloperProjectCatalog
  -> playmesh-library/packages/{gameId}
  -> 路径与修订校验
  -> 原子文件提交 + 本地历史
  -> DeveloperEventHub SSE
```

```text
Workspace Run
  -> DeveloperProjectValidator
  -> DeveloperRunController
  -> App 打开对应 Game WebView
  -> run.status + 分享链接/二维码
  -> Game SDK Console/错误捕获
  -> runtime.log + 最近 500 条缓存
  -> 工作区/游戏内日志层诊断
```

```text
AI / Chat
  -> /dev/api/ai-context 或当前项目 TXT
  -> OpenAPI + SDK Manifest + JSON Schema + 当前源码
  -> 文件/快速操作 API
  -> 项目校验 + 运行 + SSE + 日志
  -> 再次精确修改
```

## 关键决策

- 开发者 Gateway 与 Go Core 分离；Gateway 固定端口，Core 继续使用 `0.0.0.0:0` 动态端口。
- Gateway 按产品要求保持绑定 `0.0.0.0`，公网访问边界交给设备防火墙和所在网络。
- 持久化端口、开发者 token 和工作区路径，不持久化运行会话；开发者设置文件按敏感配置管理且不写日志。
- 不维护独立 App 文件编辑器，不提供服务端单文件撤销/前进；编辑器即时撤销由 CodeMirror 管理。
- 不建设测试会话、虚拟玩家或设备模拟。AI 依靠正式 SDK 契约、项目校验、运行状态、SSE 和日志完成诊断。
- 当前处于开发期，只维护一套当前 SDK/API/模板契约，不保留旧路由、字段别名、迁移适配器或历史模板实现。

## 与原路线图的调整

- 原计划的三个内置最小游戏示例取消，改为按项目类型提供最小 SDK 方法契约、页面拓扑、数据流说明和外置默认骨架，避免示例业务逻辑误导 AI。
- 原“AI 调用测试 API”调整为项目校验、真实运行状态、SSE 和 Console 日志闭环，不尝试模拟每个游戏的规则。
- 交付范围扩展了移动端工作区、项目级本地历史、精确编辑、统一日志捕获、Chat/Agent 双提示词和全局提示模板配置。
- 热重载与统一游戏包导入/导出明确转入第五阶段。

## 验证结果

- `flutter analyze --no-pub`：通过，`No issues found`。
- JavaScript 语法和 JSON 资源解析：归档前检查通过。
- OpenAPI 与 AI 页面接口目录的方法/路径集合：已加入自动一致性断言。
- 本轮 `flutter test` 在当前执行环境中启动后无输出并超时；2026-07-16 的阶段中间代码级测试曾通过。该执行环境问题不替代平台构建结论，后续修改应继续保留并执行现有测试集。
- 未执行任何平台编译、安装或真机运行验证，符合项目约定。

## 转入第五阶段

- AI 友好的轻量权威状态同步运行时。
- SDK 自动联机延迟显示及与 FPS 共用的调试控制。
- 统一 `packages/{gameId}` 游戏包导入、导出和分享。
- `main.json` 可配置普通游戏、控制器和 Authority 入口。
- 继续同步 SDK、模板、Schema、Manifest、OpenAPI、项目校验和 AI 提示词；开发期不增加旧版本兼容层。
