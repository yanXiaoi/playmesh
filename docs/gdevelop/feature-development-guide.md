# GDevelop 功能修改与可重放开发手册

本文规定在**当前锁定的官方 GDevelop 内核上**新增、删除或修改 Playmesh 功能时的实现、
重放、测试和交付方式。更换官方 tag/commit、libGD 或 GDJS 基线时，应改用
[GDevelop 内核升级手册](core-upgrade-guide.md)。AI、History 和运行时替换的领域合同分别
下钻到本目录对应专项文档，本文不复制它们的协议字段。

本文中的“必须”“不得”是发布门禁，不是建议。完成一次功能修改的定义是：从锁定的官方
ZIP 建立全新源码树，仅靠仓库中的 canonical 源和策略脚本即可得到同一输出，并通过与改动
风险相称的源码、Flow、业务、生产构建和包内审计。

## 1. 先判断修改属于哪一层

不要先改官方文件，再考虑如何保存补丁。先确定唯一事实源和 ownership：

| 修改内容 | 唯一维护位置 | 重放方式 | 禁止做法 |
| --- | --- | --- | --- |
| Playmesh WebIDE 组件、controller、adapter、协议客户端 | `assets/playmesh-library/public/GDevelop/playmesh/overlays/` | 策略将 overlay 整树复制到一次性上游树 | 在 `work/` 的源码或 build 中直接维护 |
| 跨 WebIDE/运行包共享的浏览器源码 | `assets/playmesh-library/public/developer/` | 字节复制，或生成 `PlaymeshShared/*Source.js` 字符串模块 | 在 WebIDE 和运行包各维护一份副本 |
| 官方组件中的最小接线点 | `scripts/apply-source-policy.mjs` 的 `patchFile` | 校验 Git Blob 前像后精确替换唯一片段 | 把业务状态机、请求或持久化逻辑写进 replacement 字符串 |
| 官方 ZIP 中生成但没有可用 Git Blob 身份的文件 | `patchGeneratedOfficialFile` | 校验原始 SHA-256 后精确变换 | 伪造 Git Blob 身份或无前像覆盖 |
| 必须保持未改的官方低层文件 | `assertOfficialSourceFile` | 校验 Git Blob 和禁止的 Playmesh 引用 | 为了“以后可能用到”提前打补丁 |
| 准备包时才产生的文件、裁剪、provenance | `scripts/prepare-webide.mjs` | 从已审计 build 原子生成 prepared 树 | 直接改 `prepared/`、最终 ZIP 或 build |
| App/Gateway/Flutter/Go 能力 | `lib/`、`go-core/`、`go-server/` 及其测试 | 仓库正常源码和合同测试 | 把宿主业务塞进 WebIDE 官方入口 |

AI 工具合同只维护在
`assets/playmesh-library/public/GDevelop/playmesh/runtime/ai/tools.json`。工程 manifest 的浏览器
canonical 源只维护在 `assets/playmesh-library/public/developer/playmesh-game-manifest.js`。
已有单一事实源时必须复用，不能为了方便再复制一份。

## 2. 官方文件只允许“薄入口”

新增功能的默认架构是：**官方文件只接线，Playmesh 文件拥有完整功能**。

薄入口可以做：

- import 一个 Playmesh-owned 组件、provider、router 或 adapter；
- 在官方已有生命周期中挂载或卸载它；
- 原样转发官方 `project`、options、refs、callbacks、locale 和用户手势；
- 依据一个明确、稳定的 surface/模式字段选择委托目标；
- 在最低外部 I/O seam 注册一个能力实现，并在能力缺失时按合同 fail closed。

薄入口不得做：

- HTTP、轮询、重试、上传、下载或 Gateway 协议；
- IndexedDB、localStorage、工程历史、保存或恢复；
- 业务状态机、审批、错误弹窗、载荷校验或数据迁移；
- 复制一段官方实现后在副本上长期分叉；
- 用 `any`、`FlowFixMe`、模糊正则或吞错来绕过上游类型和生命周期；
- 把两个 delegate 都调用一遍，再根据结果猜测应该采用哪个；
- 在普通官方导出中加入 Playmesh SDK、Bridge、Bootstrap 或 Gateway fallback。

如果一个官方补丁除了 import、挂载、转发或最低 seam 之外还出现异步状态、网络、存储、
复杂分支或业务错误处理，就已经不是薄入口，必须把主体移到 overlay。只有禁用官方在线
服务或替换无法外置的最低运行时 I/O seam 时，才允许更大的官方补丁；此时必须在策略步骤
旁写明不能使用薄入口的原因，并增加专项正向和负向合同测试。

当前可参考的结构包括：

- `BrowserApp.js` 的预览入口只挂载 `PlaymeshPreviewLauncherRouter`，本地 BrowserSW 与普通
  Gateway 预览的路由在 Playmesh-owned 模块中完成；
- `MainFrame`/editor container 的 AI seam 只把官方 callbacks 传给 Playmesh AI，AI 在活动
  `gdProject` 上调用官方 EditorFunctions，修改后触发 dirty 与编辑器刷新回调；
- canonical Authority/Multiplayer/调试源码先在 `public/developer/` 维护，再由策略生成 WebIDE
  字符串模块，而不是维护第二份实现。
- GDevelop 多人兼容只在
  `public/developer/gdevelop-multiplayer-bridge.js`、
  `public/developer/gdevelop-authority-bootstrap.js` 和 Playmesh-owned 运行时注入模块中实现；
  官方 Multiplayer API 只接到该兼容层。共享 Session 自动入房、Authority direct start、guest
  拒绝开始、late roster/avatar 和零倒计时都是 canonical bridge/bootstrap 的 GDevelop 业务，
  不进入 App/Game SDK。
- Windows WebView 导航完成前无法安全执行宿主回包是跨游戏的共享宿主时序问题。只有独立的
  非 GDevelop 最小复现证明同样会丢失早发 bootstrap 回包时，才在共享 Windows 宿主增加回包
  队列；该修复不改变 SDK API、消息协议、超时或版本。

这些是结构示例，不代表可以复制其具体条件。新功能仍须先核对当前官方类型和生命周期。

## 3. 可重放的精确定义

可重放不是“在同一目录反复执行 patch”。正确合同是：

```text
锁定的官方 ZIP + 锁文件 + canonical 源 + apply-source-policy
    -> 全新干净树中的确定 patched source
    -> Flow/test/build/audit/prepare
    -> 确定 ZIP 与 update.json
```

`apply-source-policy.mjs` 会故意拒绝已 patch 或受污染的树。clean replay 测试还会在第一次
成功后对同一树执行第二次策略，并要求第二次因前像变化失败。任何“最后手改 build 一下”或
“从旧 patched tree 继续打补丁”的步骤都会破坏可重放性。

禁止直接修改或复制下列派生产物来修功能：

- `work/gdevelop-webide-build-cache/profiles/default/source`；
- `build-source`、`flow-source`、`raw-build`、`audited-build`、`prepared`；
- profile 中的 receipts、logs、staging 或 backup；
- `resources/GDevelop/GDevelop-webide-v*.zip` 内部文件；
- 已解压安装目录中的 `official/` 文件。

实验性手改只能用于只读定位。方案确定后，将同一逻辑写回 overlay、canonical 源、
`apply-source-policy.mjs` 或 prepare 脚本，丢弃实验树，再从官方 ZIP 重放。

## 4. 一次功能修改的标准流程

### 4.1 写出正向结果和负向边界

修改代码前先记录：

1. 用户能观察到的业务结果；
2. 哪些官方对象、callbacks 和生命周期必须保持；
3. 哪些模块、网络、持久化或运行时绝不能进入该路径；
4. 首次、重复、失败、取消、卸载和页面重载分别应发生什么；
5. 普通预览、游戏内编辑器、官方导出和 Playmesh 发布是否需要不同路由。

只写“输入 JSON 正确、输出 JSON 正确”不算业务验收。涉及编辑器修改时，还要证明真实
GDevelop/libGD 对象已改变、打开的编辑器收到官方刷新回调、工程被标记为未保存，并且后续
读取能看到修改。

### 4.2 检查流水线状态和官方基线

流水线要求 `--zip` 为绝对路径，profile 固定为 `default`：

```powershell
$officialZip = (Resolve-Path 'work\GDevelop-<锁定版本>.zip').Path
$pipeline = 'assets/playmesh-library/public/GDevelop/playmesh/scripts/webide-pipeline.mjs'
node $pipeline status --zip $officialZip --json
```

官方 tag、commit、归档身份只读
`assets/playmesh-library/public/GDevelop/playmesh/webide-lock.json`。不要根据目录名、界面版本或
网络上的“最新版本”猜测基线。

同一 profile 同时只能有一条流水线。活跃 `.pipeline.lock` 由其 owner 持有时，不得手删锁、
启动第二条 Flow/build 或移动 profile 输出。流水线只会自动接管已经确认 owner PID 死亡的
陈旧锁。

### 4.3 实现完整 Playmesh 模块，再接薄入口

推荐顺序：

1. 在 overlay 或 canonical 源实现完整功能；
2. 直接使用当前官方 Flow 类型，写清资源和卸载生命周期；
3. 添加独立单元/模块测试；
4. 最后在 `apply-source-policy.mjs` 加最小官方接线；
5. 同时登记源码合同，证明入口可达、禁用模块不可达；
6. 若删除旧功能，同时删除旧生产路径、测试兼容分支、文案和文档，不保留 silent fallback。

普通官方文件必须使用：

```js
patchFile({
  relativePath: '<官方相对路径>',
  expectedGitBlobSha: '<锁定官方前像 Git Blob SHA-1>',
  transform: source => replaceExactly(
    source,
    '<唯一官方片段>',
    '<最小接线片段>',
    '<可诊断的步骤名称>'
  ),
});
```

缺失、重复或前像变化都必须停止。不得把唯一片段替换改成“尽量匹配”的模糊规则。官方
生成文件改用 `patchGeneratedOfficialFile({ expectedSha256, ... })`，不能混入
`patchedOfficialFiles` 的 Git Blob 分类。

#### GDevelop 专属运行时的边界

GDevelop 预览或导出中的多人、调试、FPS 等能力，主体必须是
`assets/playmesh-library/public/developer/` 下的 canonical 浏览器源码。WebIDE overlay 只能负责：

1. 判断当前 GDevelop surface；
2. 将 canonical 源写入确定的运行目录；
3. 按唯一顺序把脚本标签放在首个 `gdjs.RuntimeGame` 创建之前；
4. 对缺失、重复、乱序或部分注入 fail closed。

定位故障时必须先比较普通游戏与 GDevelop 游戏的第一处分叉。普通游戏和 GDevelop 预览若
共用 `GamePage`、App/Game Bridge 和 SDK 传输层，且普通游戏业务正常，就不能把“可能存在的
通用时序问题”当成已证实根因。只有具备独立非 GDevelop 复现和普通游戏回归证据，才允许修改
共享宿主；共享 SDK 仍不得承载 GDevelop 业务。本轮 `<head>` 早加载已经证明属于共享 Windows
宿主回包调度，因此修复限定为 navigation completed 前缓存 App/Game 回包，GDevelop lobby
语义仍留在 canonical bridge/bootstrap。

### 4.4 先跑定向业务测试

至少覆盖：

- Playmesh 模块的成功、失败、重复、卸载和并发边界；
- 薄入口只调用一个 delegate，并完整透传 options/callbacks；
- 删除功能的负向依赖扫描；
- Babel/Flow 能解析所有受影响文件；
- 对编辑器写操作，使用一次性项目和真实 libGD/官方函数完成
  `读取 -> 新建/修改 -> 再读取`，而不是只比较 DTO；
- 对跨 App/Gateway 修改，运行对应 Flutter/Go/SDK 合同。
- 对 GDevelop 多人兼容，使用 host/guest 业务夹具证明唯一 session、自动加入、Authority 直接
  开始、guest 不可开始、后加入玩家编号与头像刷新；必须证明官方 `startGameCountdown` 仅为
  无副作用 no-op，且没有按钮、pending operation、事件、Binary 包或旧 type 5 接受路径；
- 对共享 Windows WebView 宿主，使用 head 早加载和普通 body 末尾加载夹具证明 App/Game 回包
  只在 navigation completed 后按序、恰好一次送达，新导航清除旧 document 消息，并验证普通
  非 GDevelop 游戏行为不变；

自动测试不得把用户当前活动工程当 fixture，也不得为了清理测试而调用用户历史、自动保存或
回滚。需要手工验证当前工程时必须先获得用户明确授权；保存、放弃或恢复由用户决定。

### 4.5 只把受影响摘要设为 `pending`

`source-policy-output-manifest.json` 绑定：

- 官方 tag/commit；
- overlay 整树 SHA-256；
- canonical/generated 文件的 post-patch SHA-256；
- 每个官方补丁的 Git Blob 前像和 post-patch SHA-256。

修改期间仅将实际受影响的摘要写成小写字符串 `pending`。大写 `PENDING`、空串、旧候选或
从已 patch 树计算的摘要都无效。同一锁定官方版本上的功能修改通常不应改变
`upstreamGitBlobSha`；它只在经过审计的官方基线升级时变化。

### 4.6 从官方 ZIP 收集候选并冻结

候选只能来自本轮全新干净树：

```powershell
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-source-policy-clean-replay.mjs `
  --zip $officialZip `
  --allow-pending-output-manifest
```

带 `--allow-pending-output-manifest` 的输出会标记 release blocked，只能用于收集候选，不是
通过证据。确认候选集合只包含预期文件后，将本轮打印的 SHA-256 写回 manifest。不得沿用
另一次运行、旧 profile 或中间实现的候选。

冻结后必须再次从另一个全新树严格重放，不能带 override：

```powershell
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-source-policy-clean-replay.mjs `
  --zip $officialZip
node assets/playmesh-library/public/GDevelop/playmesh/scripts/verify-layout.mjs
```

严格重放必须同时证明前像、overlay 双向 ownership、source-dependent 合同、全部输出摘要，
并证明污染/二次重放被拒绝。任何 `pending` 都会阻断正式 audit、prepare 和 package。

### 4.7 运行正式流水线

开发中只想快速得到可安装测试包时：

```powershell
node $pipeline dev-package --zip $officialZip
```

`dev-package` 会复用缓存并完成快速 build 审计、prepare 和安装证明，但明确跳过完整 Flow 和
完整合同测试，不能写成“正式验收通过”。单独执行 `package` 也不会隐式运行 Flow/test。

正式交付前，优先用隔离、不改 `resources/GDevelop` 的完整检查：

```powershell
node $pipeline release-check --zip $officialZip
```

公开下载线路完整时，正式覆盖当前仓库包使用：

```powershell
node $pipeline all --zip $officialZip
```

本地测试包若 `update.json.downloads[*].url` 被明确允许保持为空，可完成全部质量阶段至 package，
再做本地实体校验：

```powershell
node $pipeline all --zip $officialZip --to package
node assets/playmesh-library/public/GDevelop/playmesh/scripts/package-webide-release.mjs `
  --action verify `
  --allow-pending-downloads true
```

该开关只允许下载 URL 为空，仍严格校验 ZIP hash/size、冻结清单和 provenance；它不是公开
发布证据。公开发布的 `release-check`/`all` 不使用此开关。

新机器或损坏缓存没有可信 libGD provenance 时，必须显式导入同一官方 commit 的已验证
`libGD.js`/`libGD.wasm`；流水线不会猜来源或回退到 latest：

```powershell
$libgdSeed = (Resolve-Path '<已验证 libGD 目录>').Path
node $pipeline all --zip $officialZip `
  --libgd-seed $libgdSeed `
  --libgd-pin '<锁定身份>' `
  --libgd-revision '<40 位官方 commit>' `
  --libgd-url-identity '<包含同一 40 位 commit 的官方精确 URL>' `
  --libgd-source-kind official-exact-commit-artifact
```

seed 与 pin 必须成对出现，JS/WASM 的大小、SHA-256 和配对导出必须验证通过。

## 5. Receipts、缓存和失败处理

固定工作区是 `work/gdevelop-webide-build-cache/profiles/default/`：

- `receipts/{step}.json` 记录输入摘要、实际工具版本、输出树摘要和完成时间；
- `logs/` 保存对应阶段日志；
- source、Flow、build、GDJS、prepared 和依赖目录是可验证的增量缓存；
- staging、backup 和 release-check 临时目录由流水线原子创建和清理。

只用 `status --json` 判断 receipt 是否有效。不得手改、复制或伪造 receipt，也不得把旧 receipt
时间当成新实现通过。看到 `input digest changed` 时，按流水线指出的前置阶段刷新；不要删除
receipt 绕过依赖链。

发生失败时遵循：

1. 记录第一个真实错误并停止后续 package/verify；
2. 区分源码/类型/合同错误与工具启动、旧 Flow server、原生进程崩溃等环境错误；
3. 只读确认进程、锁、实体文件和 receipt 后再决定重跑；
4. 环境瞬时失败最多做一次同输入、无并发的隔离重跑；重复失败就保留日志并定位故障模块；
5. 修复必须回到 canonical 源或策略，随后重新生成摘要、clean replay 和受影响 receipts；
6. 不得因为测试慢就降低 Flow、删负向断言、扩大 `any` 或把失败包冒充成功包。

`--keep-worktree-on-failure` 只用于保留本轮 staging 诊断；`--force-deps-refresh` 和
`--adopt-successful-build` 都不是日常修复开关。

## 6. 真实业务验收要求

源码测试、协议测试和真实业务测试不能互相替代。

对于会修改 GDevelop 工程的功能，隔离业务验收至少要：

1. 用锁定版本的真实 libGD 打开一次性工程；
2. 读取目标场景、对象或事件作为业务前态；
3. 调用产品实际会调用的官方 EditorFunction/EventPayload 路径；
4. 新建并编辑一个真实业务实体，而不是只构造成功响应；
5. 再次从活动 `gdProject` 读取并验证结构、callbacks 和 dirty 状态；
6. 丢弃整个一次性工程或临时目录。

AI 修改与用户编辑具有相同内存语义：AI 不写 `current`、历史或 revision，不自动保存，也不
替用户回滚。详见[本地 AI 开发流](local-ai-development-flow.md)。普通用户保存和历史恢复是
另一条路径，详见[本地工程历史](history-development.md)。验收脚本不得把这两条职责重新
耦合。

若测试发现旧协议、旧缓存或旧磁盘状态不兼容，而需求明确不兼容旧功能，应删除生产兼容
分支并给出精确的手动清理路径；未经授权不得在 App 启动时自动删除用户数据。

## 7. 包内和安装后验收

生产 build 通过不等于最终 ZIP 正确。至少检查：

- `playmesh-integration.json` 和 build provenance 都存在且互相绑定；
- `playmesh/ai/tools.json` 等 canonical 资源与源码字节一致；
- 关键 Playmesh 模块实际进入 production chunk；
- 被删除的旧协议、远程 launcher、fallback 和兼容标识在全部生产 JS 中为零命中；
- 普通官方导出、游戏内 BrowserSW 预览和 Playmesh Gateway 预览的注入边界分别正确；
- ZIP 根直接包含 `index.html`，无 source map、路径越界或嵌套外层目录；
- 最终 ZIP 的 SHA-256、精确字节数与 `resources/GDevelop/update.json` 一致；
- `downloads` 的名称、顺序和 URL 未被打包脚本改写。

同一个官方 `version` 可以对应新的 Playmesh 包摘要。安装判断以完整 ZIP SHA-256 为准，不以
版本号相等为“无需更新”。本地安装或修复应复用 staging、完整校验和原子替换；失败时保留
上一份可用 `official/`。

## 8. 完成定义

功能修改只有同时满足以下项目才算完成：

- [ ] ownership 正确，业务主体在 overlay/canonical 源；
- [ ] 官方补丁是可解释的最小薄入口，前像和唯一片段已锁；
- [ ] 正向业务行为、错误、重复、卸载和负向依赖均有测试；
- [ ] 编辑器修改使用真实 libGD/官方函数做过隔离的读写回读；
- [ ] 受影响 manifest 摘要来自本轮干净树，且已全部冻结；
- [ ] strict clean replay 通过，污染/二次重放被拒绝；
- [ ] Flow 为 0 errors，正式 WebIDE 合同测试通过；
- [ ] 受影响的 Flutter/Go/SDK 门禁通过；
- [ ] GDevelop lobby 业务只在 canonical bridge/bootstrap；共享 Windows 宿主改动有独立非
      GDevelop 复现，App/Game SDK 未增加 GDevelop 业务，普通游戏回归通过；
- [ ] production build、audit、prepare、package 和实体 verify 通过；
- [ ] 最终 ZIP 做过旧路径零命中和运行边界审计；
- [ ] 文档、测试、源码和包描述的是同一架构；
- [ ] 没有把 `dev-package`、pending override 或本地空下载 URL 验证冒充公开发布证据。

交付记录至少写明：官方 ZIP 身份、overlay/manifest 摘要、clean replay、Flow 文件数与错误数、
合同测试结果、生产 chunk、ZIP 文件数/大小/SHA-256、宿主测试、未执行项及原因。任何未知或
跳过项都要明确披露，不能用“应该没问题”代替证据。
