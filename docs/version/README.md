# Playmesh 版本更新日志规范

第六阶段是最后一个阶段归档。自 Playmesh `1.1.0` 起，后续更改不再建立新阶段，统一使用版本更新日志记录。

## 两层日志

每个发布版本必须同步维护：

1. `docs/version/{MAJOR.MINOR.PATCH}.md`：面向开发与维护的详细版本日志，是权威事实来源。
2. `lib/core/release/playmesh_release_notes.dart`：App 设置页显示的简略日志，只描述用户能感知的主要变化。

简略日志必须由详细日志提炼，不能包含尚未实现或未经确认的能力。详细日志可以记录多个 App 构建号，但文件名只使用语义版本，不包含 `+build`。

## 详细日志必填内容

- 发布日期、App 语义版本与构建号。
- 受影响组件及升级前后版本。
- 升级原因和兼容性判断。
- 用户功能变化。
- 开发者、SDK、API、协议、包结构或数据变化。
- 关键代码与文档入口。
- 自动验证结果、平台手工验证状态和已知限制。
- 升级、回滚或数据清理注意事项。

## 版本规则

所有更改先按 `docs/06-engineering-standards.md` 的“版本与升级策略”判断受影响组件：兼容修复递增 `PATCH`，兼容新增递增 `MINOR`，不兼容变更递增 `MAJOR`；Flutter 每个新的可分发构建递增 `+build`。只升级受到影响的组件，但版本常量、模板、机器契约、补全、测试和文档必须同步。

## 当前基线

- 最新详细日志：`docs/version/1.6.1.md`
- 下一版本临时日志：`docs/version/NEXT.md`（开发中，不代表正式版本）
- 历史阶段终点：`docs/status/phase-06-complete.md`
- 当前 App 简略日志：`lib/core/release/playmesh_release_notes.dart`
