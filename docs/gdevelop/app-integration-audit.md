# GDevelop App 整合验收矩阵

本表记录 4.2.0 开发阶段的实现边界、自动化证据和仍需实机确认的事项。GDevelop WebIDE
上游工作副本和构建产物不属于 App 仓库权威源码；可重放裁剪与 Playmesh overlay 才是。

| 需求 | 权威实现 | 自动化证据 | 实机或待决项 |
| --- | --- | --- | --- |
| 首页新增“制作游戏”，设置页移除开发者模式 | `lib/features/home/home_page.dart`、`lib/features/settings/settings_page.dart`、`lib/features/developer/game_creation_page.dart`、`lib/app.dart` | `game_creation_page_test.dart`、`home_page_test.dart`、`settings_page_test.dart`、`widget_test.dart`，以本轮测试记录为准 | 手机横屏尺寸、软键盘和触控折叠体验需真机确认 |
| 一个开发者开关，共享端口、Token 和 Gateway session | `developer_mode_controller.dart`、`developer_channel.dart` | `developer_controllers_test.dart` 与 analyze，以本轮测试记录为准 | Android 前后台切换和系统杀进程后的 session 恢复需真机确认 |
| 源代码与可视化入口只共享 foundation，不共享编辑器 DTO | `source_development_controller.dart`、`visual_gdevelop_controller.dart`、`developer_workspace_links.dart` | controller 分层测试覆盖独立链接、独立失败和本机打开地址 | 无 |
| GDevelop WebIDE 静态资源走现有 Gateway，不新增服务器 | `developer_web_gateway_io.dart`、`gdevelop_web_ide_source_io.dart` | `developer_web_gateway_test.dart` 覆盖 WebIDE 可用性、链接和静态资源响应 | 首个 query bootstrap 经鉴权设置 HttpOnly Cookie 后立即 303 到 tokenless URL；见下方安全边界 |
| Developer API 统一鉴权 | `operations/middleware/developer_request_middleware.dart` | Gateway 真实 HTTP 测试覆盖未授权、Bearer 和带凭据调用；比较使用 constant-time helper | LAN HTTP 无法使用 Secure Cookie；沿用现有持久 Developer Token，并以 HttpOnly、SameSite=strict Cookie 限制浏览器传输 |
| GDevelop Agent 明确复用持久根 Developer bearer | `operations/gdevelop/gdevelop_ai_operation.dart` 与统一 request middleware | `gdevelop_ai_gateway_test.dart` 覆盖 Chat 不含 Token、Agent prompt 包含现有根 Token，并以同一 Bearer 调用 Gateway | 这是与源码开发区相同的完全信任模型，不是最小权限设计；只能把 Agent prompt 交给完全信任的模型/提供商 |
| `gameId` 直接等于 GDevelop packageName 与 `main.json.id`，不签发 opaque handle | `project_provisioning_service.dart`、`gdevelop_project_root_resolver.dart`、`gdevelop_project_rekey.dart`、`gdevelop_project_rekey_controller.dart` | `project_provisioning_service_test.dart`、`gdevelop_project_rekey_test.dart`、`gdevelop_project_rekey_gateway_test.dart` 覆盖公开 ID、目标冲突、确认、原子提交、失败回滚和恢复 | 无；WebIDE 改 packageName 时以 `oldGameId` 为事务主键走已落地的原子 Rekey |
| App 的 `GDevelop/packages` 是 managed project identity/index/current/history 唯一事实；WebIDE 只保留页面内存副本，IndexedDB 仅允许可丢弃偏好 | `gdevelop_project_allocation.dart`、`gdevelop_project_history.dart`、`project_provisioning_service.dart` | 最终 allocation wire 与 App 聚合 recovery discovery 已接入；`gdevelop_project_allocation_test.dart`、`gdevelop_project_allocation_gateway_test.dart` 覆盖 raw project、chunked 资源、finalize、commit、崩溃恢复、幂等及坏项目隔离 | 无 |
| managed root、SaveAs 共享历史、Copy 新 ID 隔离 | `project_provisioning_service.dart`、`gdevelop_project_history.dart`、`foundation/local_version_store.dart` | `gdevelop_project_history_test.dart`、`gdevelop_history_gateway_test.dart` 覆盖创建/打开/另存为/复制/删除 | 无 |
| 项目级完整历史：project JSON、资源 CAS、revision、restore | `gdevelop_project_history.dart`、`foundation/local_version_store.dart` | 资源暂存、presence 去重、snapshot、diff、restore、冲突、配额、跨项目授权测试需在本轮最终验收重跑 | project JSON、恢复响应和单资源对象各有 1 GiB 安全上限；默认每项目历史唯一数据 16 GiB，current 不受历史配额影响；真实大项目体验仍需验收 |
| 不使用全局历史锁或跨项目淘汰 | `foundation/local_version_store.dart` | `local_version_store_test.dart` 覆盖不同项目并行、单项目冲突、项目隔离配额与删除 | 多 App 进程并写同一项目不支持；当前 Gateway 是单进程模型 |
| 标准 ZIP 发布复用 `/dev/api/packages/import` | `operations/packages/package_import_operation.dart`、`foundation/package_upload_spooler.dart` | `package_import_gateway_test.dart` 同时覆盖 Content-Length 与真实 HTTP/1.1 chunked 请求 | Android WebView streaming request body 尚无真机证据 |
| 上传不聚合完整请求、支持 backpressure/限额/超时/清理 | `package_upload_spooler.dart` 使用逐 chunk `RandomAccessFile.writeFrom` await | `package_upload_spooler_test.dart` 应覆盖声明和实际超限、30 秒 idle 模型、上游取消、空流、partial 清理；结果以本轮记录为准 | 进程被系统强杀时可能遗留系统临时目录，后续可增加启动清扫 |
| 发布更新不破坏 GDevelop sidecar/history | `game_package_transfer_service.dart` 保留 `data/`、`cache/`、`.playmesh/`，同时禁止上传包写 `.playmesh` | `game_package_transfer_service_test.dart`、`package_import_gateway_test.dart` 覆盖正常更新、恶意路径、失败回滚和 history 字节不变 | 无 |
| canonical 最小 Authority Bootstrap，不新增 public Manifest/Core 或 App/Game SDK 业务 | `assets/playmesh-library/public/developer/gdevelop-authority-bootstrap.js` | 私有 coordinator、发现/编号快照、Authority/guest、dispose 和真实 Core E2E 均需在本轮最终验收重跑 | 浏览器 exporter 加载顺序与真实多设备网络仍需实机确认 |
| 一个 Playmesh Session 自动映射为一个 GDevelop lobby；Authority direct start、guest 拒绝、late roster/avatar、零倒计时 | canonical Bootstrap + `assets/playmesh-library/public/developer/gdevelop-multiplayer-bridge.js` | 定向合同必须覆盖单次自动加入、直接开始、后加入稳定编号/头像；官方 `startGameCountdown` 仅无副作用 no-op，并断言零按钮/pending/event/Binary/type 5 | 当前代码与测试仍在最终收敛，不能记录为已通过；高 RTT、丢线和大帧压力需多设备验收 |
| Windows 通用宿主在 navigation completed 前缓存 App/Game 回包 | `lib/features/game/windows_local_game_web_view_io.dart` 与共享 `WebViewMessageQueue` | head 早加载、传统 body 末尾、双 Bridge、reload 清旧消息和恰好一次 ready 的宿主回归待本轮最终重跑 | 这是非 GDevelop 页面也可复现的共享宿主时序修复，不修改 SDK API、协议或版本 |
| 官方 HTML exporter 生成文件，主 HTML 唯一加载 Bootstrap | `PlaymeshPublishController` overlay、canonical 派生模块 | publish/Manifest/bridge Node tests 待最终重跑 | WebIDE 完整 production build 后需在浏览器确认实际加载顺序 |
| 流式 ZIP 优先，BlobWriter 明示风险后回退 | `PlaymeshPackageUploader`、`PlaymeshPublishDialog` overlay | Gateway chunked 与 WebIDE uploader mock/Node 测试结果以本轮验收记录为准 | 桌面浏览器/Android 真机 probe 必须单独记录；没有本轮设备证据时不得宣称通过 |
| 升级时自动重放裁剪、overlay 和 canonical 源 | `scripts/apply-source-policy.mjs`、`verify-layout.mjs`、`prepare-webide.mjs`、`webide-lock.json`、`source-policy-output-manifest.json` | 官方被改文件使用 Git Blob SHA 和唯一源片段锁；实际 patch 全集、overlay 双向文件集和补丁后 SHA-256 由 verifier 核对；相关 verifier 待本轮最终 clean replay 重跑 | 当前 manifest 的 overlay tree 仍为小写 `pending`，只可收集候选，不能作为 release evidence；最终必须从干净树冻结并严格重放 |

## GDevelop Multiplayer 自动化边界

`tool/test_gdevelop_multiplayer_e2e.mjs` 应在系统临时目录编译 go-core、直接启动独立 Core 进程
并读取其动态回环监听地址。每个 Authority/Guest 页面上下文加载仓库中实际生成的 Game SDK、
canonical bridge 和 Bootstrap，通过真实 HTTP、Session WebSocket 与 Binary WebSocket 完成会话；
测试不能依赖 WebIDE overlay，也不能以 mock Core 代替网络链路。本轮最终代码冻结后必须重跑，
当前正文不把旧测试结果当成新实现证据。

最终自动化必须覆盖 Authority 固定为编号 1、Guest 获得稳定编号、同一 Playmesh Session 只
自动加入同一虚拟 lobby 一次，以及 reset 后编号和原 Binary Channel 保持不变。编号映射由
版本化私有 Authority 服务分发；Peer 连接控制和数据帧复用既有 GDevelop Binary Channel，不能
借用 `main.storage` 伪造会话状态，也不能占用 `main.sync`。

Authority 加入后可直接 Start，guest Start 必须失败；后加入玩家的 roster、稳定编号、昵称和
头像必须在同 Session 更新后刷新。官方 `startGameCountdown` 只保留为无副作用 no-op，自动化
必须证明没有倒计时按钮、pending operation、`gameCountdownStarted`、Binary packet 或旧 type 5
接受路径。

Game SDK/go-core 的入站上下文会把真实 Authority playerId 映射为公共 sender alias
`"authority"`。单元总线会明确记录“实际来源为 host playerId、送达 sender 为 alias”，并验证
bridge 先把 alias 解析回 `session.authorityClientId` 完成拓扑校验，再保持 GDevelop 官方连接侧
看到的 `"authority"` 语义。跨 VM realm 的严格 DTO 问题只在 E2E fixture 内通过目标 realm
`JSON.parse` 修正，生产 bridge 的 plain-object 校验没有放宽。

GDevelop 逻辑连接 close/leave 是软离开：本地连接结束，但 Playmesh Session、主 WebSocket 和
Binary Channel 保留，warm re-entry 不新建传输。Binary WebSocket 瞬断后应由 SDK 重新 JOIN 原
Channel；reset 不替换 Channel，显式 Authority finish 才结束会话。当前 Authority 固定，不实现
选举或迁移；这些路径及真实浏览器 exporter、多设备、高 RTT、丢包和压力表现仍待本轮自动化/
实机验收，不得沿用旧结果宣称通过。

回归命令：

```powershell
cd go-core
go test ./...
cd ..
node assets\playmesh-library\public\GDevelop\playmesh\tests\test-multiplayer-bridge.mjs
node tool\test_gdevelop_authority_bootstrap.mjs
node tool\test_game_sdk.mjs
node tool\test_game_sdk_browser.mjs
node tool\test_gdevelop_multiplayer_e2e.mjs
node tool\test_gdevelop_multiplayer_e2e_cleanup.mjs
```

最后一项会在 Core 启动后注入预期失败，并断言子进程 PID 已退出、动态端口可重新绑定且临时
构建目录已删除。

## Token 安全边界

首个源码/GDevelop workspace 链接只把 Developer Token 用作一次 bootstrap。Gateway 验证后设置
`HttpOnly`、`SameSite=Strict` Cookie，并立即以 303 重定向到移除 query 的同一路径；所有响应仍
设置 `Referrer-Policy: no-referrer`。Token 的值、生命周期和既有链接/二维码语义保持不变。

重定向前的首个 URL 仍可能短暂显示并进入浏览器导航历史，因此不能宣称 bootstrap Token 从未进入
URL。页面稳定态和后续请求不再从 query 读取它。Agent prompt 有意包含同一个持久根
Developer Token，且该 Token 拥有与源码开发区相同的完整 Gateway 权限；Chat prompt 始终
无 Token，模型只返回 JSON，由用户手工执行。高风险写操作继续进入现有审批交互，但审批是
UX 确认，不是对根 Token 持有者的安全边界。

关闭开发者模式会立即关闭当前 Gateway 监听并清除内存中的 AI session、turn、call 与对话
状态，但不会轮换、缩短或删除已保存的 Developer Token/path；再次开启同一配置后，旧的复制
链接和二维码仍可重新完成 bootstrap。关闭期间既有 Cookie 无监听端点可用。

## 发布失败的重试边界

- 流式能力探测失败或 writer 确认尚未产生任何正文时，可以展示完整内存 ZIP 风险，经用户
  确认后使用官方 BlobWriter。
- 收到上传/校验阶段的明确结构化 `4xx`（例如空包、超限或包格式非法）时，Gateway 尚未
  进入原子安装，partial 临时文件由 server 清理。不能把任意 `5xx` 一概视为“未提交”；
  除非响应契约明确给出 `committed: false`，客户端仍应按状态不确定处理。
- 已经产生正文后若 fetch 只返回网络错误或 Abort，没有响应就无法证明安装是否提交。
  客户端必须停止自动重试并提示先检查本地游戏库；Abort 完成不能当作 server cleanup 证明。
