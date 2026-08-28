# GDevelop 集成文档

本目录是 Playmesh GDevelop 集成的唯一权威文档目录。凡是只描述 GDevelop WebIDE、
GDevelop 工程、GDevelop 运行时或 Playmesh GDevelop 扩展的设计与验收资料，都必须放在
这里；实现目录中的 README 只保留代码入口和本索引链接。

## 规范优先级

1. [GDevelop 开发总规范](development-standards.md)是本目录最高优先级规范，所有 GDevelop
   修改、审计和发布都必须先满足它。
2. [功能修改与可重放开发](feature-development-guide.md)规定通用实施流程；AI、History、
   运行时替换和内核升级文档只补充各自领域合同。
3. 专项规则只补充本领域合同，不得冻结当前实现；当前文件接线统一记录在
   [源码接线索引](integration-wiring.md)。

文档之间发生冲突时，以开发总规范为准；实现、测试或旧文档与总规范不一致时，该差异是待
整改缺口，不得解释为既有实现获准继续使用。

## 文档索引

- [GDevelop 开发总规范](development-standards.md)：Playmesh 与官方 GDevelop 的所有权、
  接线、官方后续处理、错误传播、安全、验证和冲突处理总则。
- [当前源码接线索引](integration-wiring.md)：仅用于定位当前模块与官方交接点，不产生规则。
- [本地工程历史](history-development.md)：`gdevelop.history` 的身份、资源、修订、配额、
  恢复和错误合同。
- [Playmesh 项目配置](project-config-development.md)：sidecar 协议、现有设置面板、
  Web Runtime 多线程到预览/发布清单的投影及跨源隔离边界。
- [功能修改与可重放开发](feature-development-guide.md)：同一锁定内核上的 ownership、
  薄入口、source policy、摘要冻结、clean replay、完整流水线和交付检查。
- [本地 AI 开发流](local-ai-development-flow.md)：Chat/Agent 双模式、提示词、工具、审批、
  live `gdProject` 串行执行和官方编辑器函数适配。
- [运行时后端替换设计](runtime-substitution-design.md)：Playmesh 预览/发布的异步替换注册表、
  Storage 与 Multiplayer 最低层 driver seam、固定源 guard 和等价性测试。
- [GDevelop 内核升级手册](core-upgrade-guide.md)：升级官方 WebIDE 时的取源、重放、审计、
  验证、发布和回滚流程。

日常新增或修改功能先核对“GDevelop 开发总规范”，再使用“功能修改与可重放开发”；只有官方
tag、commit、libGD 或 GDJS 基线变化时才进入“内核升级手册”。专项协议只补充规则，不能削弱
总规范边界；实现状态、整改记录、历史结论和易腐摘要不进入本目录。

下列文档同时覆盖源码开发区和 GDevelop，因此继续由平台文档维护：

- [开发者入口分层与复用边界](../platform/developer-foundation-architecture.md)
- [开发者工作区开发约定](../platform/developer-workspace-development.md)
- [SDK 与 WebView 宿主开发约定](../platform/sdk-development.md)：App/Game SDK ownership、
  Bridge 分发和 Windows navigation completed 回包队列。

## 单一事实源

- 官方版本、commit 和固定 ZIP 命名：
  `assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json`；当前可下载版本、SHA-256、
  精确字节数与下载线路只以 `resources/GDevelop/update.json` 为准。
- 裁剪与接线步骤：
  `assets/playmesh-library/public/GDevelop/playmesh/scripts/apply-source-policy.mjs`。
- Playmesh 自有源码：
  `assets/playmesh-library/public/GDevelop/playmesh/overlays/` 和
  `assets/playmesh-library/public/developer/` 下的 canonical 源。
- 最终包准备：
  `assets/playmesh-library/public/GDevelop/playmesh/scripts/prepare-webide.mjs`。
- 确定性 ZIP、SHA-256、精确大小和版本清单：
  `assets/playmesh-library/public/GDevelop/playmesh/scripts/package-webide-release.mjs` 与
  `resources/GDevelop/update.json`。正式大包固定放在本地
  `resources/GDevelop/GDevelop-webide-v{upstreamVersion}.zip`；ZIP 与 `update.json` 由 Git
  正常跟踪，脚本不负责远端发布或 Git 写操作。
- App 只用 ZIP 的完整 SHA-256 判断分发状态：未安装时下载，摘要相同即为当前版本并可执行
  修复，摘要不同即显示更新；`version` 只是官方核心版本展示。界面同时展示核心版本和 SHA
  短构建标识，详情保留完整摘要。
- 自动回归：`assets/playmesh-library/public/GDevelop/playmesh/tests/` 与根目录 `tool/` 中的
  GDevelop 专项测试。

文档不得复制固定版本号、commit 或摘要。需要当前值时直接引用 `webide-lock.json`、输出清单
或流水线 receipt。

## 维护规则

1. 不提交官方 GDevelop checkout、依赖目录或构建目录。
2. 不在临时官方源码树中保留只能手工复现的修改；每一步必须写入 overlay、
   `apply-source-policy.mjs` 或包准备脚本。
3. GDevelop 专属协议变更必须同步本目录对应文档和自动测试。
4. 跨编辑器公共底层的变化写入 `docs/platform/`；GDevelop controller、DTO、路由和 UI
   仍在本目录说明，不能与源码工作区合并成万能 controller。
5. `docs/version/NEXT.md` 和发行日志只写摘要并链接本目录，不复制完整设计。
6. 新增 GDevelop 文档时同时更新本索引；移动文件后必须全仓检查旧链接。
7. 新增或修改领域规则不得放宽开发总规范；确需改变总边界时，必须先修改并评审总规范，再
   同步专题文档、实现和测试。
8. 已知不合规实现进入 issue、测试或版本任务，不在规范文档维护状态台账；不得仅靠修改文档
   把现状宣称为合规。
9. 文件路径、模块名和接线点只写入 `integration-wiring.md`；重构时可随源码修改，不得把当前
   接线误写成永久规则。
