# GDevelop 轻量官方目录

`generated/` 只包含五个可重放生成的 JSON：根清单、扩展/示例各自的版本化
manifest 和扩展/示例索引。
它不包含 GDevelop 示例正文、素材、示例分片或官方仓库归档。

## 固定来源

- `catalog-lock.json` 固定官方 repository、commit、root tree 和当前 GDevelop 内核。
- 扩展制作输入只稀疏 checkout `reviewed/community` JSON 与 `views.json`。
- 示例制作输入是固定 commit 的稀疏 checkout；本地 `git ls-tree` 固定 path、Git blob
  OID 和 size，并对实际正文计算 SHA-256。生成阶段不依赖 GitHub API。
- 示例只收录规范路径 `examples/<slug>/<slug>.json`。当前 tree 的 287 个工程候选中
  284 个满足此规则；`follow-objects-with-camera`、`leaderboards-firebase`、
  `object-spawner` 的工程文件名与目录 slug 不一致，作为可审计的 unavailable 条目保留，
  不进入可导入列表。
- 扩展计数是 147 个 reviewed + 72 个 community = 219 个正文；旧审计中的 220
  还包含 `extensions/views.json` 这一份视图元数据，它不是扩展正文。
- 示例索引保存 `root/category/id/project path` 及紧凑的相对路径、Git blob OID、
  声明大小、SHA-256、MIME 和许可文档位置。运行时只从项目 JSON 中提取实际引用资源。

## 运行时完整性边界

列表、分类和搜索只读取随 WebIDE 包分发的五个 JSON，不访问网络。扩展正文和示例正文
都固定 official repository、exact commit、root tree、path、Git blob OID（可用时）、size、
SHA-256 和 MIME。只有用户点击安装或导入时，WebIDE 才把该固定 descriptor 交给
`POST /dev/api/gdevelop/catalog/artifact`。App Gateway 会用已安装 WebIDE 的本地索引和
`catalog-lock.json` 双重核对，服务端自行构造官方 Git raw URL，可选择 HTTP 代理，并把
成功正文写入 App 侧 CAS/LKG。浏览器不直连官方仓库。

网络不可达、代理失败、响应超限、commit/path/size/SHA 不符或缓存损坏都只让本次点击
失败并允许重试；本地列表和编辑主流程不受影响。扩展正文继续交给 GDevelop 官方
`SerializedExtension -> addSerializedExtensionsToProject` 解析/安装链，示例继续使用现有
staging、GDevelop project parser 和原子 project import。

## 升级命令

```sh
node scripts/fetch-catalog-sources.mjs --cache <本地缓存> --proxy http://127.0.0.1:1080
node scripts/generate-catalog.mjs \
  --extensions-root <本地缓存>/extensions-git-source \
  --examples-root <本地缓存>/examples-git-source \
  --examples-tree <本地缓存>/examples-tree.json
```

生成器会核对扩展 checkout 的官方 remote/commit/root tree；示例 tree 必须完整且匹配
锁定 commit/root。每次升级都应运行 `tests/test-catalog-*.mjs`、
`tests/test-example-importer.mjs`、`scripts/verify-layout.mjs` 和干净源码策略重放。
