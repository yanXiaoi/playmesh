# GDevelop 当前源码接线索引

本文只帮助定位当前实现，不是行为规范、兼容承诺或新增功能的设计模板。源码重构时可以直接
修改这里；若本文与源码不一致，以锁定上游、当前源码、类型检查和自动测试为准。

## WebIDE 与 AI

| 职责 | 当前入口 | 交接点 |
| --- | --- | --- |
| 编辑器上下文 | `MainFrame/EditorTabsPane.js`、`MainFrame/PoppedOutEditorContainerWindow.js`、`MainFrame/EditorContainers/BaseEditor.js` | 把活动 `gdProject`、官方扩展状态和预览/热刷新 callback 交给 `PlaymeshAiEditorContainer.js` |
| 扩展安装 hook | `PlaymeshAiEditorContainer.js` | 通过官方 `AiGeneration/UseEnsureExtensionInstalled` 取得当前会话 hook |
| 工具执行 | `PlaymeshAiExecutor.js`、`PlaymeshAiEditorFunctionAdapter.js`、`PlaymeshAiLocalToolWrappers.js` | 调用官方 `EditorFunctions`；Playmesh wrapper 只处理合同中明确标识的本地 facade |
| 事件载荷 | `PlaymeshAiEventPayloadExecutor.js` | 交给官方 `ApplyEventsChanges` 及编辑器刷新 callback |
| 扩展目录下载 | `PlaymeshExternalDownloadErrorPresenter.js`、`apply-source-policy.mjs` 对 `InstallExtension.js` 的精确补丁 | Playmesh 获取扩展正文结束后进入官方安装生命周期 |
| 行为目录 | `apply-source-policy.mjs` 对 `NewBehaviorDialog.js` 的精确补丁 | 使用官方 `ExtensionStoreContext` 与 `ensureExtensionsRegistryLoaded` |
| 示例工程 | `ProjectCreation/PlaymeshNewProjectCatalog.js` | Playmesh 导入完成后调用官方 `onOpenProject` |
| 工具合同 | `playmesh/runtime/ai/tools.json` | `test-ai-tool-contract-source.mjs` 对锁定 EditorFunctions 源码核对 |

## 工程源码与历史

| 职责 | 当前入口 |
| --- | --- |
| 官方 folder-project 拆分/重组 | `PlaymeshProjectFiles`、`PlaymeshProjectSerializer`、Playmesh local storage provider |
| 当前工程与历史写入 | `PlaymeshProjectStore`、App 的 `GDevelopProjectHistoryAdapter` 和 direct-current store |
| portable 导入/导出 | `PlaymeshPortableProjectImporter`、`PlaymeshRawProjectJsonReader`、`PlaymeshDownloadProjectArchive` |
| allocation 与恢复 | `/workspace/project-files` 路由及 project allocation/restore/rekey coordinator |

具体目录格式、事务顺序、错误传播和事实源规则仍由
[本地工程历史](history-development.md)约束；本表不冻结类名或文件布局。

## 运行时替换

| 职责 | 当前入口 |
| --- | --- |
| canonical Multiplayer 兼容层 | `assets/playmesh-library/public/developer/gdevelop-multiplayer-bridge.js` |
| canonical Authority 启动层 | `assets/playmesh-library/public/developer/gdevelop-authority-bootstrap.js` |
| WebIDE 生成模块 | `apply-source-policy.mjs` 生成的 `PlaymeshShared/GDevelop*Source.js` |
| 官方最低层 I/O seam | `apply-source-policy.mjs` 对锁定 Multiplayer、PlayerAuthentication 与 storage 文件的精确补丁 |
| 预览/发布替换 | Playmesh runtime substitution registry、预览 launcher 与发布 file-map 处理链 |

## 重放与打包

| 职责 | 当前入口 |
| --- | --- |
| 上游锁 | `assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json` |
| overlay 与官方薄补丁 | `overlays/`、`scripts/apply-source-policy.mjs` |
| 输出摘要 | `source-policy-output-manifest.json` |
| 构建流水线 | `scripts/webide-pipeline.mjs` |
| ZIP 生成与验证 | `scripts/package-webide-release.mjs`、`resources/GDevelop/update.json` |

维护本文件只需保证定位有效；实现理由、临时整改状态、测试通过时间和易腐摘要不写入这里。
