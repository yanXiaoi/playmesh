# 第三阶段状态：Game SDK 和联机钓鱼 Demo

## 基本信息

- 完成日期：2026-07-15
- 对应路线图：`docs/02-roadmap.md` 第三阶段
- 前置基线：`docs/status/phase-02-go-core.md`
- 当前游戏开发文档入口：`docs/game/README.md`
- 阶段目标：建立真实联机会话和受控 Game SDK，并用只支持大屏模式的联机钓鱼 Demo 验证完整链路。

## 实际完成范围

- Go Core 已实现会话创建、玩家加入、WebSocket、联机码、Authority 路由和本局分享 token。
- Core 使用系统分配端口；App 使用上报端口建立本机连接，并在分享附加层列出全部可用局域网 IPv4 地址。
- Windows Runner 启动 Core 时传入父进程 PID；Runner 被 IDE 强制结束后 Core 自动关闭，避免遗留进程锁住下一次构建要覆盖的 `playmesh-core.exe`。
- `/join/{code}` 直接提供浏览器控制器和 SDK 配置，分享 URL 与注入配置不携带昵称。SDK 首次缺少昵称偏好时弹出输入层并写入 `localStorage`，刷新复用昵称但始终创建全新的玩家 ID；旧连接断开后从成员集合移除。关闭附加层和重新开始不撤销 token，退出游戏、会话关闭或 Core 重启后失效。
- 重新开始会把同一 Core 会话重置为大厅并重建游戏运行时，保留会话 ID、联机码、已连接玩家、分享网关和 token。
- 分享附加层列出全部局域网地址，点选地址会切换二维码。
- 创建并运行会话的 App 主机固定为 Authority Client；大屏主机不进入 `players`，普通多屏 App 主机可同时作为 Player，但玩家顺序不参与 Authority 判定。
- Game SDK 提供会话、玩家、浏览器改名、动作、Authority、生命周期、Bucket 存储和显式帧上报 API；游戏代码不直接创建 WebSocket。浏览器由 SDK 统一悬浮显示改名按钮，App WebView 不显示。
- `onPause`、`onResume`、`onExit` 由 App 主动通知，退出通知有有限等待；关闭运行时前执行最终存储 flush。
- 游戏包从 `playmesh-library/packages/{gameId}/main.json` 自动扫描，校验目录名、清单、方向、模式、人数、Authority 和必需入口。
- 游戏库页面提供手动后台扫描按钮。App 级仓库在刷新期间保留旧列表，成功后按 ID 去重并原子替换缓存；缓存记录 revision、刷新时间和搜索文本，并支持 offset/limit 查询，为后续分页与搜索提供数据源。
- 游戏包公开内容只位于 `app/`；当前游戏通过 `/game/...` 暴露，平台公共 SDK 通过 `/playmesh/...` 暴露，`data/` 与其他包不可通过 URL 读取。
- 持久化文件只位于开始游戏主机的 `packages/{gameId}/data/{bucket}.json`，不增加 `{userId}` 层。Authority WebView 直接访问主机存储，浏览器走受 token 保护的 HTTP 接口，其他 App 玩家经会话路由到 Authority；加入设备不创建独立副本。SDK 与 Flutter 双层校验 Bucket 名称，主机使用内存缓存、2 秒延迟写入和脏写阈值；WebView 重启、退出或会话关闭时由 App 完成最终落盘，游戏不暴露 flush。
- 游戏详情页提供确认后的“清除游戏数据”，只删除当前游戏的 `data/`。
- 游戏工具区可拖动并默认收纳，展开后提供返回、重新开始、退出、FPS 开关和更多操作；FPS 默认显示在左上角，未上报时显示 `-- FPS`。
- FPS 必须由游戏在真实渲染完成处调用 `playmesh.performance.reportFrame()`；SDK 不通过独立 RAF 猜测 Canvas/WebGL 等游戏的帧率。
- 联机钓鱼 Demo 已迁移到最终包结构，主屏展示加入码、准备状态、倒计时和排行榜；每位控制器玩家准备后，全员满足条件自动倒计时 5 秒开始，回合由 Authority 时钟自动推进。

## 最终目录契约

```text
playmesh-library/
  packages/{gameId}/
    main.json
    app/
      index.html
      controller/index.html
      static/...
    data/
      {bucket}.json
  public/
    sdk/v1/playmesh.js
```

- `app/` 是当前游戏唯一映射到 WebView 的目录。
- `data/` 与 `app/` 同级，只能通过 `playmesh.storage.getBucket()` 访问。
- Bucket 必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- 卸载安装游戏时应删除整个 `packages/{gameId}/`；清除数据只删除其中的 `data/`。

## 代码对应关系

| 能力 | 主要代码 |
|---|---|
| 会话、Authority 和 WS 路由 | `go-core/internal/session/`、`go-core/internal/server/` |
| Flutter 会话 Client | `lib/core/network/go_core_session_client.dart` |
| Game SDK 与桥接 | `assets/playmesh-library/public/sdk/v1/playmesh.js`、`lib/core/game_sdk/` |
| 包清单和扫描 | `lib/models/game_manifest.dart`、`lib/core/game_package/asset_game_library_scanner.dart` |
| 受控 WebView 资源服务 | `lib/core/game_package/game_asset_gateway_io.dart` |
| 浏览器加入和资源服务 | `lib/core/game_web/game_web_gateway_io.dart` |
| Bucket 持久化 | `lib/core/storage/game_storage_service.dart` |
| 游戏页和分享附加层 | `lib/features/game/game_page.dart` |
| 钓鱼 Demo | `assets/playmesh-library/packages/com.playmesh.fishing-demo/` |

## 已知边界

- 完整原生键盘、USB、摄像头和传感器适配仍属于后续平台能力，不是本阶段已交付内容。
- 当前自动扫描对象是随 Flutter 构建打包的示例资源；用户导入、原子安装和卸载 UI 仍需在安装库能力中实现，但目录与删除契约已经固定。
- Windows WebView2 代码和资源网关已实现；本次 Windows Debug 构建由用户手动验证成功，常规自动任务仍不执行 `flutter build windows`。
- 构建和测试结果记录在 `docs/verification/phase-03-2026-07-15.md`。
