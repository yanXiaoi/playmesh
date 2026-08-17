# GDevelop 集成文档

本目录是 Playmesh GDevelop 集成的唯一权威文档目录。凡是只描述 GDevelop WebIDE、
GDevelop 工程、GDevelop 运行时或 Playmesh GDevelop 扩展的设计与验收资料，都必须放在
这里；实现目录中的 README 只保留代码入口和本索引链接。

## 文档索引

- [App 整合验收矩阵](app-integration-audit.md)：App、Gateway、WebIDE、预览、发布、多人、
  本地化和安全边界的当前验收状态。
- [本地工程历史](history-development.md)：`gdevelop.history` 的身份、资源、修订、配额、
  恢复和错误合同。
- [功能修改与可重放开发](feature-development-guide.md)：同一锁定内核上的 ownership、
  薄入口、source policy、摘要冻结、clean replay、完整流水线和交付检查。
- [本地 AI 开发流](local-ai-development-flow.md)：Chat/Agent 双模式、提示词、工具、审批、
  live `gdProject` 串行执行和官方编辑器函数适配。
- [运行时后端替换设计](runtime-substitution-design.md)：Playmesh 预览/发布的异步替换注册表、
  Storage 与 Multiplayer 最低层 driver seam、固定源 guard 和等价性测试。
- [GDevelop 内核升级手册](core-upgrade-guide.md)：升级官方 WebIDE 时的取源、重放、审计、
  验证、发布和回滚流程。

日常新增或修改功能先使用“功能修改与可重放开发”；只有官方 tag、commit、libGD 或 GDJS
基线变化时才进入“内核升级手册”。专项协议仍以下钻文档为准，不能在功能实现中重新发明
AI、History 或运行时状态机。

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

文档不得复制并宣称另一个固定版本号为事实。需要描述当前版本时，应引用
`webide-lock.json`；历史验收记录可以保留当时的精确版本和 commit。

## 维护规则

1. 不提交官方 GDevelop checkout、依赖目录或构建目录。
2. 不在临时官方源码树中保留只能手工复现的修改；每一步必须写入 overlay、
   `apply-source-policy.mjs` 或包准备脚本。
3. GDevelop 专属协议变更必须同步本目录对应文档和自动测试。
4. 跨编辑器公共底层的变化写入 `docs/platform/`；GDevelop controller、DTO、路由和 UI
   仍在本目录说明，不能与源码工作区合并成万能 controller。
5. `docs/version/NEXT.md` 和发行日志只写摘要并链接本目录，不复制完整设计。
6. 新增 GDevelop 文档时同时更新本索引；移动文件后必须全仓检查旧链接。
