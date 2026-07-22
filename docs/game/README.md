# Playmesh 游戏开发文档

本目录是 Playmesh 游戏作者和 Game SDK 使用者的文档入口。平台内部架构、阶段计划和历史验证仍保留在 `docs/`、`docs/status/` 与 `docs/verification/`。

## 阅读顺序

1. AI 提示词：主工作区点击“AI”直接进入统一 AI 开发页，API 接口文档与公共、游戏模式、显示模式模板位于同一页面。公共“自定义想法”会同时合入对话和 Agent 提示词；对话文本只附带当前项目已勾选能力的完整声明，Agent 文本则写入全平台注册表 API 与能力测试 API，不直接内嵌全量声明。“复制全平台能力”可独立获取全部平台注册能力，醒目的“获取项目提示词”用于切换、复制或下载两份 UTF-8 TXT。Agent 类型还可从本机 IP 枚举中选择电脑端 AI 能访问的 Base URL，用于从电脑接管手机上的开发工作区。
2. [游戏开发指南](development-guide.md)：内置工作区与 IDEA/CLI 开发流程、运行模式、页面职责和 Authority 边界。
3. [游戏包与 main.json](package-format.md)：目录结构、公开资源、清单字段、安装与数据目录。
4. [Game SDK v1](sdk-v1.md)：当前 `playmesh.js` 已实现的 API、设备能力回调、存储和 FPS 上报。
5. [网页开发者通道](web-dev-channel.md)：第四阶段工作区规格；单机/联机项目创建、`main.json` 与能力声明可视化编辑、IDEA 风格文件树、项目级本地历史、结构化校验、运行入口、SSE 同步、统一日志以及 AI 可读的 SDK、接口和 Schema。
6. [在线游戏源与 Catalog API](../catalog-api.md)：本机游戏库分享、多源聚合搜索与游戏包下载接口。
7. [能力插件开发](capability-plugins.md)：插件目录、描述符 Schema、有状态实例协议、编译期注册、工作区全平台注册表测试和当前传感器插件契约。

## 当前版本

- Game SDK：`2.0.0`
- App Bridge SDK：`2.0.0`
- Developer CLI：`1.2.0`（当前开发版本；正式基线 `1.1.0`）
- SDK 地址：`/playmesh/sdk/v1/playmesh.js`
- 游戏公开资源：`/app/...`
- 游戏包根目录：`playmesh-library/packages/{gameId}/`
- 平台不内置游戏 Demo；开发者工作区新建的项目直接进入统一游戏库。
- 页面入口：`entries.game` 默认 `app/index.html`；`entries.controller` 默认 `app/controller/index.html`；多人权威 JavaScript 使用 `authority.entry`。

## 最小游戏

```text
packages/com.example.hello/
  main.json
  capabilities.json  # 可选，仅在需要平台能力时创建
  app/
    index.html
```

```html
<!doctype html>
<html lang="zh-CN">
  <body>
    <main id="game">Hello Playmesh</main>
    <script src="/playmesh/sdk/v1/playmesh.js"></script>
    <script>
      playmesh.ready.then(() => {
        console.log(playmesh.session.getCurrent());
      });
    </script>
  </body>
</html>
```

单机游戏也必须声明 `orientation`、`modes`、`displayModes` 和玩家人数。完整字段说明见[游戏包与 main.json](package-format.md)。

## 必须遵守的边界

- 游戏只读取自身 `app/` 和平台 `/playmesh/...` 公共资源，不能跨目录读取其他包或 `data/`。
- 游戏只通过 Game SDK 使用会话、玩家、联机、生命周期、存储等平台能力。
- 设备能力只在同级 `capabilities.json` 声明；新建项目和项目设置均可编辑。能力 code、中文名、说明和 App/HTML 适配状态以 `GET /dev/api/capabilities` 返回的统一注册表为准，运行时自检使用 `GET/POST /dev/api/capability-tests`。
- 游戏页面不得直接连接 Go Core、构造内部 WebSocket 帧或访问原生 Bridge。
- 多人游戏的最终规则、分数和胜负由 Authority Runtime 决定，Go Core 只负责通用会话与消息路由。
- 启动会话的 App 游戏运行端固定为 Authority Client。大屏主机不属于 `players`；普通多屏 App 主机可同时作为 Player，但玩家顺序不参与 Authority 判定。
- 持久化数据统一写入开始游戏的 Authority 主机；浏览器和加入设备不保存独立副本。
