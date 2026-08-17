# GDevelop 内核升级手册

本文用于把 Playmesh 的裁剪、overlay 和运行时接线从当前锁定的官方 GDevelop WebIDE
重放到新版本。目标不是让新版“勉强能构建”，而是证明官方通用导出保持原样、Playmesh
能力只在规定边界生效，并且失败时可以立即回到旧内核。

构建所用版本、commit 和固定 ZIP 命名只以
`assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json` 为准；用户下载所见的当前
`version/sha256/size/downloads` 只以 `resources/GDevelop/update.json` 为准。本文中的“旧版本”
和“新版本”均指锁文件中的精确 commit，不以浮动分支、GitHub 最新 tag 或本机缓存为准。

同一锁定内核上的普通功能新增或修改，不属于内核升级，应使用
[GDevelop 功能修改与可重放开发手册](feature-development-guide.md)。本手册只处理官方 tag、
commit、libGD 或 GDJS 基线变化。

## 统一入口：一个官方 ZIP、一条流水线

当前手册记录升级流水线的完整内部合同和故障排查步骤。正常升级只填写一个值：官方精确
commit 源码 ZIP 的绝对路径，然后执行现有统一入口：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/webide-pipeline.mjs all --zip <官方精确 commit 源码 ZIP 的绝对路径> --profile default
```

统一脚本自动完成并原子记录以下工作：

1. 从 ZIP 证明并锁定官方版本、完整 commit、来源和 SHA-256；无法证明精确 commit 时
   fail closed，禁止人工猜测或使用浮动版本。
2. 替换固定工作目录中的旧 `newIDE` 源码，同时复用按锁文件及工具链指纹隔离的
   `node_modules` 与 libGD 缓存；输入变化时只失效对应阶段。
3. 重放全部 Playmesh 裁剪、overlay 与底层运行时替换，并执行布局、preimage、输出摘要和
   provenance 校验。
4. 从同一官方精确 commit 自动生成示例项目、扩展列表、扩展搜索元数据和下载锁文件；
   生成结果稳定排序、原子覆盖，自动校验 schema、重复项、缺失文件、大小与 SHA-256，
   禁止人工维护生成文件。
5. 完成生产构建、审计、prepare、ZIP 打包与最终 verify，原子覆盖
   `resources/GDevelop/GDevelop-webide-v{version}.zip`，并在保留 `downloads` 原值的前提下
   更新同目录 `update.json` 的 `version/sha256/size`。
6. 为每个阶段写入包含精确输入、工具版本和输出树摘要的原子 receipt；支持 `status`、
   `dev-package` 以及 `extract/deps/libgd/patch/build/audit/prepare/package/verify` 等独立调试步骤，但
   单独执行步骤不得隐式触发无关的耗时前置阶段。

下方详细章节是脚本实现合同与高级故障排查，不是每次升级需要人工照做的普通操作清单。

## 不可破坏的原则

- 官方 checkout 是一次性输入，不提交到仓库，也不直接维护手工补丁。
- Playmesh 自有代码只维护在 `playmesh/overlays`、`public/developer` 或生成/准备脚本中。
- 所有官方源修改必须由 `apply-source-policy.mjs` 按顺序、带文件路径、Git Blob SHA 和唯一
  源片段断言重放。任何断言失配都应停止升级。
- 升级前必须核对现有合同与 ownership。若目标官方 GDevelop 已提供等价功能或修复同一
  bug，必须撤销 Playmesh 对应补丁，不得在官方实现上继续叠加。按顺序移除
  `apply-source-policy` 变换、overlay 文件或接缝、对应测试的 Playmesh ownership，再以官方
  实现验证真实行为。只有官方实现不完整或违背 Playmesh 必需架构时，才可保留最小
  差异，并记录保留依据、差异边界和后续复核条件。
- `source-policy-output-manifest.json` 必须完整登记实际生成文件与官方补丁文件；overlay
  整树及每个补丁后输出必须冻结 SHA-256，发布门禁中不允许保留 `pending`。
- 先证明未修改的上游能安装、检查和构建，再应用 Playmesh 策略；否则不能区分上游环境
  问题与 Playmesh 兼容问题。
- 每次策略重放都使用新的干净源码树。已经应用过策略的目录不能作为升级验证输入。
- WebIDE 裁剪、Flow、生产构建和打包统一在 Windows 上使用仓库现有流水线与依赖缓存；
  不切换操作系统或另建 profile，不为同一锁文件重复建立另一套 `node_modules` 缓存。
- 日常开发测试使用 `dev-package`：复用解压、依赖、libGD 和生产构建缓存，跳过 Flow 与完整
  合同测试，但仍执行快速 build 审计、prepare 和 schema 3 证明链校验；否则 ZIP 不能通过
  App 的统一原子安装器。除非需求明确写出“正式包”“发布包”或 `release`，任何“打包”“出
  ZIP”“给我测试”都必须解释为 `dev-package`；代理不得自行升级为完整流水线。正式构建才使用
  `all`，并恢复全部质量门禁。
- 固定构建工作区和 Flow 工作区按文件内容增量同步，未变化文件保持原时间；正式全流程在
  依赖阶段完成后并发执行 Flow、合同测试和生产构建，审计/准备/打包/校验仍按顺序执行。
- 通用 GDevelop HTML 导出不得含 Playmesh SDK、Bridge、Bootstrap、Manifest 或 Gateway
  调用。只有预览/Playmesh 发布按运行计划装饰虚拟文件系统。
- 运行计划将运行包是否存在、运行时是否激活和展示形态拆开表达：官方导出固定
  `none/inactive/game/false`；Playmesh 单机预览与发布固定
  `full/inactive/game/false`；在线模式固定 `full/active/game/true`；诊断预览固定
  `full/inactive/diagnostic/false`。最后一位是 `connectCore`，不得再由“文件已携带”推断。
- 升级未完成全部门禁前，不替换 `resources/GDevelop` 中当前可下载 ZIP 与版本清单。

## 1. 建立升级记录

日常修改后最快生成可安装测试包（`<官方ZIP绝对路径>` 只需替换这一项）：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/webide-pipeline.mjs dev-package --zip <官方ZIP绝对路径> --profile default
```

准备正式分发时运行完整门禁并原子覆盖 `resources/GDevelop`：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/webide-pipeline.mjs all --zip <官方ZIP绝对路径> --profile default
```

流水线 profile 固定为稳定的 `default`，所有重复构建都复用
`work/gdevelop-webide-build-cache/profiles/default`。日期只记录在 receipts 的
`completedAt` 字段中，不得用日期新建 profile 目录。

两条命令使用同一 Windows profile、依赖缓存、libGD 缓存和增量构建工作区；不要为测试另建
profile。任一步骤需要定位时才单独执行对应子命令。

流水线取得 profile 锁后会回收上次异常中断遗留的 `.staging-*`、原子替换 `.backup-*` 和
`release-check` 一次性目录；成功、失败和中断的 `finally` 路径都会再次尝试清理。清理失败只
输出 warning，不能掩盖原构建错误或阻止释放 profile 锁。`upstream`、`source`、`build-source`、
`raw-build`、`built-gdjs`、`audited-build`、`prepared`、receipts、logs、共享 `node_modules`、
libGD/GDJS 与工具链均属于增量缓存，不得在常规构建结束时删除。只有显式传入
`--keep-worktree-on-failure` 才保留本轮失败 staging 供诊断；下次不带该选项运行时再回收。

开始前新建一份临时升级记录，至少写明：

| 字段 | 内容 |
| --- | --- |
| 旧 tag / commit | 从旧 `webide-lock.json` 原样抄录 |
| 新 tag / commit | GitHub tag 解析后的完整 40 位 commit |
| 上游仓库 | `https://github.com/4ian/GDevelop.git` |
| 源归档 URL | 固定 tag 或 commit，不使用 `latest` |
| 源归档 SHA-256 | 实际下载文件的 SHA-256 |
| Node / npm / 系统 | 实际成功构建所用 Windows Node/npm 版本与缓存 profile |
| 网络 | 是否使用本机 `127.0.0.1:1080` 代理，以及失败重试记录 |
| Playmesh revision | 新的单调递增 revision，不能覆盖旧 revision |
| 操作者与日期 | 便于后续定位构建环境 |

在更新锁文件前，用 `git ls-remote` 或本地 `git rev-parse` 证明 tag 对应的 commit。下载源
归档后计算 SHA-256；代理只改变下载路径，不改变所接受的 commit 或哈希。

同时保存旧锁文件、旧构建日志、旧 ZIP 的大小与 SHA-256。旧 ZIP 与旧清单必须保留在本次
构建的临时回退位置，直到新版完成本地验收并原子替换成功。

## 2. 准备两个干净上游树

从同一个精确 commit 建立两个互不复用的目录：

- `upstream-untouched`：只验证官方源码和依赖，绝不应用 Playmesh 策略。
- `upstream-playmesh`：只在 untouched 验证通过后，由脚本应用 Playmesh 策略。

两个目录都应满足：

1. `git rev-parse HEAD` 等于升级记录中的完整 commit。
2. `git status --short` 在开始时为空。
3. 没有从旧版本复制的 `node_modules`、build、libGD 或生成资源。
4. 安装前记录锁文件类型和包管理器版本；不在安装失败时随意升级依赖。

在 `upstream-untouched/newIDE/app` 按该版本官方锁文件安装依赖并运行官方检查与
`npm run build`。GDevelop 的 `postinstall/import-resources` 还会构建或下载 GDJS、libGD 和
外部编辑器资源，因此必须检查命令退出码，并确认 `libGD.js`、`libGD.wasm` 等关键文件
存在且非零字节。上游未修改构建失败时先修正环境或精确依赖，不得修改 Playmesh 策略来
掩盖问题。

## 3. 更新构建锁，但暂不覆盖当前本地包

在 `webide-lock.json` 中只更新已经验证的事实：

- `upstream.tag`、`upstream.commit`、`upstream.sourceArchive`；
- 单调递增的 `playmeshRevision`；
- ZIP 固定由上游版本派生命名为 `GDevelop-webide-v{upstreamVersion}.zip`。当前基线必须
  精确使用 `GDevelop-webide-v5.6.276.zip`；不得使用 `pm10`、`pm15`、`unknown-hash` 等
  临时 revision 或未知哈希名称；
- `resources/GDevelop/update.json` 暂时保持上一份已验证内容，不能提前写入新版本、哈希或
  大小。

不要把浮动 URL、目录名或展示版本当作 commit 校验。门禁完成前不要提前覆盖当前本地
ZIP 或 `update.json`。

## 4. 在干净树重放源码策略

从仓库根执行：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/apply-source-policy.mjs --source <upstream-playmesh>
```

脚本失败是升级审计入口，不是应该跳过的障碍。处理每个失败时遵循以下分类：

| 失败类型 | 判断与处理 |
| --- | --- |
| Git Blob SHA 不匹配 | 官方文件发生变化；先比较旧、新上游语义，再更新目标 SHA 和补丁 |
| 唯一源片段缺失 | 官方实现移动或重写；重新寻找等价职责，不能改成模糊替换 |
| 唯一源片段出现多次 | 补丁锚点失去唯一性；缩小到稳定上下文，仍必须精确命中一次 |
| 路径不存在 | 查明官方模块迁移；更新路径、import 和验证脚本，不能复制旧文件强行补位 |
| React 生命周期/Hook 冲突 | 适配新版组件边界，保持官方状态流和清理顺序 |
| Flow/TypeScript/import 冲突 | 使用新版真实类型和导出；不得用 `any`、`FlowFixMe` 或关闭检查绕过 |
| libGD/GDJS 资源失败 | 回到精确上游依赖和非零文件验证；必要时给准备脚本传入同版本已校验资源 |
| 运行时测试失配 | 判断官方语义是否变化，先补契约测试，再调整 Playmesh adapter |

如果为了定位问题在 `upstream-playmesh` 中做过手工试验，确认方案后必须立即将同一改动
写回 overlay 或脚本，丢弃该试验树，并在新的干净树从第一步重放。升级结果中不能存在
“最后再手改一次”的步骤。

`apply-source-policy.mjs` 会把本次实际执行的官方 patch 路径、上游 Git Blob SHA 和补丁后
SHA-256 与 `source-policy-output-manifest.json` 做全集核对。漏登记、多登记或 preimage SHA
不一致都会失败。策略仍在修改时，manifest 摘要可显式写为字符串 `pending`；脚本会在
`PLAYMESH RELEASE BLOCKED` 区块打印应冻结的实际 SHA-256。完成业务输出后，把 overlay
整树摘要、三个 canonical 生成文件和所有官方补丁后摘要写实，再从全新上游树重放一次。

只有为了收集冻结候选值时，才可临时运行：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/verify-layout.mjs --allow-pending-output-manifest
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-source-policy-output.mjs --source <upstream-playmesh> --allow-pending-output-manifest
```

这两个命令会醒目标记“不是 release evidence”。生产构建审计、最终 clean replay 与发布
记录禁止携带该开关；默认门禁只要发现一个 `pending` 就必须失败。

策略成功后运行布局验证：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/verify-layout.mjs
```

随后检查 `git diff`（或归档树差异），确认每个官方文件变化都能对应到策略中的一个具名
步骤，新增文件都来自 canonical 源或 overlay。布局验证会按实际 overlay 树和 output
manifest 派生检查项；源码重放验证还会双向比较 Playmesh-owned 文件集合，旧版残留文件也
必须导致失败。

## 5. 逐项重新审计功能边界

版本升级必须重新走完下列 23 项，不能只凭首页可打开判定成功：

1. App 语言在首次进入前设置 GDevelop 官方语言。
2. GDevelop 会话内临时切换语言时，发布、历史、多人、AI 和项目配置文案同步更新。
3. 创建、打开、复制和重命名使用 `gameId` 身份；项目事实只存入 App 的 GDevelop packages，
   浏览器 IndexedDB 不参与工程持久化。
4. 本地资源选择器可处理图片、音频、字体和 3D 资源，内置对象图标不丢失。
5. 官方扩展/行为与精确 commit 示例目录加载失败时不阻塞编辑主流程。
6. GDevelop Cloud、资产商店、课程、登录、Ask AI、Piskel 等禁用入口没有回流。
7. PropertiesDialog 中 Playmesh 项目配置可读取、保存、冲突提示并刷新 revision。
8. `single/online/legacy/unknown` 运行计划严格遵守 bundlePresence、runtimeActivation、
   presentation 与 connectCore 四维矩阵，且不存在旧 `injection/injectionFileCount` 字段。
9. 预览只装饰预览虚拟文件系统，失败信息可诊断且不污染工程 JSON。
10. 发布只走 HTML 到本地 Playmesh，并从项目设置生成 manifest 预览。
11. 大包优先流式上传；不支持时仅在明确提示后使用全内存回退。
12. 连接中断后的未知提交状态不自动重复发布。
13. 普通官方 HTML 导出为零 Playmesh 注入。
14. 迁移到官方 GDevelop 的工程 JSON 不包含 Playmesh 专属事件或对象。
15. `storagetools.ts` 仍只在官方两个 localStorage seam 惰性切换同步 Bucket；无 Playmesh、
    完整 SDK、残缺 SDK 三态分别保持官方、使用同步存储、明确失败关闭，且没有新 Symbol、
    预载快照或 Bootstrap gate。
16. 官方 Multiplayer 项目 API、事件名、事件数据格式和 message manager 调用形状不变；
    Playmesh 私有兼容层的大厅展示和 backend 映射按下一项单独验收。
17. 一个 Playmesh Session 只映射一个虚拟 lobby；玩家自动加入，Authority direct start，guest
    拒绝开始，后加入玩家编号/昵称/头像刷新。官方 `startGameCountdown` 只保留为无副作用 no-op，
    且不存在倒计时按钮、pending operation、事件、Binary packet 或旧 type 5 接受路径。Binary
    transport、ready/attach 有界协商、软离开、warm re-entry、重连和清理仍符合兼容层合同；本地
    lobby/auth frame 的 nonce、sequence、WindowProxy 与 token 隔离负向测试通过。
18. Windows 通用宿主在 navigation completed 前缓存 App/Game 回包，新导航清除旧 document
    消息；head 早加载与传统 body 末尾加载均恰好完成一次 bootstrap/ready。该修复不改变
    App/Game SDK 业务、API、协议或版本。
19. canonical Bootstrap 可随 Playmesh solo 包存在但保持 inactive；只有在线计划激活并连接
    SDK/Core，官方通用导出不携带该运行包。
20. History 保存不改变普通保存顺序；资源引用被 pin，恢复使用事务与独立 journal。
21. History 恢复的旧态、目标态、第三态冲突均可确定恢复，不产生半写项目目录。
22. AI Chat/Agent 只在活动 `gdProject` 上调用官方 EditorFunctions/EventPayload，修改后触发
    官方 dirty/刷新回调；AI 不保存工程、不写 History/current/revision、不生成提交证据，也不
    替用户撤销或恢复。
23. 所有 Gateway、目录、示例和网络软依赖失败时，用户仍可本地创建、打开、编辑和保存。

任何一项的官方调用点发生变化，都应把新的路径、类型或事件合同补进自动测试和对应文档。

## 6. 自动验证门禁

在新的干净策略树中至少完成：

- `npm run flow -- --show-all-errors`，错误数必须为 0；
- `npm test` 的相关官方测试（使用非交互/单次运行参数）；
- `npm run build` 的生产构建；
- 构建产物中关键 JS、CSS、WASM、图标和 runtime 文件非零且可引用。

在 Playmesh 仓库中运行全部
`assets/playmesh-library/public/GDevelop/playmesh/tests/test-*.mjs`，并运行根目录 `tool/` 中
的 GDevelop Authority、Multiplayer、SDK 和生产构建专项测试。至少单独确认：

```text
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-release-verifiers.mjs
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-source-policy-clean-replay.mjs --zip <exact-official-source.zip>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-source-policy-output.mjs --source <upstream-playmesh>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-multiplayer-runtime-seams.mjs --source <upstream-playmesh>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-zero-cloud-resource-source.mjs --source <upstream-playmesh>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-official-runtime-ui-contracts.mjs --source <upstream-playmesh>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-gdevelop-storage-runtime.mjs --source <upstream-playmesh>
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-runtime-injection-boundary.mjs
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-production-build-audit.mjs --build <newIDE/app/build> --lock assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json --source <patched-root> --source-archive <exact-official-source.zip> --source-policy-manifest assets/playmesh-library/public/GDevelop/playmesh/source-policy-output-manifest.json --overlay assets/playmesh-library/public/GDevelop/playmesh/overlays --libgd-kind official-exact-commit-artifact --libgd-source <exact-official-commit-artifact-base-url> --libgd-upstream-version <version> --libgd-js-sha256 <sha256> --libgd-js-size <bytes> --libgd-wasm-sha256 <sha256> --libgd-wasm-size <bytes> --libgd-user-decision not-required --expect-ai session-bootstrap
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-ai-client.mjs
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-history-client.mjs
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-project-config.mjs
node tool/test_gdevelop_authority_bootstrap.mjs
node tool/test_gdevelop_multiplayer_e2e.mjs
```

再运行受影响的 Go、Flutter 和 SDK 门禁：`go test ./...`、`flutter analyze`、相关
`flutter test`、SDK 生成/声明测试。某项因环境不能执行时必须在升级记录中写明具体原因，
不能写成“应当没问题”。

最后从另一个全新 checkout 再做一次“应用策略 → Flow → 生产构建 → 包准备 → 自动测试”。
只有第二次无人工修补的 clean replay 才证明升级步骤可维护。

## 7. 准备分发包

生产构建通过后，用锁定版本的 GDJS Runtime 准备独立输出目录：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/prepare-webide.mjs --input <audited-newIDE/app/build> --gdjs <verified GDJS runtime> --source <patched-source> --output <prepared-output> --lock assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json --source-policy-manifest assets/playmesh-library/public/GDevelop/playmesh/source-policy-output-manifest.json
```

开发期需要直接运行源码或静态 build 时，可使用：

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/prepare-dev-webide.mjs --source <patched-root> --libgd <verified libGD directory> --build <static-build>
```

`--libgd` 必须来自同一锁定 GDevelop 版本并已验证大小/哈希，不能拿旧版 WASM 填补下载
失败。生产审计只接受 `webide-lock.json` 固定 SHA-256 的官方源码归档及其直接解压、应用
策略后的源码树；所有源码、AI 状态和 build 内容通过后，才原子写入
`playmesh-build-provenance.json`。`prepare-webide.mjs` 必须先验证该 build 证明，在同目录
staging 中完成裁剪和注入，再生成 schema 3 的 `playmesh-integration.json`。两份记录共同绑定
`playmeshRevision`、上游 tag/commit、官方源码归档、冻结 source-policy 清单、overlay、生成/
修改文件集合、原始 build 树与 prepared 树 SHA-256。打包脚本会在压缩前和最终 ZIP 内重算
prepared 树并校验完整证明链；旧 schema 2、旧 prepared、任意文件篡改或摘要不符都必须在
改写当前 ZIP/`update.json` 之前失败。包准备后使用唯一发布打包脚本：

正常升级必须使用与锁定 tag commit 一致的 GDevelop 官方 libGD 产物，来源类型为
`official-exact-commit-artifact`。`source` 必须是
`https://s3.amazonaws.com/gdevelop-gdevelop.js/master/commit/<40位commit>` 这种精确提交
URL，`userDecision` 固定为 `not-required`；latest、父提交、master 最新、旧包目录和隐式回退
均不允许。还必须将两个文件与同版本官方发行包交叉核对，并把 SHA-256、字节数及 JS/WASM
导出配对结果写入缓存身份、构建证明和 schema 3 marker。

当前 `v5.6.276` 基线使用该 tag 精确 commit 的官方 `libGD.js` 与 `libGD.wasm` 产物，
`libGdProvenance.sourceKind` 必须是 `official-exact-commit-artifact`。5.6.269 曾使用的 legacy
prepared 例外仅属于已结束的历史审计，不得在当前或后续内核升级中复用。脚本不扫描候选目录、
不猜测来源，也不在失败时回退；来源与 build 均需完成摘要、大小、WASM 编译和 JS 引用导出配对
检查，并将证明写入 build provenance 与 schema 3 marker。

```text
node assets/playmesh-library/public/GDevelop/playmesh/scripts/package-webide-release.mjs --action package --prepared <prepared-output>
node assets/playmesh-library/public/GDevelop/playmesh/scripts/package-webide-release.mjs --action verify --allow-pending-downloads true
```

脚本只从 `webide-lock.json.upstream.tag` 派生上游版本，并强制校验 ZIP 资产名。
每次核心升级成功后，正式 ZIP 必须保存到仓库工作区
`resources/GDevelop/GDevelop-webide-v{upstreamVersion}.zip`；当前固定路径为
`resources/GDevelop/GDevelop-webide-v5.6.276.zip`。ZIP 根直接包含 `index.html`，不得再套一层
`gdevelop-webide/` 目录，否则 App 解压到 `official/` 后无法直接启动。归档按规范路径排序、
使用固定时间与权限写入，并拒绝符号链接、ZIP32 越界、source map 和缺失关键文件。

临时官方源码树由 `.gitignore` 排除，但最终
`resources/GDevelop/GDevelop-webide-v{upstreamVersion}.zip` 与同目录 `update.json` 都必须
能够由 Git 正常跟踪。它们由用户按普通仓库提交与推送流程一同分发；本地脚本不创建
Release、不调用 GitHub/Gitee API，也不执行 stage、commit、push。不得把解压源码、
`node_modules`、build、prepared output 或 ZIP 临时/备份文件加入 Git。

打包脚本先在同目录生成临时 ZIP 并完成结构、大小和 SHA-256 校验，再原子替换固定文件名。
若本地已有同版本 ZIP，脚本先用同目录硬链接（不支持时复制）保留旧文件；ZIP 与清单均
替换成功后才删除备份，任一步失败则恢复旧 ZIP。随后原子更新现有
`resources/GDevelop/update.json`，其唯一合法结构为：

```json
{
  "sha256": "<64 位小写 SHA-256>",
  "version": "5.6.276",
  "size": 123,
  "downloads": [
    { "name": "GitHub", "url": "https://..." },
    { "name": "Gitee", "url": "https://..." }
  ]
}
```

根对象只允许 `sha256`、`version`、`size`、`downloads`，线路项只允许 `name`、`url`；旧
`sha` 字段、MD5、未知字段、重复线路、带凭据或非 HTTPS URL 均失败。`size` 是最终 ZIP
文件的精确字节数，不是解压大小；`downloads` 的名称、顺序、URL 及用户配置结构必须逐项
原样保留。构建与打包脚本不得猜测、增加、删除或改写下载线路。

包准备后记录：

- ZIP 文件校验值（SHA-256）和压缩字节数；
- 解压后的总字节数；
- `index.html`、service worker、GDJS Runtime、libGD、图标及 Playmesh policy 文件存在；
- ZIP 解压不会越界，且布局验证通过。

`assets/app/GdevelopWebIDE.json` 每次 App 打包都必须存在，内容为按名称列出的远端版本清单
URL；App 先探测这些清单线路，再读取其中的 `downloads` 并探测实际 ZIP 线路。该文件不是
ZIP 下载清单本身，不能把两级 URL 混写。GDevelop 本地发布脚本只验证最终 ZIP 与
`update.json` 的 `version/sha256/size` 完全一致，并证明 `downloads` 未被改动。完成后把
ZIP 与清单交给用户正常 Git 流程；不在该脚本中验证或改变远端状态。

用户端“安装”“升级”和“修复”必须复用同一下载、测速、精确大小、SHA-256、安全解压与
原子覆盖流程。更新判断只比较完整 SHA-256：未安装即下载，摘要相同即为当前版本并允许
强制修复，摘要不同即更新；因此同 `version` 不同摘要仍更新，不同 `version` 相同摘要仍是
当前实体。`version` 只展示官方核心版本，UI 另显示 SHA 短构建标识，详情保留完整摘要。新 WebIDE 必须
在 staging 中完整验收后才能替换 `official/`。下载、校验、解压、启动自检或覆盖失败时均
保留旧 `official/`，不能留下半安装目录。测速或某一线路失败只影响该线路，不阻塞用户选择
其他可用线路或继续使用已安装版本。

## 8. 真实端到端验收

至少在 Windows 浏览器、App WebView 和手机横屏各执行一次：

1. 下载、校验、解压、首次打开和离线再次打开。
2. 创建 single 和 online 项目，重启 App 后重新打开。
3. 添加资源与行为、预览、保存历史、恢复历史。
4. 发布到本地 Playmesh，打开游戏并核对名称、图标、方向和 `gameId`。
5. 两台设备验证共享 Session 自动入房、Authority direct start、guest 拒绝、后加入玩家编号与
   头像、零倒计时、状态同步、软离开、重连和 App 容器最终断开。
6. 将同一工程迁入官方 GDevelop，执行普通 HTML/原生导出，确认没有 Playmesh 私有依赖。
7. 断网、官方目录失败、Gateway 暂时不可用、上传中断和低内存回退提示。

真实验收发现的问题也必须落回脚本、overlay 或测试，然后重新执行 clean replay；不能只
修已生成的 build。

## 9. 发布与回滚

发布前保留旧锁记录和旧资产。新版启用应只改变锁文件指向，不覆盖旧 URL。若下载、启动、
数据迁移、预览、发布或多人出现阻断问题：

1. 把 App 分发指向恢复为上一份已验证锁记录；
2. 保留失败的新资产和日志用于分析，但将其标记为不可下载；
3. 不删除用户项目目录、历史、App 扩展/示例缓存或浏览器偏好；
4. 在新的 Playmesh revision 修复，不能原地替换同名 ZIP；
5. 修复后重新走完整 clean replay、本地 ZIP 与清单一致性验证。

## 10. 升级结果模板

升级完成后在验收记录中至少填写：

```text
GDevelop: <old tag/commit> -> <new tag/commit>
Playmesh revision: <old> -> <new>
Source archive SHA-256: <sha256>
Prepared ZIP: <name>, <compressed bytes>, <installed bytes>, <sha256>
Untouched upstream build: PASS/FAIL + log
Clean policy replay: PASS/FAIL + log
Flow: 0 errors / <count>
Node GDevelop tests: <passed>/<total>
Go/Flutter/SDK gates: PASS/FAIL/SKIPPED(reason)
Windows/App WebView/mobile landscape: PASS/FAIL
Official-client migration and generic zero-injection: PASS/FAIL
Multiplayer two-device E2E: PASS/FAIL
Windows early-bootstrap host reply: PASS/FAIL
Known limitations: <list>
Rollback target: <previous local ZIP sha256 and manifest snapshot>
```

只有所有必需项为 PASS、跳过项有明确非产品原因且获得确认时，升级才算完成。
