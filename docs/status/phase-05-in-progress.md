# 第五阶段开发中：可配置运行入口

## 基本信息

- 开始日期：2026-07-17
- 对应路线图：`docs/02-roadmap.md` 第五阶段
- 前置基线：`docs/status/phase-04-web-dev-channel.md`
- 状态：已由 `phase-05-complete.md` 完成归档；本文仅保留第一批入口切片历史

## 当前已落地纵向切片

- `main.json.entries.game` 声明普通游戏首页，默认 `app/index.html`。
- `main.json.entries.controller` 声明单屏多人控制器首页，默认 `app/controller/index.html`。
- `authority.entry` 继续声明多人 Authority JavaScript，并限制为 `app/` 内 `.js` 或 `.mjs`。
- 三类入口统一拒绝外部 URL、绝对路径、反斜杠、查询、片段、空段、`.` 与 `..`；页面入口只接受 `.html`。
- Asset 包加载、文件游戏库扫描、开发项目校验、App WebView 启动和浏览器分享均读取同一份 Manifest 入口。
- 浏览器分享自定义嵌套首页时按入口目录注入 `/app/.../` 基准路径，保留完整 HTML 小游戏的相对资源结构。
- 文件扫描器补齐控制器和 Authority 文件存在性校验；非法或缺失入口在运行前失败。
- 默认模板、Game Manifest Schema、SDK Manifest、OpenAPI、AI 提示词和游戏作者文档已同步入口命名。

## 当前调用链

```text
main.json
  -> GameManifest 解析 entries.game / entries.controller / authority.entry
  -> FileGameLibraryScanner 校验正式安装包文件
  -> GameSummary.LocalGameEntry 保存解析后的入口
  -> GameLauncher / GameWebGateway 按 displayMode 和角色选择页面
  -> 当前包 app/ 受控资源映射
```

## 自动验证

详细命令、执行环境、无响应处理与结果见 `docs/verification/phase-05-entry-routing-2026-07-17.md`。

- Manifest 默认值、自定义路径、外部 URL、错误文件类型测试。
- Asset 与文件扫描的自定义入口和缺失 Authority 测试。
- 开发项目自定义入口定位诊断测试。
- 浏览器自定义嵌套首页与基准路径测试。
- 当前环境必须按 `docs/04-dev-env.md` 使用 `D:\KaiFaTool\runtime\flutter\bin\dart.bat` 与 `flutter.bat` 的绝对路径，在沙箱外执行；沙箱内曾出现超过 60 秒无输出，已明确要求中止后改用本机开发环境。
- 验证顺序固定为修改文件格式化、定向测试、`flutter analyze --no-pub`、`flutter test --no-pub`；依赖未变化时不重复执行 pub 解析。

## 当时记录的剩余主线（现已完成）

- `playmesh.sync` 轻量权威状态同步、Authority tick、全量快照、版本和重连恢复。
- SDK 自动联机往返延迟采集、结构化诊断及与 FPS 共用网页悬浮层。
- 统一游戏包导入、原子安装、导出和临时分享包清理。
- 开发者工作区的完整 HTML 小游戏导入流程和入口配置 UI/API。

第五阶段全部验收项完成后必须另建正式完成归档，不能把本文改名后直接视为完成。
