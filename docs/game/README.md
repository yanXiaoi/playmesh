# Playmesh 游戏开发文档

本目录面向 Playmesh 游戏作者。平台内部架构、SDK 实现和 Developer Gateway
扩展约定统一放在 [`docs/platform/`](../platform/README.md)；阶段与版本历史分别位于
[`docs/status/`](../status/)和 [`docs/version/`](../version/)。

## 按开发方式选择

### AI 开发

从 [AI 游戏开发](ai-development.md) 开始。

适用于：

- 按 [ChatAI 使用方法](chat-ai-development.md) 把项目提示词交给普通对话 AI；
- 在工作区“对话控制台”执行 AI 返回的 JSON 指令；
- 按 [AgentAI 使用方法](agent-ai-development.md) 让可调用 HTTP API 的 Agent
  直接读取项目、修改文件、校验、运行和诊断日志。

AI 开发与手工开发使用同一个项目目录、SDK、校验器、运行时和本地历史，不存在独立的
“AI 项目格式”。

### IDEA / CLI 开发

从 [IDEA 与 CLI 游戏开发](idea-cli-development.md) 开始。

适用于：

- 在 IDEA、WebStorm、VS Code 等外部 IDE 中使用完整 `.d.ts` 和中文 JSDoc；
- 从 App 拉取已有项目或创建新项目；
- 使用 `playmesh-cli dev/run/logs/update` 分别执行开发代理、正式发布运行、日志附加和
  集成更新；
- 拉取损坏但仍有有效游戏 ID 的项目进行修复。

CLI 命令的权威说明位于 [`dev-cli/README.md`](../../dev-cli/README.md)。

### 网页工作区

从 [网页开发者通道](web-dev-channel.md) 开始。电脑浏览器和 App 内置 WebView 使用
同一工作区，提供项目管理、编辑器、Diff、本地历史、校验、运行、日志、能力测试、
AI 提示词和操作审批。

## 通用游戏契约

无论使用 AI、CLI 还是网页工作区，都应按以下顺序了解公共契约：

1. [游戏开发指南](development-guide.md)：运行模式、Player/Authority 分层、生命周期、
   状态同步、Binary Channel、存储和性能。
2. [游戏包与 main.json](package-format.md)：目录结构、清单、入口、能力声明、数据目录
   和导入导出边界。
3. [Game SDK / App SDK](sdk-v1.md)：当前公开 API、类型、角色限制和错误语义。
4. [游戏能力使用指南](capability-plugins.md)：如何直接使用非敏感 Web API，并按需在
   `capabilities.json` 中声明敏感权限或 Playmesh 多平台适配能力。
5. [在线游戏源与 Catalog API](../catalog-api.md)：游戏源声明、搜索、下载与认证。

## 当前契约

- 主 SDK 稳定地址：`/playmesh/sdk/v1/playmesh-main.js`
- App SDK 稳定地址：`/playmesh/sdk/v1/playmesh-app.js`（由平台预先注入）
- 游戏公开资源：物理 `app/` 直接映射到运行时 `/`
- Bucket 上传文件：`/bucket/...`
- 游戏包目录：`playmesh-library/packages/{gameId}/`
- 游戏入口：`entries.game` 对所有游戏显式必填；默认模板写入 `index.html`
- 单屏多人控制器入口：`entries.controller` 显式必填；默认模板写入
  `controller/index.html`
- 多人 Authority 入口：`authority.entry` 显式必填；默认模板写入
  `static/js/service/index.js`
- SDK 清单版本：`sdkVersion` 与 `appSdkVersion` 均必填；新保存项目分别写入 `4.1.0`
  与 `3.3.0`
- 游戏业务 locale：`playmesh.app.runtime.getLocale()`（只返回当前显示端 locale；
  游戏自行提供翻译，不读取 App messages）

URL 中的 `sdk/v1` 是稳定资源路径，不代表游戏声明的语义版本。目标 App 只接受 Game
SDK `4.1.0`；App SDK `3.2.0` 与 `3.3.0` 均受支持，并解析到当前兼容 bundle。

## 最小游戏

```text
packages/com.example.hello/
  main.json
  capabilities.json  # 可选
  icon.png            # 可选
  app/
    index.html
```

```html
<!doctype html>
<html lang="zh-CN">
  <body>
    <main id="game">Hello Playmesh</main>
    <script src="/playmesh/sdk/v1/playmesh-main.js"></script>
    <script type="module">
      const ready = await playmesh.ready;
      console.log(
        ready.main.session,
        playmesh.app.runtime.getLocale(),
      );
    </script>
  </body>
</html>
```

单机游戏也必须声明方向、模式、显示模式和玩家人数。完整字段见
[游戏包与 main.json](package-format.md)。

## 游戏代码必须遵守的边界

- 只读取自身外层物理 `app/` 映射到运行时 `/` 的普通资源、平台
  `/playmesh/...` 和 SDK 返回的 `/bucket/...`。用户首段 `app` 是普通资源路径：
  物理 `app/app/**` 映射为 `/app/**`，不会别名到外层 `app/**`。
- 只通过 `playmesh.main.*` 使用会话、玩家、联机、生命周期和存储；通过
  `playmesh.app.*` 使用当前终端的 locale、性能和平台能力。
- 面向游戏代码的唯一全局对象是 `window.playmesh`，其根级公开成员严格只有
  `ready`、`main` 与 `app`。Game SDK `4.1.0` 的游戏域只位于
  `playmesh.main.*`，App SDK `3.3.0` 的终端域只位于 `playmesh.app.*`；
  `window.playmeshApp` 与公开 `__*` 内部桥接均不存在。`main.ready` 内部先等待
  `app.ready`；根 `playmesh.ready` 只复用这条初始化链并返回 `{ main, app }`，
  不保留其他旧根路径。
- 不读取分享参数、内部 token、Core 地址、原生 Bridge 或 WebSocket 帧。
- 不根据局域网、公共中转、浏览器或 App 加入方式分叉游戏协议。
- 最终规则、分数和胜负由 Authority Runtime 决定，Go Core 只负责通用会话与路由。
- 大屏 Authority 主机不属于 `players`；普通多屏主机可同时作为 Player，但玩家顺序
  没有 Authority 语义。
- 持久化数据写入 Authority 主机；浏览器和加入设备不建立独立 Bucket 副本。
- 非敏感权限和用户主动文件选择直接使用标准 Web API；WebView 敏感权限与 Playmesh
  多平台适配能力才需要在 `capabilities.json` 中按页面角色声明。

## 文档扩展规则

新增游戏作者文档时：

1. 一个主题只保留一个事实源，其他文档使用链接而不是复制完整规则。
2. AI、CLI、网页工作区只描述各自入口；游戏包和 SDK 语义放在通用契约中。
3. 平台实现、内部协议和维护约定放入 [`docs/platform/`](../platform/README.md)。
4. 新文档必须加入本目录索引；公开契约变化还要同步版本日志、Schema、模板和测试。
