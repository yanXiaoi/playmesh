# Playmesh 下一版本临时更新日志

## 状态

- 状态：开发中，尚未发布。
- 当前正式基线：App `1.6.1+8`。
- 当前开发版本：App `1.8.2+15`、Go Core `0.3.0`、Core 协议 `1.1.0`、Game SDK `2.2.1`、App Bridge SDK `2.1.0`、Developer API / OpenAPI `1.6.1`、Developer CLI `1.3.1`。

## 游戏库兼容与最近打开

- 旧游戏缺少 `author` 时显示“佚名”，缺少 `lastModifiedAt` 时显示“无”，不再导致整库扫描失败。
- 其他清单或入口错误只要 `main.json` 能解析出非空 `id`，就以“待修复”条目进入游戏库和开发者工作区；无法识别 ID 的目录只记录诊断并跳过。
- “最近打开时间”只存于包外 `playmesh-library/cache/app/game-library.json`，每个 ID 覆盖单个时间戳；删除游戏同步删除记录，最多保留 2048 条并淘汰最旧记录。
- 游戏库默认按最近打开时间倒序，未打开游戏排在最后并按名称稳定排序。

## 损坏项目自救与临时文件

- Developer Gateway 项目包下载和 `playmesh-cli get` 不执行 Manifest、能力、入口或运行语义校验；缺少 `app/` 的残缺项目仍可下载已有内容。
- 运行、`push/dev` 和正式导入继续执行完整校验。
- App 分享导出、在线库导入导出和 Developer Gateway 包传输改用固定临时 ZIP；每次操作前覆盖旧文件、完成后清理，并串行化共享中转文件。

## 单屏多人方向与全屏

- `main.json` 新增 `controllerOrientation`；单屏多人必填，其他模式禁止声明。
- 主画面使用 `orientation`，控制器使用 `controllerOrientation`。本地 App WebView、远程 App WebView、普通浏览器分享入口均按当前页面角色选择方向。
- Game SDK 在 App 中调用 `playmesh.app.device.setFullscreen(true, orientation)`，原生宿主进入全屏并应用横竖屏；退出时解除方向限制。
- 普通浏览器不再显示全屏提示层，SDK 会直接尽力请求 Fullscreen API，再调用 Screen Orientation API；用户激活、浏览器策略或平台不支持导致的失败不阻断 SDK 初始化和加入对局，悬浮工具栏保留全屏按钮供用户手势重试。

## 发布元数据与详情

- `main.json` 新增只读 `author` 与 `lastModifiedAt`。网页、Agent 和 CLI 上传时分别使用当前 App 设置昵称与 Unix 毫秒时间戳覆盖包内值。
- 普通项目设置不能修改 `id`、`author` 或 `lastModifiedAt`；最后上传时间在 App 游戏详情和开发者工作区按设备本地时区显示。
- 游戏详情以紧凑信息卡展示作者、最后上传、游戏/SDK 版本、人数、模式、主画面方向、控制器方向和运行入口。

## 角色化能力声明

- `capabilities.json.required` 只属于主画面；单屏多人新增 `controllerRequired`，只属于控制器。
- 开发者网页和 CLI 创建项目时分别选择两组能力；非单屏多人声明控制器能力会校验失败。
- 本地 WebView、浏览器配置与 `/api/app-capabilities` 只返回当前页面角色的能力集合，能力确认和插件实例创建不会越权到另一角色。
- 单屏多人页面角色统一驱动入口、方向和能力选择；权威显示端的空 `required` 是最终结果，不会回退到非空 `controllerRequired`。
- App WebView 的 Game SDK 只以 App Bridge `getDeclared()` 返回的当前页面声明决定是否弹能力确认。

## Agent / CLI 发布历史

- `POST /dev/api/packages/import` 改为复用 Developer Project Catalog 的发布事务，不再直接绕过本地历史。
- 同 ID 发布记录整包 before/after 快照；恢复整个工作区时同时恢复 `main.json`、`capabilities.json` 与 `app/`，继续保留 `data/` 和 `cache/`。
- 新增回归测试覆盖上传时作者/时间覆盖、发布历史生成与整包恢复。

## 契约与资料

- Manifest、能力 Schema、OpenAPI、默认模板、开发者工作区、CLI、AI 提示词、SDK 声明与游戏开发文档均同步到当前字段。
- Game SDK 升级到 `2.2.1`，App Bridge SDK 保持 `2.1.0`，Developer API 当前为 `1.6.1`，CLI 当前为 `1.3.1`。
- Go Core 与 Core 协议没有线级字段变化，保持 `0.3.0` / `1.1.0`。

## 验证与构建

- 使用固定 SDK 在沙箱外串行执行 Dart/Flutter 静态分析、定向测试、全量测试、SDK JavaScript 契约与 CLI Go 测试。
- Android 与 Windows 通过统一发布脚本串行构建；1.8.2 产物和 SHA-256 记录在 `docs/verification/playmesh-1.8.2-role-capability-build-2026-07-24.md`。
