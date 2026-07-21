# 第五阶段完整验证记录（2026-07-17）

## 验证范围

本记录对应 `docs/status/phase-05-complete.md` 的最终归档基线，覆盖：

- Game SDK 状态同步、浏览器身份、昵称、全屏门禁、性能与存储契约。
- 游戏包扫描、校验、导入/导出和工作区复制、移动、上传、ZIP 解压。
- 游戏存储串行写入、Windows 原子替换重试、只清理 `data/` 和宿主退出收尾。
- Developer API 的当前状态、开始、重启、停止、最近 50 条日志和游戏数据清理。
- 工作区二级工具菜单、可搜索项目选择、新建项目描述、默认多人多屏和文件点击跳转编辑区。
- App 正式版响应式 UI、资料持久化、扫码加入、分享、固定运行日志和游戏/控制器全屏门禁。
- Go Core 健康检查、服务生命周期、会话、路由和移动宿主接口。

## 执行规则

- 使用 `docs/04-dev-env.md` 记录的绝对 SDK 路径。
- Dart 格式检查直接调用 `dart-sdk/bin/dart.exe`，不经过 Flutter SDK lockfile 初始化。
- Flutter 分析与测试在允许写 SDK lockfile 的本机环境执行，并统一使用 `--no-pub`。
- Flutter 定向测试硬超时 120 秒，全量测试硬超时 180 秒；使用默认并发。
- Go 测试使用固定 Go 1.26.2 SDK。
- 不执行 Android、iOS、Windows、macOS 或 Linux 平台构建。

## 最终结果

| 验证 | 命令/范围 | 结果 |
|---|---|---|
| Dart 格式一致性 | `dart.exe format --output=none --set-exit-if-changed lib test` | 91 个文件，0 个变更 |
| Dart 静态分析 | `dart.exe analyze` | `No issues found` |
| Flutter 静态分析 | `flutter.bat analyze --no-pub` | `No issues found`，约 4 秒 |
| 新增能力定向测试 | 运行控制器、Developer Gateway、`widget_test.dart` | 15 项全部通过 |
| Flutter 全量测试 | `flutter.bat test --no-pub` | 87 项全部通过，约 23 秒 |
| SDK App Bridge | `node tool/test_game_sdk.mjs` | 通过 |
| SDK 浏览器契约 | `node tool/test_game_sdk_browser.mjs` | 通过；全屏前不加入对局，随后验证昵称、身份、存储与性能 |
| 默认 Authority 模板 | `node tool/test_default_authority_service.mjs` | 通过；替代已移除示例包的失效测试入口 |
| 工作区与 SDK 语法 | `node --check workspace.js`、`node --check playmesh.js` | 通过 |
| Developer 机器契约 | 递归 `JSON.parse` `contracts/` | 4 份 JSON 全部通过 |
| Go Core 全量测试 | `go test ./...` | health、server、session、mobile 全部通过 |

## 关键回归结论

### 全屏

- `GamePage` 在全屏完成前不挂载游戏或控制器运行时；失败分支由定向 Widget 测试覆盖。
- Windows/macOS/Linux 不再依赖通用封装的异步状态通知判断是否已全屏，而是直接等待 `window_manager.setFullScreen` 并轮询 `isFullScreen` 的窗口真实状态。
- “浏览器需要一次用户操作”的说明只在 Flutter Web 显示；桌面端真实失败显示桌面重试文案。
- 分享链接中的浏览器主游戏和控制器由 SDK 全屏门禁覆盖；首次全屏前不调用加入接口，退出全屏后门禁重新显示。

### Developer API 与工作区

- `GET /dev/api/projects/{projectId}/run` 返回当前状态。
- `POST /dev/api/projects/{projectId}/run` 开始游戏。
- `POST /dev/api/projects/{projectId}/run/restart` 重启当前实例并保留分享信息。
- `POST /dev/api/projects/{projectId}/run/stop` 关闭当前会话并进入 `stopped` 状态。
- OpenAPI、内置 `/dev/docs`、AI Agent 提示词和 AI Context 同时包含停止接口。
- 顶部工具栏仅保留高频动作，其他操作进入二级菜单；页面资源断言确认项目搜索弹窗、停止按钮、项目描述和工作区资源均可由 Gateway 提供。
- 新建联机项目 UI 与 API 缺省值统一为 `multi_screen`。

### 存储与日志

- 同一 Bucket 高频写入串行执行且不丢数据。
- 游戏数据清理只删除 `data/`，并返回 `cachePreserved: true`；运行中返回 `409 game_running`。
- 运行日志面板对非开发者游戏也固定可用；Developer API 能读取最近最多 50 条日志。

## 测试输出说明

Flutter 全量输出中的以下日志来自测试主动构造的失败分支，并且对应测试最终通过：

- `启动游戏资源网关失败: FormatException: 游戏资源网关必须且只能指定一种包来源`
- `进入游戏全屏失败: Bad state: fullscreen requires a user gesture`

它们分别验证错误包来源不会破坏游戏页控制流程，以及全屏失败时运行时不挂载并显示重试门禁，不代表全量回归失败。

## 未执行项

未执行平台构建、模拟器、真机、安装包或真实 WebView/摄像头/窗口手工操作。Windows 已全屏状态识别、浏览器 Fullscreen API 用户手势、二维码摄像头权限和系统文件选择器仍需用户在目标平台做最终体验验收；这不影响本次代码级完整测试全部通过的结论。
