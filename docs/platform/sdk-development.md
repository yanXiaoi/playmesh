# SDK 开发约定

本约定适用于 Game SDK、App Bridge SDK、网页运行片段、Dart 宿主执行器和 SDK
兼容发行版。游戏作者 API 见 [Game SDK / App Bridge SDK](../game/sdk-v1.md)。

## 核心原则：逻辑即定义

SDK 唯一手写源位于：

```text
lib/core/game_sdk/
  sdk_feature_registry.dart
  features/
    game/
    app/
```

一个 Feature 在同一个 Dart 文件中维护：

- 网页 TypeScript 和类型声明片段；
- 网页实际发送的命令；
- Dart 宿主命令执行器；
- 执行器支持的 SDK Bundle 版本范围。

不能直接修改以下生成产物作为功能实现：

```text
assets/playmesh-library/sdk-src/
assets/playmesh-library/public/sdk/v1/
```

生成物用于发布、审阅、外部 IDE 和包内资源检查，不是运行时事实源。

## 注册表职责

`SdkFeatureRegistry` 是唯一注册与分发位置，负责：

- 按 target 和 order 组装 Game/App SDK；
- 生成 TypeScript、JavaScript 和 `.d.ts`；
- 建立命令到版本化执行器的索引；
- 注册 Game/App SDK 兼容发行版；
- 根据游戏声明解析 SDK Bundle；
- 根据消息携带的实际 Bundle 版本选择对应执行器；
- 拒绝未知版本、重叠发行范围和同版本重复执行器；
- 为网关、Developer API、AI 提示词和 SDK 下载提供同一内容。

Bridge 只负责消息解析、上下文构造、统一分发和响应，不重新维护命令 `switch`。

## Feature 约定

每个 Feature 应围绕一个稳定功能域，例如：

```text
game.session
game.binary
game.sync
game.performance
game.storage-lifecycle
app.capability
app.device
```

一个 Feature 不应仅为缩短文件而创建，也不能同时拥有多个无关业务域。

新增功能时：

1. 在 `features/game/` 或 `features/app/` 新建 Feature。
2. 定义唯一 `SdkSourceFragment.id`、target 和稳定 order。
3. 在同一文件声明网页命令和 Dart 执行器。
4. 执行器通过 `supportedVersions` 声明适用 Bundle。
5. 在注册表增加 `part`，并注册片段与执行器。
6. 不在 Bridge、网关或生成器中增加功能专用旁路。

## 版本与兼容发行版

游戏通过 `main.json.sdkVersion/appSdkVersion` 请求 SDK。资源路径
`/playmesh/sdk/v1/` 是稳定 URL，其中的 `v1` 不是语义版本。

解析链：

```text
requestedVersion
  -> SdkRelease 兼容范围
  -> bundleVersion + 对应 SDK 文件
  -> SDK 消息携带实际 bundleVersion
  -> 版本化命令索引
  -> 对应 Dart 执行器
```

规则：

- 未注册或格式错误版本直接失败，不静默回退最新版。
- 兼容发行范围不能重叠；是否允许空洞必须由当前发布策略明确决定。
- 调用契约未变化的执行器使用 `SdkVersionRange.last` 开放上界。
- 参数、消息、返回值、事件或错误语义不兼容时，封口旧执行器范围并注册新实现。
- 相同命令名可以有多个历史执行器，但同一个 Bundle 只能命中一个。
- 未变化的 Feature 不复制到新版本目录。
- 旧发行版一旦用于已发布游戏，应保持不可变；修正应通过新的兼容发行定义完成。

未来不兼容版本只在受影响域增加例如 `features/game/v3/` 的新实现，不复制整套 SDK。

## SDK 消费入口

以下入口必须通过 `SdkFeatureRegistry`：

- App 本地游戏资源网关；
- 普通浏览器分享网关；
- 本地 App SDK 服务；
- Developer Gateway 公共资源；
- SDK Bundle 下载；
- AI 项目提示词和 `.d.ts`；
- Manifest 版本兼容校验；
- Game/App Bridge 命令分发。

新增消费入口时，必须加入单一源架构断言。禁止从 `rootBundle`、文件系统或测试参数
注入另一份 SDK。

## 生成与发布

日常 `flutter run` 直接使用注册表即时组装内容，不要求先生成静态文件。

正式构建前，统一发布脚本调用生成器，更新：

- `sdk-src/*.ts`；
- `public/sdk/v1/*.js`；
- `public/sdk/v1/*.d.ts`；
- SDK Manifest 与 Schema；
- 默认项目 `main.json`；
- 需要同步的提示词和版本摘要。

生成器必须比较网页实际发送命令和 Dart 执行器集合，发现缺失、陈旧或重复命令时失败。
新的正式构建入口也必须执行同一生成步骤。

## 公开契约变化

修改公开 SDK 时同步评估：

- Game SDK 或 App Bridge SDK 版本；
- 兼容发行范围和执行器范围；
- `.d.ts` 与中文 JSDoc；
- SDK Manifest、Schema 和开发文档；
- 默认项目模板；
- AI 提示词和编辑器补全；
- App、Developer API 或 Core 协议是否真正受影响。

不要因为 App 版本变化而机械升级 SDK，也不要在公开签名未变化时制造无意义新执行器。

## 验证清单

- Source Fragment ID 和顺序唯一。
- 网页发送命令与执行器集合一致。
- 同版本同命令只能命中一个执行器。
- 未注册版本和非法版本被拒绝。
- 旧、新 Bundle 能选择各自执行器。
- `.js` 不包含声明模板，`.d.ts` 不包含版本占位符。
- 所有运行时和开发者入口返回注册表即时组装内容。
- 生成物、Manifest、Schema、模板和版本摘要一致。
- 回滚 App 时同时回滚注册表与同次生成产物，不能只替换静态 JS。
