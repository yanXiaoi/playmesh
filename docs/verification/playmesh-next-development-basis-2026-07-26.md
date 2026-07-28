# Playmesh 下一版本开发依据

- 日期：2026-07-26
- 状态：实施前门禁
- 目标：实现 `docs/下一步方案.md` 的 FR-01 至 FR-26
- 工作区基线：`2c57359`

## 已读取的通用文档

- `docs/00-context.md`
- `docs/01-architecture.md`
- `docs/02-roadmap.md`
- `docs/04-dev-env.md`
- `docs/05-next-steps.md`
- `docs/06-engineering-standards.md`
- `docs/version/README.md`
- `docs/version/NEXT.md`

## 已读取的领域文档

- `docs/catalog-api.md`
- `docs/platform/README.md`
- `docs/platform/go-server-development.md`
- `docs/platform/developer-workspace-development.md`
- `docs/platform/sdk-development.md`
- `docs/game/README.md`
- `docs/game/package-format.md`
- `docs/game/sdk-v1.md`
- `docs/game/ai-development.md`
- `docs/game/web-dev-channel.md`

实现范围扩大到其他领域时，先补读对应 `docs/platform/` 或 `docs/game/` 文档，再修改代码。

## 当前事实基线

- App：`2.2.0+21`
- Go Core：`0.4.0`
- Core 协议：`1.2.0`
- Game SDK：`2.2.3`
- App Bridge SDK：`2.1.1`
- Catalog API：`1.4.0`
- Relay 协议：`2.0.0`
- Developer API / OpenAPI：`2.1.0`
- Developer CLI：`1.3.1`

当前代码仍使用 Catalog 1.4、游戏源配置 v1、本地最近打开元数据 v1、文字头像和匿名邮箱上传。目标规格明确不兼容读取这些旧格式。

## 单一事实源

| 领域 | 唯一事实源 |
| --- | --- |
| Game/App SDK | `lib/core/game_sdk/features/` 与 `sdk_feature_registry.dart` |
| Developer API | `lib/core/developer/operations/` 的 Operation Definition |
| 游戏包 | 根 `main.json`、可选根 `icon.png`、`capabilities.json` 与 `app/` |
| AI 默认提示词 | `assets/playmesh-library/public/developer/prompts/manifest.json` 与同目录 TXT |
| UI 语言 | `assets/playmesh-localization/manifest.json` 与登记词典 |
| App 游戏源 | `catalog/settings.json` 的 formatVersion 2 |
| App 使用统计 | `cache/app/game-library.json` 的 version 2 |
| go-server 业务数据 | 新 schema 版本的 SQLite；不自动迁移旧库 |

不得直接实现于 SDK 生成物、静态 OpenAPI、重复提示词、硬编码语言数组或 Developer Gateway 路由旁路。

## 协议、数据与安全边界

- Catalog 只接受 `2.0.0`；下载与图标必须指定版本，并且只公开每个 gameId 的当前最新 approved + published 版本。
- 源分享和导入只使用 `publicURL?token=...`；上传密钥不进入链接、二维码、网页 JavaScript、日志或 Catalog。
- gameId 所有权只按 go-server 用户 ID 判断；所有权、最高版本、版本创建和冲突判断在同一事务内完成。
- 用户上传必须严格递增三段式语义版本；冲突时不保存 ZIP、图标或审核记录。
- 游戏包列表图标只接受根 `icon.png`；`main.json` 不定义 `icon` 或
  `permissions`，规范化写回会清除额外同名字段。
- `_sys-` 是平台保留 Bucket 前缀；游戏 SDK 不能创建、上传或清空系统 Bucket。
- 会话头像由凭据决定玩家身份，只保存同源相对 URL；HTML 玩家不能上传头像。
- Authority 分享命令只打开平台既有 UI，不返回 Token、URL 或二维码内容。
- API 不参与 UI 国际化；语言和主题只改变渲染层。
- App/SDK/Web 平台 UI 必须有键盘和 Android TV 遥控器路径，触摸或拖动不能是唯一入口。

## 工具链与正式命令

正式验证只能在沙箱外串行执行，并使用固定工具链：

```text
D:\KaiFaTool\runtime\flutter\bin\cache\dart-sdk\bin\dart.exe
D:\KaiFaTool\runtime\flutter\bin\flutter.bat
D:\KaiFaTool\runtime\go\go-1.26.2\bin\go.exe
D:\KaiFaTool\runtime\go\go-1.26.2\bin\gofmt.exe
```

验证顺序为格式化、定向测试、组件全量、跨端契约、浏览器/可访问性、Flutter 全量、独立授权的发行构建。每组真实命令、开始与结束时间、退出码和结果另写验证记录；未获授权或未执行的项目必须标为“未执行”。

## 版本升级判断

初始判断如下，最终以实际公开契约改动复核：

| 组件 | 目标判断 | 原因 |
| --- | --- | --- |
| App | `3.0.0+22` | 源配置、资料、统计、导入协议和 UI 偏好均破坏性变化 |
| Catalog API | `2.0.0` | 单链接导入、版本化下载、图标、上传声明和 latest-only |
| Game SDK | `2.3.0` | 兼容新增 `avatar` 与 `authority.openSharePanel()` |
| App Bridge SDK | 保持 `2.1.1`，若公开身份结构改变再升级 | 当前目标没有新增游戏可调用头像修改 API |
| Go Core | `0.5.0` | 会话头像传输与资源生命周期新增 |
| Core 协议 | `1.3.0` | Player 快照兼容新增 `avatar` |
| Developer API | `2.2.0` | 兼容新增多源发布 Operation |
| Relay 协议 | 保持 `2.0.0` | 端点和传输语义不变 |
| Developer CLI | 实际受 icon/package 契约影响后复核 | 不机械随 App 升级 |
| go-server SQLite | 新 schema 版本 | 旧数据库拒绝启动，不执行自动 ALTER |

## 需同步资料

- 通用架构、工程规范、Catalog、包格式、SDK、工作区与 go-server 开发文档
- SDK Manifest、Schema、类型声明、默认模板、编辑器补全与 AI 提示词
- `docs/version/NEXT.md`、App 简略更新日志和各组件版本常量
- `docs/verification/` 中的真实测试与发行验证记录

## 工作区保护

开始时存在用户/历史遗留的未跟踪文件和一个已暂存备份可执行文件；实施不删除、不覆盖、不暂存这些无关内容。生成目录只通过仓库生成链更新。
