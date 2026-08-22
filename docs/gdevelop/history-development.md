# GDevelop 本地多文件源码与历史 v3

本文服从 [GDevelop 开发总规范](development-standards.md)。Playmesh 可以拥有物理目录、CAS、
事务、资源下载、身份和历史证据，但不能把这些存储职责扩张成第二套 GDevelop opener、
serializer、split/unsplit 或编辑器生命周期：

- WebIDE 的打开、保存、导入、导出和历史恢复必须把工程交给真实官方函数处理；
- App 中的 Dart 翻译只用于项目列表、证据读取和历史 diff，不得替代 WebIDE 或官方 opener；
- Playmesh 自有归档、路径、资源和身份处理必须在官方处理链之前结束；
- 进入官方打开、反序列化、重组或回调链后，不得追加二次校验、修复、再次导入或 fallback，
  官方错误必须保持可诊断并原样传播。

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

## 官方格式合同

“官方兼容”指锁定上游桌面端 `LocalFileStorageProvider` 的 folder-project 协议。官方浏览器
`DownloadFileStorageProvider` 仍可导出单个 `game.json`；Playmesh 下载的是采用桌面
folder-project 布局的 ZIP，不承诺与浏览器下载产物具有相同文件数或字节布局。

WebIDE 的拆分、重组、名称生成、引用深度和 JSON 格式必须直接使用锁定上游的
`ObjectSplitter`、`JSON.stringify(value, null, 2)` 与末尾换行规则。Playmesh 不增加路径白名单、
孤儿分片、重复引用、大小写冲突或引用闭包门禁。归档、身份和资源处理在官方 opener 之前完成；
进入官方打开、反序列化、`unsplit` 或 callback 后，不再重组、复核、再次导入或 fallback。

当前实现入口仅记录在[源码接线索引](integration-wiring.md)，不属于本合同。

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
10. WebIDE 打开、导入和恢复都调用官方 opener、反序列化、split/unsplit 与原始 callbacks；App
    Dart 翻译没有进入这些编辑器路径。
11. 官方处理开始后不存在 Playmesh 二次导入、后置修复、额外写入或 fallback，官方错误经
    WebIDE、Gateway/App 边界后仍保留原始诊断。
