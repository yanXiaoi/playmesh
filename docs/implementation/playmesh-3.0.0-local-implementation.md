# Playmesh 3.0.0 本地功能实现说明

- 文档类型：已实现工程说明
- 对应 App：`3.0.0+23`
- 编制日期：2026-07-27
- 适用仓库：Flutter App、Go Core、Go Server、Developer CLI、Developer Workspace
- 需求来源：`docs/下一步方案.md`（只读；本文件不替代需求规格）

本文说明本轮功能在本地仓库中的实际落点、运行链路、数据边界、安全约束、生成关系
和验证入口。后续维护应更新本文件和相应领域文档，不在需求规格上记录实现细节。

## 1. 版本与破坏性边界

| 组件 | 当前版本 | 处理 |
| --- | --- | --- |
| Playmesh App | `3.0.0+23` | MAJOR：本地资料、源配置、统计和 Catalog 破坏性升级 |
| Catalog API | `2.0.0` | MAJOR：publicURL、latest-only、版本化下载、图标、上传声明 |
| Game SDK | `3.0.0` | MAJOR：`playmesh.app.ui` 平台功能统一分组，移除旧工具栏公开入口 |
| App Bridge SDK | `3.0.0` | MAJOR：统一游戏菜单、分享、日志、全屏、信息、性能与退出命令 |
| Go Core | `0.5.0` | 玩家头像同步与协议升级 |
| Core 协议 | `1.3.0` | 玩家 avatar 字段 |
| Relay 协议 | `2.0.0` | 契约不变 |
| Developer API / OpenAPI | `2.3.0` | 多源发布与定义驱动的能力交互测试操作 |
| Developer CLI | `1.4.0` | 根 `icon.png` 拉取、打包和上传 |
| Go Server SQLite | schema v3 | 只接受全新 v3 数据库 |

不提供旧格式兼容读取。发现旧 App 源配置、用户资料或使用统计时，文件会被隔离并从
空 v2 状态开始；Go Server schema 不匹配时拒绝启动。Catalog 1.x、旧二维码和缺少
版本的下载请求直接拒绝。

## 2. 实施结构

```text
严格语义版本 + v2 本地格式 + Catalog 2.0
  ├─ 本地游戏统计/索引/搜索/更新
  ├─ 在线首页/聚合搜索/源详情/下载
  ├─ 根 icon.png/流式导出/临时文件管理
  ├─ Developer Workspace 多源发布
  └─ Go Server 账号/所有权/审核/上下架/删除

用户资料 v2 + 头像规范化
  └─ Go Core 权威会话头像
       └─ Game SDK PlaymeshPlayer.avatar

统一 SDK feature 注册表
  ├─ avatar 全返回面
  ├─ playmesh.app 平台功能统一入口
  │    ├─ openSharePanel()
  │    ├─ showToolDock() / hideToolDock()
  │    └─ exitGame()
  └─ WebView 平台 UI、键盘/TV 与本地化

统一本地化清单 + UI 偏好
  ├─ App app.json（唯一 App 文案源）
  │    ├─ Flutter App
  │    ├─ Developer Workspace
  │    └─ 平台注入游戏 Web UI
  └─ Go Server go-server.json（独立部署界面）
```

## 3. 本地数据与隔离策略

### 3.1 游戏源配置

主要实现：

- `lib/core/catalog/game_catalog_models.dart`
- `lib/core/catalog/game_catalog_preferences.dart`
- `lib/core/catalog/online_game_catalog.dart`

源配置 v2 保存：

```text
id
enabled
showOnHome
name                 # 用户本地名称
host + token         # publicURL 拆分后的读取配置
uploadKey            # 本机私密写入凭据
declaration          # 最近一次 /apps/info 只读快照
lastValidatedAt
lastError
```

导入入口只接受 `publicURL?token=...`。扫码和文本输入共用
`GameCatalogController.verifyAndUpsertSource`，先请求 `/apps/info`，成功后才保存。
分享源配置只重新组合 publicURL，不序列化上传密钥。

### 3.2 游戏使用统计

主要实现：

- `lib/core/game_package/game_library_local_metadata.dart`
- `lib/core/game_package/game_library_repository.dart`
- `lib/models/game_summary.dart`

v2 文件以 gameId 为键：

```json
{
  "version": 2,
  "games": {
    "com.example.game": {
      "lastOpenedAt": 1785031200000,
      "launchCount": 12,
      "futureField": {}
    }
  }
}
```

进入实际运行页时原子更新 `lastOpenedAt` 并增加 `launchCount`。容量限制为 2048 项、
单项 16 KiB、总文件 4 MiB，超限按最旧记录清理。搜索只读内存索引，不请求网络或
修改状态。

`GameLibraryUsageStats` 在接收扩展 JSON 时立即执行防御复制，并递归冻结其中的
`Map`/`List`；`readUsageStats` 返回的顶层映射及每条统计中的完整扩展树同样只读。
调用方因此不能通过公开快照修改内存缓存，也不能把修改污染到后续原子写回。

### 3.3 用户资料与头像

主要实现：

- `lib/models/user_profile.dart`
- `lib/core/profile/user_profile_store.dart`
- `lib/core/profile/avatar_image.dart`
- `lib/features/profile/profile_page.dart`

profile v2 只保存稳定本机 userId、昵称和嵌套头像摘要；规范化 PNG 单独保存：

```json
{
  "formatVersion": 2,
  "userId": "local-user-id",
  "nickname": "玩家",
  "avatar": {
    "path": "profile/avatar.png",
    "sha256": "64 位小写十六进制摘要",
    "updatedAt": 1785031200000
  }
}
```

没有头像时 `avatar` 为 `null`；v2 不接受旧的扁平头像字段。选择图片时先在完整解码
前检查 8 MiB 源文件、4096 像素单边和 16 MiPixel 上限，再使用 Flutter 图像解码器
应用方向信息，中心方形裁剪并输出 256×256 PNG，最大 512 KiB。无自定义头像时平台
显示系统人物图标，会话字段为 `null`。

## 4. Catalog、本地库与包链路

### 4.1 在线首页与搜索

界面：

- `lib/features/games/online_game_library_page.dart`
- `lib/features/games/game_library_page.dart`
- `lib/features/home/home_page.dart`

首页只读取 `enabled && showOnHome`，每个源拥有独立页码、加载更多、空、错误和重试
状态，不跨源去重。标题使用本地源名称。

搜索读取全部启用源，各源独立翻页并把已加载页重新聚合；一个源的页数不会推进其他
源。后台更新检查会遍历每个源的全部分页，并隔离单源失败。跨页重复 gameId、无进展
分页和超过安全页数的响应会作为该源协议错误停止继续读取。

`aggregateCatalogOffers` 按 `gameId + publisherKey` 聚合：

- 发布者是 `author.trim()`；空发布者用 sourceId 隔离。
- 每个源只能贡献自己的当前最新 offer。
- 代表信息取最高语义版本，同版本按本地源顺序。
- 一级结果按 launchCount、lastOpenedAt、版本、名称、groupKey 稳定排序。
- 版本层保留所有原始 source offer，由用户选择实际下载源。

下载任务键为 `sourceId + gameId + version`。快速升级在安装前再次检查 gameId、
发布者精确相同且目标版本严格更高，避免检查完成后本地版本变化造成竞态。

App 自带只读 Catalog 只公开能够重新解析且与缓存 id、version 一致的本地包。
`manifestError` 待修复项、内置资源项和扫描后又被并发改坏的单个包都会逐项跳过，
不会让 `/apps/list` 隐藏其他合法游戏；其下载和图标接口同样返回
`version_not_available`，不暴露待修复内容。

在线首页 offer、按源“加载更多”、聚合搜索摘要与按源分页操作都以
`sourceId/gameId/version/groupKey` 组合成稳定焦点 ID。异步刷新或分页完成后，目标仍
存在则恢复原目标；目标被删除时按刷新前顺序选择最近仍存在的 offer，再回退到搜索
主操作。版本/来源选择与本地更新候选也使用稳定 Widget key，不把焦点语义绑定到列表
下标。Widget 契约覆盖“聚焦加载更多，最后一页移除该按钮后回到最近 offer”的路径。

### 4.2 本地统一搜索

本地库只有一个输入框，字段覆盖发布者、名称、gameId、描述、版本和 tags。输入
200 ms 防抖，Enter 立即执行；关键词按空白拆分，跨字段 AND 匹配。空查询恢复完整
列表与进入搜索前的滚动起点。损坏 Manifest 的可恢复错误摘要也进入同一预构建索引。
索引只对拉丁字符折叠大小写，中文和其他文字按原字符匹配。`Ctrl/Cmd+F` 聚焦输入框
但移动端不自动弹出键盘。

页面先用缓存渲染，再后台检查全部启用源。更新详情按目标语义版本倒序，列出同版本
全部来源；单源失败只进入本次检查摘要。

### 4.3 icon.png 与不可信包

主要实现：

- `lib/core/game_package/game_package_icon.dart`
- `lib/core/game_package/game_package_transfer_service.dart`
- `lib/core/game_package/file_game_library_scanner.dart`
- `dev-cli/internal/packaging/archive.go`

允许包根：

```text
main.json
capabilities.json  # 可选
icon.png           # 可选
app/
```

`icon.png` 经过大小、PNG chunk/CRC、尺寸、像素和解码预算校验。无效图标被忽略，
不会阻止安全游戏包安装；ZIP 路径、符号链接、重复项、危险扩展名、文件数量和展开
预算仍严格拒绝。

列表、首页和详情使用 `GamePackageIconImageProvider`。其 Flutter 图片缓存键除固定
根路径外还包含文件类型、大小、修改时间和状态变更时间；原子升级继续覆盖规范路径
`icon.png`，但新文件不会命中旧像素缓存。相同文件修订在不同页面仍复用正常的
Flutter 图片缓存。

`main.json` 模型不再包含 `icon` 或 `permissions` 属性。读取 JSON 时将它们和其他
任意未知键一样静默忽略，不执行旧字段校验、不发兼容诊断，也不赋予任何语义；
Manifest 序列化、Go Server 规范化、游戏包导入/导出、Developer Workspace
保存和 CLI SDK 版本重写均使用当前已知字段投影并丢弃所有未知键，确保新产物只通过包根 `icon.png` 提供
图标、只通过同级 `capabilities.json` 声明受保护平台能力。共享 gameId 校验为
1–64 个 ASCII 字符，首字符是字母或数字，后续仅允许字母、数字、点、下划线和
连字符。

### 4.4 导出与临时文件

主要实现：

- `lib/core/game_package/game_package_share_files.dart`
- `lib/core/game_package/game_package_transfer_service.dart`
- `lib/features/games/game_detail_page.dart`
- `lib/core/catalog/game_catalog_server.dart`

导出名称统一由 `gamePackageShareFileName` 生成：

```text
游戏名称-v游戏版本.zip
```

ZIP 使用 `ZipFileEncoder.addFile` 流式读取磁盘文件，不把完整包装入内存。Android
分享使用专用目录中的唯一临时路径，并通过系统分享覆盖显示文件名；App 启动和每次
分享前清理非活动旧文件，系统分享返回后只释放活动租约，由下一次清理删除，避免接收
应用尚未打开 URI 时文件已被提前删除。活动租约防止并发分享互删。Catalog/发布链路
同样使用专用临时目录、活动租约和最终清理；网络响应直接流式读取 ZIP。

## 5. Developer Workspace 多源发布

主要实现：

- `lib/core/developer/developer_web_gateway_contract.dart`
- `lib/core/developer/developer_game_catalog_publisher.dart`
- `lib/core/developer/operations/publishing/`
- `assets/playmesh-library/public/developer/workspace.html`
- `assets/playmesh-library/public/developer/workspace.js`

端点：

```text
GET  /dev/api/projects/{projectId}/publish
POST /dev/api/projects/{projectId}/publish
```

GET 只返回启用、声明支持用户上传且已配置上传密钥的源，并只暴露
`id/name/protocolVersion/maxUploadBytes`。响应不含 Host、读取 Token 或上传密钥。

POST 请求体只允许 `sourceIds`。服务端重新保存并完整校验项目，失败时不打包；校验
通过只生成一个 ZIP，逐源上传并通过 SSE 报告状态。部分成功不回滚成功源，用户可只
重试失败项。错误响应有读取上限，所有路径最终清理 ZIP。

Workspace 视觉层固定使用深色编辑器配色，不随 App 的 light/dark 外观切换重绘，
但语言、主题选择控件及其写入仍通过统一 App UI 桥接；因此在 Workspace 内修改主题
会更新 App，Workspace 自身仍保持同一套高对比度代码界面。项目选择使用项目图标，
目录按展开状态使用文件夹图标，代码、图片、压缩包、`main.json` 和其他资源分别使用
不同的内联 SVG 图标与语义色。手机工具栏固定为“项目 / 运行 / 保存 / AI / 更多”一行，
发布入口在手机端进入“更多”，避免第六项换行后被固定高度裁切；桌面端保留图标和
文字。AI 使用工具栏唯一的高饱和强调色，运行、保存和更多保持次级层级。

### 5.1 定义驱动的能力交互测试

平台能力测试不再只调用插件的 `test()`。新增三个 Developer Operation：

```text
POST   /dev/api/capability-tests/instances
POST   /dev/api/capability-tests/instances/{instanceId}/invoke
DELETE /dev/api/capability-tests/instances/{instanceId}
```

`DeveloperCapabilityTestService` 持有测试实例和事件订阅。创建时按 `code` 精确查找
注册插件，平台不可用返回 `409 capability_unavailable`；调用时要求 `method` 精确
等于描述符中某个 `methods[].name`；释放时先取消订阅，再调用实例 `dispose()`。
实例发出的已声明事件通过全局 Developer SSE 转为 `capability.test.event`，流错误和
未声明事件转为 `capability.test.error`。

Workspace 只实现一个通用递归表单渲染器：`optionsSchema` 生成创建参数，
`argumentsSchema` 生成每个方法的调用参数，支持对象、数组、枚举、布尔、数字、
整数和字符串。参数区不显示原始 JSON，也不要求开发者手写 JSON。存在精确
`start` / `stop` 方法时，持续测试按钮调用对应方法；否则创建实例即开始接收事件，
停止时释放实例。所有请求结果和事件继续原样进入右侧 JSON 回显。

固定界面文案来自 App 统一 `workspace.*` 语言包，能力 code、方法名、参数、结果、
事件数据和错误正文不翻译。当前内置能力均可由描述符完整表达，因此没有增加自定义
测试 HTML 字段，也没有在 Workspace 为任何具体能力写死页面。

## 6. Go Server 账号与发布治理

主要实现位于 `go-server/internal/` 的 `user`、`store`、`packages`、`catalog`、
`admin`、`server`、`middleware` 和 `webui`。

### 6.1 账号

- 邮箱注册和登录，密码 10–128 字符。
- `allowUserRegistration=false` 隐藏公共入口并拒绝新注册；既有账号仍可登录。
- 邮箱验证可配置；验证 Token 一次性、过期且只存摘要。
- 展示名称可修改，注册初值取邮箱账号。
- 上传密钥满足大小写、数字和特殊字符，HMAC-SHA256 后保存，明文只显示一次。
- 浏览器会话使用 HttpOnly/SameSite=Lax Cookie 与 CSRF；HTTPS 才加 Secure。

### 6.2 所有权和版本

首次有效上传在事务中取得 gameId 所有权，后续只按账号 ID 判断。新版本必须严格
高于数据库最高版本；同版本、低版本和并发抢占返回 409，无文件或数据库残留。包内
author 被账号展示名称覆盖，不能伪造发布者。

Catalog 每个 gameId 只公开当前最高 `approved + published` 版本。最高 approved
下架后不回退历史版本；图标和下载也必须精确匹配当前公开版本。

### 6.3 审核、上下架与删除

- 管理员通过后默认 published。
- 管理员可上架、下架；所有者可管理自己的已通过版本。
- pending 可由所有者删除；approved 必须先下架。
- 删除先事务标记 `deleting` 并写审计，再删除包/图标，最终事务删记录并在最后一个
  版本时释放所有权。
- `deleting` 不进入 Catalog、下载、管理员下载或用户门户。
- 启动立即重试，运行期间每 30 秒后台重试；审计不因游戏行删除而丢失。

完整部署和安全边界见 `go-server/README.md` 与
`docs/platform/go-server-development.md`。

## 7. 会话头像与 SDK

主要实现：

- `go-core/internal/session/`
- `lib/core/session/`
- `lib/core/storage/game_storage_service.dart`
- `lib/core/storage/game_bucket_http.dart`
- `lib/core/game_sdk/features/game/`

权威主机把 App 玩家规范化头像保存为：

```text
/bucket/_sys-user-avatars/{userId}.png
```

新 Authority 会话在同步本机或远端玩家头像前先清空该游戏上次异常退出可能遗留的
系统头像目录；正常停止、会话关闭和运行桥关闭也再次清理。加入方 App 不执行这项
Authority 存储清理。

所有 `_sys-` Bucket 对游戏代码保留；创建、上传、清空和普通 Bucket 访问均拒绝。
头像固定 URL 使用 ETag 和 `no-cache`，替换内容后 URL 不变但缓存会重新验证。
HTML 玩家不能上传头像，只能修改昵称。

go-core 不再把 `POST /v1/sessions/join` 请求体中的 `source` 当作授权事实。公开
浏览器即使提交 `source=lan_app`，会话仍记录为 `lan_html`；`server` 只保留现有
Relay 展示语义且没有头像权限。LAN App 身份由服务端从接入路径推导：

- Authority/本机 App 的原生请求来自 loopback 且没有浏览器 `Origin`；
- 远端 App 的 WebView 请求经过 App 管理的 Core Upgrade 隧道，到达 Core 时仍是
  loopback，并保留内层浏览器的 Host；该 Host 端口与 Core 实际本地监听端口不同；
- 普通分享页浏览器直接访问 Core，不符合上述任一条件，客户端不能设置浏览器的
  Host 来伪造受控隧道。

`Player.source` 仅用于协议快照和界面展示。Store 另存不序列化的 `playerAccess`，
头像上传和最终 commit 只检查这份服务端接入身份；即使内存中的公开 `source` 字段
被误设为 `lan_app`，HTML 凭据仍无头像权限。相同 playerId 重连时必须保持同一
接入身份，防止已断线 App 玩家被 HTML 凭据替换并继承头像。受控隧道必须继续透明
保留内层 Host，不得把它改写为 Core 的监听地址，否则远端 App 会安全降级为 HTML
身份；Relay 的 `server` 声明优先于 loopback/Host 隧道特征，按当前契约始终不上传
头像。

Game SDK `PlaymeshPlayer` 的所有返回面在 nickname 同级返回：

```ts
readonly avatar: string | null;
```

包括当前玩家、全部玩家、加入/离开事件、Authority 上下文、快照和重连。路径来自
Authority 同源资源，不暴露本机文件路径。

App 级平台功能统一为：

```ts
playmesh.app.ui.initializeBrowser(): boolean
playmesh.app.ui.configure(options): PlaymeshAppUiOptions
playmesh.app.ui.showGameSidebar(): Promise<boolean>
playmesh.app.ui.restartGame(): Promise<void>
playmesh.app.ui.openSharePanel(): Promise<void>
playmesh.app.ui.openLogs(): Promise<void>
playmesh.app.ui.setFullscreen(enabled): Promise<void>
playmesh.app.ui.openGameInfo(): Promise<void>
playmesh.app.ui.togglePerformance(): Promise<void>
playmesh.app.ui.exitGame(): Promise<void>
```

分享入口由 App 和 SDK 双重检查 Authority、有效用户激活、前台 UI 和频率。方法只打开现有分享
面板，Promise 不返回 Token、URL 或二维码。重复调用复用同一打开任务；面板已经
显示时只把焦点移回同一个关闭按钮，关闭后 800 ms 内的 SDK 重开返回
`rate_limited`。

App SDK 在当前 HTML 的 Shadow DOM 中创建屏幕居中的响应式游戏菜单、信息层和日志层；
原生 Flutter 页面不再挂载另一套工具栏。`showGameSidebar()` 的名称为兼容公开契约而
保留，当前行为是打开居中菜单并把焦点移到“继续游戏”；菜单关闭后恢复此前的游戏 DOM
焦点。菜单开关不发送 `pause` / `resume`。SDK 不公开 `hideGameSidebar()` 或
`onMenuRequest`。

`playmesh-app.js` 在捕获阶段处理 Escape、浏览器返回、菜单键和对应 Android/遥控器
keyCode，原生层不再注入或转发菜单意图。App WebView 不创建悬浮入口；普通浏览器默认
创建可拖动悬浮入口，或者通过 `initializeBrowser()` 只启用菜单，由游戏自己的按钮调用
`showGameSidebar()`。只有游戏完整提供替代 UI 时才用
`configure({fallbackUi:false})` 关闭平台兜底。`exitGame()` 复用 App 退出链路，完成
会话和存储清理后返回上一页面；远程加入 App 可使用菜单与退出，但不能调用 Authority
分享入口。

Game SDK 中浏览器空 App 宿主和 `PlaymeshAppApi.version` 只写
`__PLAYMESH_APP_SDK_VERSION__` 占位符。Dart `SdkFeatureRegistry` 即时组装和
`tool/generate_sdk.mjs` 正式生成都先取得同一批次 App SDK 版本，再同步替换
`playmesh.ts`、`playmesh.js`、`playmesh.d.ts`，禁止在 Game SDK 中另写固定 App SDK
版本或 `*-empty` 伪版本。

## 8. 提示词与生成链

AI 默认提示词唯一手写源：

```text
assets/playmesh-library/public/developer/prompts/
  manifest.json
  common.txt
  agent-common.txt
  custom-ideas.txt
  solo.txt
  multiplayer.txt
  multi-screen.txt
  single-screen-multiplayer.txt
```

`DeveloperAiPromptTemplateStore` 从清单加载默认模板，用户覆盖保存在本地；恢复默认
重新读取随包资源。Dart、JS 和构建脚本不得复制默认正文。

正式构建：

1. 生成 SDK、声明、Schema、补全和提示词派生内容。
2. 校验提示词清单与源文件 SHA-256。
3. 构建发行目标。
4. 从发行 Asset 再读出提示词并复核摘要。

脚本：

```powershell
node tool/generate_sdk.mjs
tool/verify_release_assets.ps1
tool/build_release.ps1
tool/build_windows_release_ninja.ps1
```

`build_release.ps1` 是总发布入口并只生成一次 SDK；它调用 Windows 子构建时传入
`-SkipSdkGeneration`，避免同一批次重复生成。Android/Windows 之外的平台不进入
本轮发布目标。

## 9. UI、本地化、主题与输入

统一清单：

```text
assets/playmesh-localization/manifest.json
assets/playmesh-localization/locales/{locale}/
  app.json
  go-server.json
```

语言列表、默认语言、fallback 和 UI 开关全部来自清单。初始启用 `zh-CN`、`en-US`；
增加语言不需要修改 Dart、JS 或 Go 的固定语言数组。

`app.json` 是全部 App 所有界面的唯一显示文案源，覆盖 Flutter 页面、App 内置
Developer Workspace，以及 Game SDK/宿主注入游戏 WebView 的居中游戏菜单、能力确认、
昵称、信息和日志界面。工作区不再拥有 `developer.json` 或内置 `zh-CN`/`en-US`
对象，也不能用 HTML/JS fallback 文本形成第二份词典。

联动链路为：

```text
App 解析 locale + fallback + app.json
  -> Developer Gateway 生成 locale + theme + messages 的 App UI 快照
  -> WebView 宿主生成只读 locale + messages 投影
  -> Workspace 使用 workspace.* 投影
  -> 平台游戏 UI 使用 platform.game.* 投影
  -> Android 开发者前台通知使用 platform.android.developer_service.* 投影
  -> App 切换语言时向已打开 WebView 推送同一投影
  -> App 切换语言时刷新运行中的 Android 前台通知
  -> Web 端更新 document.lang、当前 DOM 与后续动态渲染
```

投影只包含目标命名空间，不允许工作区或游戏脚本读取完整 App 词典；Web 端不保存
脱离 App 的 locale 或 theme 偏好。独立部署的 Go Server 不属于 App 内界面，用户门户和后台
继续读取 `go-server.json`。API 路径、机器错误 code、游戏内容、用户内容和原始日志
不翻译，只由渲染层使用统一词条解释状态。

Developer Workspace 由 `DeveloperWorkspaceLocalizationBridge` 接入当前
`PlaymeshUiController`。`GET /dev/api/localization` 返回版本化的 locale/mode、
可选语言、`themeMode`、实际显示 App 的 `effectiveTheme`、主题切换开关和
`workspace.*` 消息；`PUT /dev/api/localization` 接受 `localeId` 和/或
`themeMode`，并调用同一个 App 控制器后返回新快照。Gateway 在返回 Workspace HTML
时同步注入 App UI 快照；HTML 在 CSS 加载前固定应用 Workspace 深色编辑器主题，
`effectiveTheme` 只用于显示和修改 App 偏好，不再改变 Workspace 配色。Workspace
不读取 `playmesh.developer.theme`、`matchMedia` 或其他浏览器私有主题状态。桥接端点测试位于
`test/core/developer/developer_web_gateway_test.dart`，静态 key、双语占位符、
`app.json` 单一来源和本地内联图标资源由
`test/core/localization/developer_workspace_localization_contract_test.dart` 校验。
`BuildContext.tr` 不接受调用点 fallback；缺少本地化 delegate/catalog 或 key 都抛出
`FlutterError`，Widget 测试必须挂载真实 catalog 和 delegate。catalog 建立前若启动
失败，只显示机器诊断码和原始错误，不额外维护中英文启动文案。所有 Dart 调用点及每个
启用语言的静态 key 覆盖由 `tool/test_flutter_localization_source.mjs` 校验。

Android `DeveloperForegroundService` 的通知没有独立资源词典。Flutter 从当前
`PlaymeshUiController` 与平台 locale 解析出实际显示 App 的语言，再只投影
`platform.android.developer_service.*` 五个固定文案，经
`playmesh/developer_background_host` 传给 `MainActivity`。启动服务和运行中刷新使用
相同契约；`port` 始终作为整数单独传输，Java 只将其原样替换进 `{port}`，不把端口、
工作区地址或其他动态数据当作 i18n key。固定语言切换与系统语言变化都会刷新正在运行
的通知，服务未运行时刷新调用不产生通知。

Workspace 词条只覆盖固定 UI 外壳；项目/游戏/源/发布者/昵称/标签/文件名、日志以及
未知或开发者自定义的 API 文本均原样显示，进入固定句式时也只作为不变参数插值。
首次资料尚未由用户命名时使用 locale-neutral 的 `Playmesh Player` 种子；一旦进入
资料、会话或 Catalog，它和用户修改后的昵称一样都是原始动态值，不随 App 语言切换。
平台内置能力、提示模板、校验诊断和本地历史使用显式 code/ID 白名单映射 App 词条；
后端仍保留原始 `message`/`summary`，并提供独立参数对象。未知 code/ID 直接显示原文，
路径、错误详情等动态参数不会参与 key 查找。有限协议状态采用同样的白名单边界。
工作台视觉样式合并在单一
`assets/playmesh-library/public/developer/workspace.css`，不保留版本覆写样式源；图标
统一由本地 `assets/playmesh-library/public/developer/workspace-icons.js` 生成内联 SVG。
页面不再通过外部 SVG sprite 的 `<use href>` 加载图标，避免部分 WebView 把
`SVGAnimatedString` 当作失败资源并重复上报 `resource.error`。

Developer Gateway 的 HTML、静态资源、API、错误和 SSE 响应统一带
`Referrer-Policy: no-referrer` 与 `X-Content-Type-Options: nosniff`。前者阻止入口
URL 查询参数中的 developer token 随外链或子资源 Referrer 传播，后者禁止浏览器把
错误 MIME 当作可执行资源嗅探；当前不添加会破坏 CodeMirror 和内联首帧引导的 CSP。

日志边界逐层保持相同：Flutter 游戏日志层、Game SDK Shadow DOM 日志层和
Developer Workspace Console 只翻译固定标题、按钮与空状态；`event.message`、
`event.stack`、`event.source`、`event.level` 以及 API 返回的日志正文逐字原样输出，
不查找、拼接或生成 i18n key。

损坏 `main.json` 的扫描结果只保存原始 `remarks`（没有时为空）和机器状态
`manifest_repair_required`；不会向游戏简介或状态字段注入中文。游戏详情、游戏库卡片
和游戏内信息面板仅在动态简介为空时从 App 的 `game.repair_description` 显示修复说明，
非空游戏简介始终逐字保留。

平台游戏 UI 的 App WebView 路径从当前 `PlaymeshLocalizations` 截取
`platform.game.*`，通过私有 `_playmeshPlatformUi` bootstrap 在
`playmeshApp.ready` 前交给 Game SDK，消费后立即删除；后续语言切换使用私有
`platform.ui.configure` 更新 SDK Shadow DOM。普通浏览器分享网关按 localization
manifest 注入全部启用语言的受限 browser config；SDK 按浏览器系统语言为平台覆盖
层独立选择投影并在消费后删除。该私有配置不进入公开 `.d.ts`、SDK Manifest、游戏
提示词或 API JSON。

游戏业务只通过同步只读 `playmesh.runtime.getLocale(): string` 获得 locale，并在
`await playmesh.ready` 后调用。App WebView 返回当前显示/加入方 App locale，不读取
Authority 主机语言；普通浏览器直接返回 `navigator.languages`、`navigator.language`
中第一个合法系统 locale，失败回退 `zh`，即使覆盖层没有该语言也不改写返回值。
浏览器平台覆盖层独立使用 `zh-CN` 选择 App 提供的 `platform.game.*` 文案，公开游戏
locale 与覆盖层文案回退是两个常量、两条链路。
公开 API 不返回 messages，游戏包自行提供业务翻译，平台不会翻译游戏 DOM、资源、
标签、用户内容或日志。

主题为 `system/light/dark`，偏好独立于业务数据。主要设计令牌：

| 模式 | Canvas | Surface | Ink | 主色 | 辅色 |
| --- | --- | --- | --- | --- | --- |
| light | `#F4F7F6` | `#FFFFFF` | `#17211D` | `#087F6D` | `#2F6FED` |
| dark | `#101614` | `#18201D` | `#EAF1ED` | `#4CC7AE` | `#78A6FF` |

首页恢复上一版的信息层级和空间关系：顶部保留品牌，右上角提供快速扫码加入和设置；
带用户头像、昵称的简介 Hero 是用户资料唯一入口。Hero 下方直接放置
“游戏库－最近游戏”快捷栏，优先按最近启动时间排列，最多显示三项；启动记录不足时
按游戏库顺序补位。点击条目直接启动游戏，标题入口进入完整游戏库。快捷条目不显示
简介，只显示发布者、版本、联机/单机、单屏多人/多屏多人和横屏/竖屏；完整游戏库则
同时保留简介，并使用左侧大图标重排信息。其后只保留“加入对局 / 在线游戏库”两个
主操作，不再设置独立游戏库卡片。

在线游戏库右上角同时提供扫码添加游戏源和游戏源管理；添加页不显示 publicURL 或
`/apps/info` 请求提示。设置页把软件与构建版本放在首位，游戏源入口统一命名为
“游戏源管理”，副标题只描述“管理你的游戏源”。页面背景使用低对比度几何网格，
Hero 允许使用受控的青绿到蓝紫渐变；其余普通组件圆角不超过 8px/dp，不使用装饰
渐变、光晕或 `transition: all`。二维码始终白底。
reduced motion/disable animations 下移除非必要动画。

App 游戏悬浮工具和普通浏览器 SDK 覆盖层保持同一信息层级：运行日志为一级按钮；
“更多”只包含游戏信息与显示/隐藏性能信息，不再包含 App 设置。浏览器昵称编辑保留在
游戏信息弹窗内。日志标题、空态和按钮来自 `platform.game.*`，日志正文继续逐字输出。
悬浮工具支持 App SDK 主动显示和隐藏；SDK 显示时自动聚焦工具，工具操作完成后自动
隐藏，手动展开时则自动收起为悬浮按钮。

App WebView 每次按当前有效 `Brightness` 生成 `platform.ui.configure`；普通浏览器
覆盖层使用 `system` 并监听 `prefers-color-scheme`。能力确认、浏览器工具/昵称/
信息/日志以及 App 性能浮层的 Shadow DOM 都通过同一 `data-theme` 更新，不维护
独立主题偏好。UI 偏好写入按调用顺序串行；单次磁盘失败会返回给当前调用方，但队列
会恢复，之后的语言或主题变更仍可继续持久化。

Flutter 统一快捷键层位于 `lib/ui/focus/`。游戏运行容器支持：

- F10、TV Menu、手柄 Start 打开工具。
- Alt+M 进入悬浮球移动模式。
- 方向键移动，Enter/A 保存，Escape/B 还原。
- 返回优先关闭移动、日志/分享、菜单、工具栏，最后退出页面。
- 菜单和弹层关闭后恢复调用前焦点。

App 根节点的自定义快捷键和 Action 通过内层 `Shortcuts`/`Actions` 叠加，不直接赋给
`MaterialApp.shortcuts/actions`，因此不会替换 Flutter 默认的 Tab、方向键、
Enter/Space 焦点遍历与激活契约。首页资料卡是首页初次打开时的稳定初始焦点；
Windows、Linux、Android TV 和外接键盘共用同一套导航规则，方向移动后由
`PlaymeshFocusPolicy` 自动保持目标可见。

Android Manifest 声明 Leanback launcher 和触摸屏非必需，TV banner 位于
`android/app/src/main/res/drawable-nodpi/playmesh_tv_banner.png`。手机、平板、
电脑和 TV 共用业务逻辑，只按可用尺寸调整布局密度与滚动。

TV banner 由仓库本轮 ImageGen 资产流程生成，保留的复现提示为：
“Android TV banner, deep ink, cyan/amber cartridge shelf, exact Playmesh,
16:9, no extra text”。当前 PNG 为 `1672 × 941`、`907264` bytes，SHA-256
`cdf07ae03ef4ef455cfc74f3e7359f343541fce9f164fd58154881460d2cb660`；Android
清单只引用该仓库内资源，不依赖运行时网络图片。

## 10. 开发和验证入口

正式命令必须使用仓库固定工具链，在获得沙箱外权限后串行执行。最低顺序：

```text
格式化本次 Dart/Go 文件
定向 Flutter/Go/Node 测试
各组件全量测试
SDK/声明/提示词/本地化契约
Flutter analyze + 全量 test
浏览器键盘/无障碍/视口/主题/语言回归
独立授权后的 Android、Windows 发行构建
产物版本、Asset 与 SHA-256 复核
```

真实命令、开始/结束时间、退出码、生成物和未执行项记录在
`docs/verification/playmesh-3.0.0-2026-07-26.md`。未获得权限或未实际执行的项目
必须标为“未执行”，不能用静态检查或历史日志替代。

本轮最终验收已完成：Flutter 全量 `270/270`，Flutter analyze、三套 Go
`test/race/vet`、全部 Node/SDK/本地化契约、公开门户与管理入口浏览器联调均通过。
Android 与 Windows 统一发布构建成功，两份产物都通过 13 项发布 Asset 校验；实际
命令、内部签名边界、产物大小和 SHA-256 见上述验证记录。

## 11. 维护检查表

变更 Catalog、SDK、Developer API、Core 或 Relay 时：

1. 先判断语义版本影响。
2. 修改唯一手写源，禁止直接维护 SDK 生成物。
3. 同步 Schema、声明、提示词、补全、领域文档和版本日志。
4. 新 UI 文案同时补齐所有启用语言，保持 key 集一致；App 内任何可见文案只编辑
   `app.json`，工作区和平台注入 Web UI 不增加独立字典或硬编码 fallback。
5. 新平台 UI 提供可见、可聚焦的键盘/遥控器路径。
6. 不把读取 Token、上传密钥、Session、管理员路径或头像本机路径写入日志。
7. 增加成功、失败、权限/状态边界和并发/资源用例。
8. 更新本实现说明及真实验证记录。
