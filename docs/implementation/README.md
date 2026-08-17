# Playmesh 本地实现文档

本目录记录需求在当前仓库中的实际实现落点、运行链路、数据边界和验证入口。需求规格
保持只读；实现变化更新本目录和相应领域文档，不在需求文档中追加完成状态或代码细节。

## 当前实现

| 版本 | 文档 | 范围 |
| --- | --- | --- |
| Playmesh `4.2.0+28` | [手动检查 App 更新](playmesh-4.2.0-app-update.md) | 并发读取远端更新清单、最高语义版本选择、当前平台下载线路与延迟展示、系统默认浏览器打开 |
| Playmesh `4.1.0+27` | [4.1.0 正式实现与验证](../version/4.1.0.md) | 英文默认 README、多语言 AI 提示词目录与清单、全局 locale/文案复用、Developer API 4.1 locale 查询、工作区语言联动与分语言用户覆盖 |
| Playmesh `4.0.0+26` | [4.0.0 正式实现与验证](../version/4.0.0.md) | 根 Web 运行时、外部工程与 CLI 2.0、Game SDK 4.0 / App SDK 3.2 双命名空间和成对注入、Developer API 4、Catalog/Relay 3、普通网页 ZIP 转换 |
| Playmesh `3.2.0+25` | [3.0.0 历史本地功能实现基线](playmesh-3.0.0-local-implementation.md) | 4.0 之前的 Catalog 2.0、本地数据 v2、工作区多源发布、Go Server 账号与治理、头像与 SDK、统一 App 国际化、主题、键盘/TV、主页 GitHub 入口、居中游戏菜单、统一 WebView 权限、Android ARCore 位姿与按需终端媒体 |

## 使用规则

- 当前行为先查 4.1.0 版本文档，再按领域查看 `docs/game/`、`docs/platform/` 和
  `docs/catalog-api.md`；3.0.0 实现文档只作为历史基线。
- 版本状态与升级原因查 `docs/version/`；实际命令和结果查 `docs/verification/`。
- App 内置工作区和平台注入 Web UI 都是 App 表面，显示文案只来自各 locale 的
  `app.json`，通过宿主只读 `locale + messages` 投影联动，不建立独立 Web 字典。
- 独立部署的 Go Server 可以使用自己的 `go-server.json`，但不得与 App 工作区词条
  混用。
- 文档写“已实现”时必须能指向当前代码；写“已验证”时必须能指向本轮验证记录。
