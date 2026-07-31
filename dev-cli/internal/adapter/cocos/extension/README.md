# Playmesh for Cocos Creator

**作者：** Playmesh
**发布日期：** 2026-07-30
**版本要求：** Cocos Creator >= 3.0.0 且 < 4.0.0
**平台支持：** Windows、macOS

## 资源介绍

Playmesh 是由 `playmesh-cli init cocos` 安装的项目级扩展，用于将 Cocos Creator
3.8 的 Web Mobile 或 Web Desktop 构建接入 Playmesh App。

- 在 Web 构建面板显示 Playmesh 发布和构建后运行选项。
- 将构建产物同步到 `playmesh-cli.json` 指定的隔离发布目录。
- 自动注入 Playmesh Game SDK，并可在构建后上传、运行到真实 App。
- 在“扩展 -> Playmesh”菜单中提供项目设置、构建入口、最近构建运行、实时日志和集成更新。
- 项目设置面板可编辑游戏名称、版本、备注、标签、运行形态、能力声明和 Cocos 集成选项。
- 作者不在面板中配置；每次开发启动都会更新当前基础信息。
- 点击 Creator 浏览器预览时，通过短时一次性 token 自动执行
  `playmesh-cli dev <当前完整预览页 URL>`，保留平台和构建任务子路径。
- 自动使用系统可用端口；可通过 `integration.previewBridgePort` 固定端口。
- 普通浏览器只负责安全触发，不加载游戏；游戏只在 Playmesh App WebView 中渲染。

首次使用请在 Cocos 扩展管理器中刷新并在已安装扩展中启用 Playmesh 扩展。

> Cocos Creator 3.8 不提供向“发布平台”或顶部“预览设备”下拉框注册自定义项的公开
> 接口。Playmesh 会显示在 Web Mobile/Web Desktop 的构建选项中。
