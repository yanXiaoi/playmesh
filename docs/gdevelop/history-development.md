# GDevelop 本地多文件源码与历史 v3

## 不可违反的边界

GDevelop 当前工程源码与版本历史是两套独立数据：

- `source/current` 是唯一可打开、可保存的当前工程事实源；
- `history` 只保存用户可见的历史版本，并用独立 CAS 对历史内容去重；
- 删除或损坏 `history` 不能让“打开本地工程”按钮失效；
- `hasCurrent` 只能由 `source/current/manifest.json` 和 `project/` 工程树得出，不能由
  history head、history CAS 或浏览器缓存推断；
- WebIDE 只编辑内存中的官方 `gdProject`。手动保存和开启开关后的每分钟/预览前自动保存写入
  current/history；AI 本身不写 current/history，不创建写前快照，也不回滚工程。

v3 不读取、迁移或修复旧单文件 current、旧 history payload 或旧恢复事务。

## 物理结构

```text
playmesh-library/GDevelop/packages/{gameId}/
  .playmesh/project.json
  .playmesh/gdevelop/
    source/
      current/
        manifest.json
        project/
          game.json
          layouts/*.json
          externalLayouts/*.json
          externalEvents/*.json
          eventsFunctionsExtensions/*.json
        resources/
          {sha256}.blob        # current 自己的内容寻址资源
      uploads/                 # 未提交资源的临时 CAS，不是 current/history
        state.json
        cas/
    history/
      state.json
      cas/
      staging/
    restore-transactions-v3/
```

`source/current/project` 固定使用 GDevelop 官方文件夹工程布局：`game.json` 保存根对象和
`__REFERENCE_TO_SPLIT_OBJECT` 引用，四个官方目录保存实际分片。每个 JSON 都使用官方的两空格
缩进和末尾换行。资源使用 `resources/{sha256}.blob` 内容寻址。
这里使用 CAS 是为了资源去重与完整性校验，不代表 current 依赖 history head。每次 current 更新在
同卷 sibling 目录完成，验证后通过 `current -> backup`、`next -> current` 原子替换；异常启动
只恢复这一组交换文件。

`source/uploads` 是提交前的临时 CAS，不是工程事实源。成功 current 提交会把所需资源复制到
current 自己的资源 CAS；清空 history 只删除 `history/cas`，不得清理 `source/current`。
`history/cas` 由历史版本独立 pin/GC，不能反向决定工程是否可打开。

## 官方实现映射与接线点

这里的“官方兼容”特指 GDevelop 5.6.276 桌面端 `LocalFileStorageProvider` 的
folder-project 协议。官方浏览器 `DownloadFileStorageProvider` 仍导出单个 `game.json`；Playmesh
下载的是一个采用桌面 folder-project 布局的 ZIP，解压后可由官方桌面版直接打开，不宣称与官方
浏览器下载产物的文件数或字节布局相同。

| 改动点 | 官方底层/规则 | Playmesh 架构实现 | 主要接线点 |
| --- | --- | --- | --- |
| 工程拆分 | `Utils/ObjectSplitter.split`；`splitPaths` 只匹配 `/layouts/*`、`/externalLayouts/*`、`/externalEvents/*`、`/eventsFunctionsExtensions/*`；名称由 `getSlugifiedUniqueNameFromProperty('name')` 生成 | WebIDE 直接复用这三个官方函数，根文件固定为 `game.json`，分片引用保持 `__REFERENCE_TO_SPLIT_OBJECT/referenceTo` 原样 | `PlaymeshProjectFiles.splitPlaymeshProject` -> 保存、示例导入、源码导出 |
| 工程重组 | `Utils/ObjectSplitter.unsplit`，官方 opener 使用 `maxUnsplitDepth: 3` | WebIDE 直接复用官方 `unsplit`；App 中需要读取/diff 时使用同算法的 Dart 翻译 | WebIDE 打开、portable import、history restore；App history diff |
| JSON 字节格式 | `JSON.stringify(value, null, 2)` + `addFinalNewline` | 每个 `game.json`/分片均以两空格缩进和一个末尾换行写入 | ZIP text files、`source/current/project/*`、history CAS project objects |
| WebIDE 保存 | 官方 `LocalProjectWriter` 依据 `project.isFolderProject()` 决定拆分 | Playmesh provider 是唯一多文件模式；快照前调用 `setFolderProject(true)`，会话镜像保存 `projectFiles[{path,content}]`，不保留 `projectJson` | `PlaymeshProjectSerializer`、`PlaymeshProjectStore`、provider `index.js` |
| 属性面板 | 官方提供 Single/Multiple 两种选择，并注明只对桌面文件系统生效 | Playmesh 薄接线把该字段固定为 Multiple files，避免显示一个保存时会被覆盖的假选项 | `apply-source-policy.mjs` 对 `ProjectPropertiesDialog.js` 的精确前像替换 |
| App current | 官方目录工程以主文件与相邻四目录为一个项目 | direct current 原子目录改为 `current/project/game.json` 与四类分片路径；manifest v3 记录逐文件引用 | `GDevelopProjectHistoryAdapter`、`_GDevelopDirectCurrentStore` |
| History | 官方不提供 Playmesh 本地历史 CAS | 每个工程 JSON 分别进入既有 CAS，revision payload 保存 `projectFilesHash/projectFilesSize/projectFiles[]`；整棵工程树仍是一次原子 revision；手动保存和有新修改时的自动保存均创建用户可见 revision | history save/current/diff/restore，capability `gdevelop.history.v3` |
| Allocation | 官方没有 Playmesh allocation 协议 | 上传内容从一个 project JSON 改为 `projectFiles` DTO；workspace 解析 `game.json` 获取身份与资源引用，并把逐文件对象接入 current/history | `/workspace/project-files`、allocation coordinator/client/operation |
| Restore / rekey | 官方 opener 只负责按引用加载；不处理 Playmesh 事务 | restore 传输完整 `projectFiles`；rekey 只修改根 `game.json.properties.packageName`，随后更新 v3 current/history 事务证据 | restore protocol/client/materializer/transaction；rekey coordinator/journal/operation |
| 源码导入 | 官方 opener 从根引用按需读取分片；单文件工程可直接反序列化 | 接受 folder-project ZIP、仅含 `game.json` 的 ZIP，以及官方浏览器下载的裸 `game.json`。ZIP 分片先按官方引用串行读入再 `unsplit`；单文件直接反序列化。所有输入在身份/资源处理后都经统一 `createProjectSnapshot` 调用官方 `split`，因此 allocation 之后只存在多文件树 | `PlaymeshPortableProjectImporter`、`PlaymeshRawProjectJsonReader`、`PlaymeshPortableProjectFormat`、`PlaymeshProjectSerializer` |
| 示例导入 | 官方示例正文是完整工程 JSON | 示例完成身份和资源 URL 改写后调用同一官方 `split`，不建立示例专用单文件存储；最终也只向 allocation 上传 `projectFiles` | `PlaymeshExampleImporter`、`PlaymeshProjectAllocationCoordinator` |
| 源码导出 | 官方桌面 writer 写分片后写根文件 | 克隆项目、下载本地资源、强制 folder-project、复用官方 split，再把工程文件和资源放入 ZIP；不加入 Playmesh 私有 manifest | `PlaymeshDownloadProjectArchive`、官方 Download dialog 薄接线 |

分片格式的接受与重组不增加 Playmesh 自定义的路径白名单、孤儿分片、重复引用、大小写冲突或
引用闭包检查，只执行官方 `ObjectSplitter` 的判断和深度规则。表中 hash/CAS 字段是既有 App
事务与内容寻址存储证据的多文件迁移，不作为额外的 GDevelop folder-project 格式门禁。

## 身份与项目列表

`gameId` 等于 GDevelop `properties.packageName` 和发布包 `main.json.id`。项目列表先枚举
App 托管项目根，再只读 direct current evidence。合法项目但 current 损坏时，项目仍出现在
列表中，`currentEvidence` 为 `null` 并返回稳定诊断；历史损坏不影响 current evidence。

项目 rekey 必须同时重写：

- `.playmesh/project.json` 的 `gameId/previousGameIds`；
- `main.json.id`（若存在）；
- project config 的 `gameId/revision`；
- `source/current/manifest.json` 的 `gameId`、配置快照与内容证据。
- `source/current/project/game.json` 的 `properties.packageName`。

不重写旧历史 blob。目标项目通过新 direct current 身份打开，历史版本仍是只读版本数据。

## current 与历史写入

保存请求先校验 `baseRevision`，然后提交 direct current：

1. 接收 WebIDE 按官方 `ObjectSplitter.split` 生成的 `projectFiles`，并校验原有资源字节与配置快照；
2. 写入并完整验证 `source/current.next-*`；
3. 原子替换 `source/current`；
4. 对显式保存、自动保存或重要变化，再把已提交 current 复制进 history CAS 并追加版本。

第 4 步失败不能回滚或隐藏已经成功的 current。响应以 `historyCreated=false` 明确表示“源码已
保存，但本次历史版本未创建”。显式保存、自动保存与重要变化分别使用 `explicit_save`、
`autosave`、`important_change`。

同一个 `autosaveOnPreview` 开关继续作为自动保存总开关。开启后，PlaymeshLocal 在工程存在新修改
时每 60 秒尝试一次自动保存，并在预览前走同一个入口。两种触发共享单一 in-flight 与成功
generation 游标：无新修改不重复写；手动保存 busy、项目 mutation busy、历史未创建或瞬时写入
失败都不前移游标并可在下一周期重试。`gdevelop_revision_conflict` 会阻断周期和预览对同一
generation 自动 rebase/重放，直到出现更高 generation 的本地修改；手动保存仍由用户显式决定。
写入期间到达的新修改由下一轮保存。自动保存不调用 `sealUnsavedChanges`，因此不会清除官方手动
保存的 dirty 状态。

历史恢复把目标历史版本写成新的 direct current，current revision 只增加一次。恢复事务协议和
持久日志均为 v3；旧 restore journal 不读取。恢复完成后 WebIDE 下载分片和资源，按官方
`ObjectSplitter.unsplit` 重组并替换内存
工程，普通保存仍由用户决定。

## API

基础路径仍为 `/dev/api/gdevelop/projects/{gameId}/history`，这是 HTTP 功能分组名，不代表
current 的物理存储位于 history。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `GET` | `/dev/api/gdevelop/projects` | 托管项目 identity 与 direct current evidence |
| `GET` | `/history` | `gdevelop.history.v3` 能力、历史 retention 与版本列表 |
| `GET` | `/history/current` | 读取 direct current |
| `PUT` | `/history/current` | 只更新 direct current，不创建历史版本 |
| `POST` | `/history/resources/presence` | 查询 current 提交还缺哪些临时资源 |
| `PUT` | `/history/resources/{sha256}` | 流式接收提交前资源 |
| `POST` | `/history/snapshots` | 更新 current，并尝试追加一个历史版本 |
| `GET` | `/history/diff?fromRevision=&toRevision=` | 比较两个历史版本 |
| `GET` | `/history/revisions/{revision}/resources/{sha256}` | 读取指定历史版本资源 |
| `DELETE` | `/history` | 只删除历史版本/CAS；必须保留 direct current |
| `POST` | `/history/restore-transactions` | 准备 v3 历史恢复事务 |
| `DELETE` | `/dev/api/gdevelop/projects/{gameId}` | 删除完整项目根，包括 current/history/config |

`DELETE /history` 成功后必须满足：历史列表为空、current GET 仍成功、项目列表
`currentEvidence` 仍非空、工程仍可打开。

## 大小与保留策略

本地工程由用户决定实际大小，但实现保留一个明确的安全上限，避免单次请求或对象耗尽进程地址
空间：

- GDevelop `projectFiles` 工程树总量：最大 1 GiB；
- WebIDE 历史恢复 JSON 响应：最大 1 GiB；
- 单个本地资源对象：最大 1 GiB；
- 默认每项目历史版本：100；
- 默认每项目历史唯一数据：16 GiB；
- 单次资源 presence：最多 2048 项。

projectFiles 不包含图片、音频、模型等资源字节，因此“工程树 1 GiB”和“单资源 1 GiB”是
不同边界。current 没有历史总配额；历史空间不足时只令 `historyCreated=false`，不能破坏 current。

## 清理与故障处理

- 只清历史：删除该项目 `.playmesh/gdevelop/history/`，或调用 `DELETE /history`；
- 删除完整工程：调用项目 DELETE；不要把“清历史”实现成删除整个项目根；
- 不要手工删除 `source/current`，否则项目按无当前源码处理；
- 不要把旧 history head 复制成 v3 current；旧单文件格式与 v3 不兼容；
- 不要让 history GC、配额或解析错误影响 project list 的 `hasCurrent`；
- 不要在 App 启动时静默删除旧数据。需要清理时由用户关闭 WebIDE/App 后手工执行。

## 必测合同

每次修改存储或历史必须至少覆盖：

1. 新项目首次提交生成 `source/current revision 1`；
2. current 资源使用自己的 `{sha256}.blob`，并且不依赖 `history/cas`；
3. 清空 history 后 current 工程、资源、项目列表和打开能力保持；
4. current 保存成功而 history 配额失败时，current 保持新内容；
5. 恢复只让 current revision `N -> N+1`；
6. rekey 后 direct current/config/metadata 全部使用新 gameId；
7. old `gdevelop.history.v2`、单文件 current 和旧 restore journal 不被新实现读取；
8. 导出的 `game.json` 与四个分片目录可由官方桌面 GDevelop 直接打开并继续按多文件保存。
9. 官方裸 `game.json`、单文件 ZIP、folder-project ZIP 与官方示例导入后都只生成多文件 current/history。
