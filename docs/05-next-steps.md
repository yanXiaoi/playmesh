# 下一步任务

## 当前阶段

第一至第六阶段均已完成并归档，事实基线见：

- `docs/status/phase-01-flutter-webview.md`
- `docs/status/phase-02-go-core.md`
- `docs/status/phase-03-game-sdk-fishing.md`
- `docs/status/phase-04-web-dev-channel.md`
- `docs/status/phase-05-complete.md`
- `docs/status/phase-06-complete.md`

当前保持 Playmesh `1.4.0+5`、Go Core `0.2.0`、Game SDK `1.3.0`、App Bridge SDK `1.1.0`、Developer API / OpenAPI `1.2.0`、Catalog API `1.1.0` 正式基线。第六阶段后不再开始新阶段，后续交付统一进入版本更新日志。游戏运行能力仍通过 `GoCoreRuntime -> GoCoreSessionClient -> Game SDK`，游戏代码不得直连 Core；App WebView 另由 `playmesh-app.js` 提供本机身份与当前可用设备能力；开发者网页通过独立 `DeveloperWebGateway` 调用 App 提供的正式开发者 API。

## 当前稳定基线

```text
游戏库扫描 playmesh-library/packages/{gameId}/main.json
  -> 游戏详情
  -> 应用 orientation，并行尝试可选全屏
  -> Game SDK / WebView
  -> 返回详情 / 退出游戏库 / 重新开始
  -> 恢复进入前的全屏状态和系统屏幕方向
```

```text
Go Core 监听 0.0.0.0:0
  -> 宿主上报实际端口
  -> Flutter 本机使用回环地址
  -> 分享层列出全部可用局域网 IPv4 地址
  -> /join/{code} 身份页与 app/controller/index.html
```

会话拓扑固定为：

- `single_screen_multiplayer`：创建会话的 App 主机是公共显示端与 Authority Client，不属于 `players`；玩家只能通过 Controller 加入。
- `multi_screen`：创建会话的 App 主机固定为 Authority Client，并可同时作为 Player 计入人数；不得把玩家首位或加入顺序当作 Authority 规则。

## 第四阶段交付基线

已归档的纵向链路：

1. 设置页可在独立固定端口开启开发者模式，默认 `16666`，并持久化端口、自定义或随机 token 和工作区路径。
2. 关闭开发者模式或 App 退出时停止监听；重新开启或 App 重启后恢复同一工作区链接，局域网设备可直接重连。
3. 工作区可新建项目，以 IDEA 风格项目树浏览并编辑文本文件；支持新建、删除、上传、快速批量操作和项目级本地历史，不提供嵌入式主页面预览。
4. 工作区提供运行按钮；多人项目运行后显示与游戏分享面板一致的地址切换、链接复制和二维码入口。
5. 已提供 `/dev/docs`、OpenAPI、Developer Session Schema、SDK Manifest、请求示例和当前接口鉴权/AI 可用性面板。
6. 文件变更、运行状态和客户端日志通过统一 SSE 通道同步；浏览器原生 `console` 输出保留，同时在存在开发者监听时复制到后台日志面板。
7. 设置页、Core 地址、开发者模式地址和游戏分享链接均支持长按或拖选复制。
8. App 内置 WebView 与外部浏览器使用同一套响应式工作区。

项目校验、文件行列诊断、5 分钟窗口项目级本地历史、机器契约、运行状态、SSE 和 Console 日志诊断闭环均已纳入交付。第四阶段不包含测试会话、虚拟玩家、设备模拟、热重载或游戏包导入/导出。

## 第五阶段完成

第五阶段已于 2026-07-17 完成。`entries.game`、`entries.controller` 与 `authority.entry` 已统一进入 Manifest、游戏库扫描、开发校验、App/浏览器运行、模板和机器契约；状态同步、自动延迟、网页性能层、应用包导入/导出与工作区文件整理也已完成。完成归档见 `docs/status/phase-05-complete.md`。

第五阶段把 SDK 升级为 AI 友好的轻量权威状态同步运行时，并加入 SDK 自动联机延迟显示。默认采用状态同步而不是帧同步：游戏或 AI 只维护权威状态、处理玩家输入、编写 tick 规则和渲染表现；SDK 负责连接、输入限频/合并、Authority tick、快照版本、状态分发、重连恢复和基础诊断。FPS 和延迟都由 SDK 在网页内自动渲染，多人游戏显示当前玩家到权威端并收到返回的往返耗时，和 FPS 共用左上角位置及开关；App 运行时由 App 工具坞控制开关，普通浏览器由 SDK 自己提供悬浮组件并放入昵称修改入口；单人游戏不显示延迟，游戏代码不需要手动创建组件。

第五阶段同时实现统一 `packages/{gameId}` 游戏库的导入与导出：导入包经过路径、清单和资源校验后原子安装；导出由用户直接选择系统保存位置，因此不产生需要清理的临时分享包。开发项目与正式项目使用同一目录，不增加单独发布步骤。

第五阶段还允许游戏在 `main.json` 中自定义运行入口，覆盖普通游戏首页、控制器首页和权威 JS。当前模板的默认值保持为：普通游戏首页 `app/index.html`、控制器首页 `app/controller/index.html`，权威 JS 使用当前 `authority.entry` 约定。自定义入口只能指向当前游戏包 `app/` 内文件，必须由项目校验拦截越界路径、缺失文件和外部 URL。应用侧导入/导出只处理根目录存在 `main.json` 的 Playmesh 游戏包；完整 HTML 小游戏通过开发者工作区上传文件，并使用解压、移动、复制、粘贴整理目录，不设置单独导入口。

第五阶段实施任何 SDK/API/模板改动后，必须同步更新所有相关项目文档、SDK 文档和 AI 提示词文档，特别是 SDK Manifest、JSON Schema、OpenAPI、开发者工作区说明和 `assets/playmesh-library/public/developer/prompts/` 下的提示词。

## 第六阶段完成

第六阶段已于 2026-07-18 完成。加入 App 不再要求预装游戏，而是直接加载权威主机提供的当前入口；游戏与控制器的全屏请求不再参与运行前置条件，失败时只提示，并可在 WebView 悬浮工具中按需进入或退出。Android 已接通系统文件打开/分享入口：压缩包复用 Playmesh 包导入，单个 HTML 使用无 SDK 的独立 WebView，游戏包导出交给系统保存或分享。

运行身份拆分为两层：`playmesh.js` 始终使用 Authority 主机的会话、日志和游戏数据；App WebView 自动注入 `playmesh-app.js`，只提供当前 App 的持久身份，以及当前游戏已声明、用户本次确认且设备可用的硬件能力。普通浏览器不加载 App Bridge，但保留 `playmesh.app` 安全空实现，并在自身 `localStorage` 持久化随机玩家 ID 和昵称。Core 拒绝同一 ID 的并发在线连接，仅在旧连接离线后允许同 ID 重连；当前 Game SDK `1.3.0` 暴露 `onPlayerJoin`、`onPlayerLeave`、`onPlayerReconnect`、`session.finish()` 与 `app.onDevice()`。

移动端开发工作区顶部操作、二级菜单、弹层边界、项目搜索选择、文档跳转和界面切换动效已收口。完整归档见 `docs/status/phase-06-complete.md`，验证记录见 `docs/verification/phase-06-complete-2026-07-18.md`。

## 后续变更要求

后续所有更改都必须按需升级版本号，并遵循 `docs/06-engineering-standards.md` 当前定义的语义版本与 Flutter 构建号规则。每次变更必须评估 App、Go Core、Game SDK、App Bridge SDK、Developer API、Core 协议和游戏包中哪些组件受影响；只升级受影响组件，但必须同步代码常量、模板、机器契约、编辑器补全、测试与文档。

不再创建第七阶段或新的阶段状态文档。每个发布版本在 `docs/version/{MAJOR.MINOR.PATCH}.md` 保存详细更新日志，并同步 `lib/core/release/playmesh_release_notes.dart` 供 App 设置页显示简略版；规则与当前入口见 `docs/version/README.md`。

## Playmesh 1.2.0 完成

本机游戏库可以通过独立 Catalog Gateway 分享，提供带可选 Bearer Token 的分页搜索和标准游戏包下载。现有游戏库内部新增在线游戏库入口，可并发读取多个启用源、按 ID 去重、扫码配置与分享源，并通过可停止/删除的多选下载队列安装游戏。详细接口和边界见 `docs/catalog-api.md`，版本事实见 `docs/version/1.2.0.md`。

## 必须保持的边界

- 游戏包直接位于 `playmesh-library/packages/{gameId}/`，不增加版本或 `files` 中间目录。
- `packages/{gameId}/app/` 是当前游戏唯一可映射目录；平台公共 SDK、头像等资源位于 `playmesh-library/public/` 并通过 `/playmesh/...` 暴露，`data/` 与 `cache/` 永不参与静态映射。
- 持久化文件直接位于 `packages/{gameId}/data/{bucket}.json`，不增加 `{userId}` 目录。Bucket 名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。
- Core 每次启动都使用系统分配端口，实际端口由宿主上报。
- 开发者 Gateway 与 Core 分离，默认固定端口 `16666`，可在设置页修改；不得为了修改开发者端口重启 Core。
- Android 发布物包含 `playmesh_core.aar`，Windows 发布物包含 Runner 同目录的 `playmesh-core.exe`。
- `orientation`、`displayModes` 和 `modes` 是独立维度；当前 `displayModes` 与 `modes` 都只能声明一个值。
- 浏览器分享 token 在当前游戏会话期间有效，关闭附加层和重新开始不撤销；退出游戏、会话结束或 Core 重启后失效。
- 分享地址列表可点选，二维码始终对应当前选中的地址。
- 所有 Bucket 数据只保存在开始游戏的 Authority 主机；浏览器走主机 HTTP 存储端点，其他 App 玩家走会话内存储 RPC。
- FPS 由游戏在真实渲染点调用 `playmesh.performance.reportFrame()` 上报，默认显示在左上角并可从悬浮工具坞关闭。
- 各平台构建和运行由用户自行验证，自动任务不在 Android、iOS、Windows 等平台尝试编译或运行验证。
- 公共显示端不得进入 `players` 或提交玩家动作。

## 明确排除

- 完整房间列表或局域网自动发现。
- 云端账号和异地联机。
- 完整原生键盘、USB、摄像头适配，以及加速度计、陀螺仪之外的传感器适配。加速度计和陀螺仪已在 Playmesh 1.3.0 通过 App SDK 接入。
- iOS 发布和云端游戏包分发。
- 创意工坊与生产级签名审核系统。
