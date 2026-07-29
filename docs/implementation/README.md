# Playmesh 本地实现文档

本目录记录需求在当前仓库中的实际实现落点、运行链路、数据边界和验证入口。需求规格
保持只读；实现变化更新本目录和相应领域文档，不在需求文档中追加完成状态或代码细节。

## 当前实现

| 版本 | 文档 | 范围 |
| --- | --- | --- |
| Playmesh `3.1.0+24` | [3.0.0 本地功能实现基线](playmesh-3.0.0-local-implementation.md) | Catalog 2.0、本地数据 v2、工作区多源发布、Go Server 账号与治理、头像与 SDK、统一 App 国际化、主题、键盘/TV、主页 GitHub 入口、居中游戏菜单与退出 WebView 清理修复 |

## 使用规则

- 当前行为先查本目录，再按领域查看 `docs/game/`、`docs/platform/` 和
  `docs/catalog-api.md`。
- 版本状态与升级原因查 `docs/version/`；实际命令和结果查 `docs/verification/`。
- App 内置工作区和平台注入 Web UI 都是 App 表面，显示文案只来自各 locale 的
  `app.json`，通过宿主只读 `locale + messages` 投影联动，不建立独立 Web 字典。
- 独立部署的 Go Server 可以使用自己的 `go-server.json`，但不得与 App 工作区词条
  混用。
- 文档写“已实现”时必须能指向当前代码；写“已验证”时必须能指向本轮验证记录。
