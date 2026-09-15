# Playmesh 下一版本临时更新日志

## 状态

- 发布基线：App `5.1.1+38`，Git 标签 `v5.1.1-build38`。该版本已在 GitHub 与 Gitee
  作为 Pre-release 公开，Android universal、Windows x64 portable 与校验文件均已提供；
  最新稳定正式发行仍为 `4.5.0+33`。
- 5.1.1 组件基线：Runtime `2.1.1+13`、Go Core `0.7.1`、Core 协议 `1.6.0`、Game SDK
  `4.3.0`、App Bridge SDK `3.5.0`、Catalog API `3.0.0`、Relay 协议 `4.0.0`、GDevelop
  Playmesh 扩展 `2.1.0`、Developer API / OpenAPI `5.0.0`、Developer CLI `2.0.0`。
- 5.1 build 37 后的变更已进入 5.1.1 发布；版本、制品、哈希、验证事实与已知限制见
  `docs/version/5.1.1.md`。本文件保留该次变更明细，后续新增内容才属于下一版本。

## 5.1.1 发布归档变更

### WebView File System Access 桥

- Windows 与 Android 的 App WebView、独立 Runtime 现在覆盖 WebView 中“已暴露但调用被
  平台拒绝”的 `showOpenFilePicker()`、`showSaveFilePicker()`、
  `showDirectoryPicker()`，统一转交原生系统选择器。普通浏览器保留浏览器自身实现。
- 返回句柄支持 `getFile()`、`createWritable()`、`write/seek/truncate/close/abort`、目录
  枚举、子条目创建/查询/删除、`resolve()` 与 `isSameEntry()`。文件内容按 512 KiB 分块
  经过 App Bridge，原生路径和 Android `content://` URI 不进入网页。
- 三种选择器都消费一次短期可信用户操作；取消映射为 `AbortError`，页面导航或退出撤销
  全部句柄并丢弃未提交的临时写入。Android 插件直接使用 Storage Access Framework，补齐
  `file_selector_android` 没有提供的 `ACTION_CREATE_DOCUMENT` 保存链路。
- 这是主 App、Runtime 与 App Bridge SDK 的兼容性修复；下一版本发布前必须完成 Windows
  与 Android 实机对话框、覆盖写、目录树、取消和导航中断验收，并重新构建两端制品。

### 持久玩家 ID

- App 与独立 Runtime 在首次本地资料创建时同时生成随机昵称和 `u_` 前缀
  UUID v4，并在当前安装且应用数据未清除期间复用。已持久化的旧格式 ID
  保持不变；换设备、重装或清理数据后允许换号。
- 主 App 和 Runtime 创建会话时把该 ID 传入 Go Core，因此普通多屏主机的
  `player.id` 与 `authorityClientId` 不再每局重新生成。浏览器仍在首次加入时
  生成 `p_...` 并写入现有 `playmesh.player-id.v1`，只在同一 origin 且
  `localStorage` 未清除期间稳定。稳定 ID 不是鉴权凭证，Core 仍校验短期会话凭证。
- 会话创建请求增加可选 `playerId`，保留旧客户端的局内随机 ID 回退；版本评估已落实为
  App `5.1.1+38`、Runtime `2.1.1+13`、Go Core `0.7.1` 和 Core 协议 `1.6.0`。
  Game SDK 只是收紧已有 `player.id` 语义，没有新增公开方法，版本保持 `4.3.0`。

### 主会话消息容量

- Go Core 主 Session WebSocket 的单条消息上限从 64 KiB 提升到 1 MiB，允许 Authority
  状态同步发送较大的完整 JSON 快照；普通会话 HTTP JSON 请求体上限同步提升到 1 MiB。
  WebSocket 超限消息会被流式丢弃并记录会话、玩家、消息类型、实际字节数和上限，只拒绝
  该条消息，主会话保持连接，因此不会触发会话重连和 WebView 重建。
- 每连接每秒消息条数、Binary WebSocket 和 RPC payload 的既有边界不变；Go Core 补丁版本
  已升级到 `0.7.1`。接近上限的状态快照仍需在主机与加入端实机发布验收中验证。

### Authority 入口隔离

- 主 App 分享网关与 Runtime 资源网关从 `main.json.authority.entry` 取得权威 JavaScript
  的精确路径。非 Authority 加入端请求该路径时返回 HTTP 成功、JavaScript 类型的空正文，
  不下载或执行权威逻辑，也不以资源错误中断玩家页面；Authority 主机本地仍读取真实脚本，
  其他 JavaScript 资源保持原样。
- 源码 Chat/Agent 与 GDevelop Chat/Agent 的中英文最终提示词在可自定义模板之外强制注入
  同一隔离规则。多人示例与默认脚手架先判断 `isAuthority()`，再动态导入权威入口，避免
  非 Authority 页面依赖该模块的导出或副作用。
- 这项变化修改了主 App 与 Runtime 的实际资源服务行为。5.1 固定 APK/ZIP 没有包含该实现；
  发布下一版本时必须重新构建受影响的主 App 与 Runtime 制品，并同步提示词清单与验证记录。

### 完整 Authority RTT 链路

- Go Core 删除 Authority 主机 `session.ping` 的服务端直接 `session.pong` 快捷路径。主机和
  加入玩家的探针现在都按固定 Authority 角色路由到 Authority SDK，再按发送玩家 ID 路由
  原始回应；主机自回环只是普通路由命中同一连接。
- Core 不再改写探针、生成可用性结果或写入接收/发送时间戳，也不保存或计算 RTT。App SDK
  只以实际收到的 Authority 回应计算和平滑本地 RTT，并在连续无回应后让旧样本过期。
- 已补充 Core 主机完整自回环、原始载荷保持、普通玩家定向回应和高频消息无额外限流测试，
  同步更新 SDK 传输测试、机器 Schema 与开发文档。版本评估结论为 Go Core `0.7.1`、
  Core 协议 `1.6.0`；Game SDK `4.3.0` 与 App Bridge SDK `3.5.0` 保持不变。

### 流式上传分块

- Game SDK 的 RPC 流和 `StorageBucket.upload()` 共用的私有 `chunked-v1` 固定分块从
  64 KiB 增大到 1 MiB，减少大文件上传的 HTTP 往返和请求数。普通 RPC 的
  `4 MiB - 64 KiB` 编码上限、32 KiB pipe 背压缓冲和 512 MiB 单流上限不变。
- 主 App Bucket 网关、独立 Runtime 网关和 Go Core RPC 流端点同步返回并校验
  1 MiB，仍保证单分块在途和顺序背压。单上传的在途 HTTP 分块内存上界因此增大
  16 倍，发布前需执行 Android、Windows 和普通浏览器大文件实机验收。
- 这项内部传输性能调整不增加 GDevelop 公开方法，扩展仍通过同一 Game SDK 进入上传链路。
  版本评估结论同上；Runtime 三端制品与主 App Android/Windows 正式制品均已重建。

### 游戏包更新事务与本地历史边界

- 同 ID 游戏包更新只移动和替换包拥有的 `app/`、`main.json`、可选
  `capabilities.json` 与可选 `icon.png`。`data/`、`cache/`、`.playmesh/` 及其他非包根条目
  留在原路径，`packages/{gameId}/` 根目录在事务期间不再被整体改名或短暂移除，避免大存储
  项目产生临时双倍占用，也避免并发存储刷新重建同名空目录。
- 更新事务持久化 `prepared` 与 `committed` 阶段，并校验目标包条目和清单后决定提交、回滚
  或清理。恢复旧版 `.playmesh-backup-*` 时备份优先；如果目标路径已被并发重建，先整体移动
  到隐藏冲突保留目录，再恢复备份，不自动删除任何可能含用户数据的目录。
- Developer Gateway 导入、Catalog 在线升级和其他标准安装入口复用同一事务。本地历史只
  快照上述包拥有条目；整项目恢复不再删除、复制或重建数据、缓存及其他非包根条目。
- 已为事务提交、异常恢复、旧备份兼容、Catalog 升级、历史快照和数据目录并发场景补充
  回归用例。当前基线整理没有把这些用例记作 5.1 验证结果；下一版本发布前需单独执行并记录。

### 源码项目校验边界

- Developer 项目校验不再根据 HTML/CSS/JavaScript 中的引用文本判定本地资源是否存在，
  避免动态 `import()`、模板路径和构建器生成资源被静态正则误拒。资源加载失败改由真实
  运行时请求反馈。
- 发布源上传本来就不调用项目语义校验；这次变更收窄项目校验器自身的诊断边界。包路径、
  保留命名空间、UTF-8、清单语义以及清单明确入口存在性校验保持不变。

## 5.1.1 发布结果

- 已完成版本评估：App、Runtime 与 Go Core 递增 PATCH 和 Flutter 构建号；会话创建新增
  可选 `playerId`，Core 协议递增 MINOR；Game SDK、App Bridge SDK、Developer API、
  Catalog 和 Relay 不升级。
- 主 App 正式构建已替换 `resources/app/playmesh.apk`、`resources/app/playmesh.zip` 和
  `resources/app/update.json`，固定镜像与版本化附件逐字节一致。
- 已完成 Flutter、Runtime、Go Core、SDK/提示词回归，以及 Runtime 三端正式底包和 WebIDE
  开发打包、主 App 正式构建与发布门禁；Android、Windows、跨设备和公网 TURN 手工验收
  仍未完成，因此本版以 Pre-release 发布。
