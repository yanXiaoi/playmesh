# GDevelop Playmesh 项目配置开发约定

本文补充 GDevelop 工程中 Playmesh 项目配置的所有权、协议和生成边界。通用修改流程仍以
[GDevelop 开发总规范](development-standards.md)和
[功能修改与可重放开发](feature-development-guide.md)为准；当前文件定位见
[源码接线索引](integration-wiring.md)。

## 两层配置必须分开

GDevelop 编辑期 sidecar 与发布包 `main.json.config` 不是同一个协议：

- App 持有的 `gdevelop/project-config.json` 是 Playmesh 自有、带 revision 的严格协议。
  `webRuntimeMultithreading` 在当前 schema 中必须是布尔值。旧 schema 和此前未包含该字段的
  schema 读取为 `false`，下一次保存写入当前完整结构。
- `main.json.config` 是跨编辑器共享的不透明可选扩展值，通用清单解析器不得校验其类型或
  内部字段。GDevelop 只在预览和发布生成清单时，把 sidecar 的布尔值投影为
  `config.webRuntime.multithreading`。

严格 sidecar 不得被误用为通用清单校验器；通用 `config` 的不透明兼容规则也不得放宽
GDevelop sidecar 的类型、精确字段、revision 或冲突校验。

## 屏幕方向投影

屏幕方向继续读取 GDevelop 官方工程属性，不写入 Playmesh sidecar。官方值为
`landscape` 或 `portrait` 时原样投影到 `main.json.orientation`；官方默认/自动方向投影为
`system`，不得再根据设计分辨率猜测固定方向。`system` 生成的游戏在自动启动时只请求
全屏，不向 App 或浏览器指定、锁定或解除方向。

## UI 与保存链路

该开关只放在官方工程属性窗口中现有的 Playmesh 设置区域，不进入 GDevelop 新建项目流程，
也不修改官方 GDevelop 工程 JSON。缺少 sidecar 或旧 sidecar 时显示关闭；用户应用工程属性
时，以界面当前值保存，不维护第二份前后值对照。

```text
官方 PropertiesDialog Apply
  -> PlaymeshProjectConfigSection
  -> PlaymeshProjectConfigController
  -> PlaymeshProjectConfigClient
  -> PUT /dev/api/gdevelop/projects/{gameId}/config
  -> GDevelopProjectConfigController / Repository
  -> gdevelop/project-config.json
```

官方属性应用结果与 Playmesh sidecar 保存结果仍分别报告。请求必须携带
`expectedRevision`；冲突后按既有 controller 规则重新读取和协调，不能覆盖其他客户端的
更新。新字段必须同步 WebIDE Flow DTO、精确 key 校验、Dart OpenAPI/operation、Repository、
本地化消息和冲突测试。

## 预览、发布与 WebView 边界

预览和发布共用唯一 GDevelop 清单构建器，将当前 sidecar 值写成：

```json
{
  "config": {
    "webRuntime": {
      "multithreading": false
    }
  }
}
```

只有精确布尔值 `true` 才使 App 的公共 WebView 回环资源网关为该次游戏运行的所有响应添加
`Cross-Origin-Opener-Policy: same-origin` 和
`Cross-Origin-Embedder-Policy: require-corp`。响应头由公共网关处理，不由 GDevelop 游戏代码
或具体游戏包实现；普通浏览器分享不受影响。

开启后，跨源脚本、图片、音频、字体、Worker 和 WASM 等资源必须满足 CORS 或
`Cross-Origin-Resource-Policy`，否则可能被 `COEP: require-corp` 阻止。游戏运行时仍须检测
`crossOriginIsolated`、`SharedArrayBuffer` 和 `Worker`，并保留单线程路径。

## 修改与验收

实现只能落在 Playmesh overlay、canonical 共享源或 App 自有代码中，不直接编辑 official、
prepared、build 或其他生成目录。协议变化至少覆盖：旧 sidecar 默认值、非法类型拒绝、GET /
PUT、revision 冲突、设置面板切换与保存、预览清单、发布清单、本地化合同和 Flow/Babel。
overlay 或生成共享模块变化后，必须按开发手册从锁定官方 ZIP 执行 clean replay，冻结
`source-policy-output-manifest.json` 的真实摘要，再运行严格重放。
