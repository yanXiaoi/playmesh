# Playmesh 平台开发文档

本目录面向维护 Playmesh App、Go Core、Go Server、SDK、能力插件和 Developer
Gateway 的平台开发者。游戏作者只需要阅读 [`docs/game/`](../game/README.md)
中的公开契约。

## 开发约定

1. [能力开发约定](capability-development.md)
   - 新增或修改传感器、震动、摄像头、麦克风、MIDI、USB 等平台能力。
   - 统一描述符、实例生命周期、权限、平台适配、自检和注册。
2. [SDK 开发约定](sdk-development.md)
   - 修改 Game SDK、App Bridge SDK、TypeScript/声明片段、宿主执行器和兼容发行版。
   - 保证运行逻辑、类型、版本、网关响应和生成产物来自同一注册表。
3. [开发者工作区开发约定](developer-workspace-development.md)
   - 新增 Developer Operation、网页工作区功能、AI 审批、项目文件能力和后台行为。
   - 保证路由、OpenAPI、操作目录、权限和运行处理逻辑同源。
4. [Go Server 开发约定](go-server-development.md)
   - 维护轻量游戏包分享、上传与分发服务，以及跨网络联机中转。
   - 保持 Catalog、包管理和 Relay 的边界、鉴权、资源限制与版本独立。

## 通用平台资料

- [技术架构](../01-architecture.md)
- [工程开发规范](../06-engineering-standards.md)
- [开发环境与统一发布](../04-dev-env.md)
- [局域网与公共中转](../remote-game-relay.md)
- [Catalog API](../catalog-api.md)
- [HarmonyOS 构建与适配](../harmony-release.md)
- [当前版本日志](../version/README.md)

## 共同原则

### 单一行为来源

公开契约、运行逻辑、生成物和文档不能各自维护一份：

- 能力插件由插件描述符和实例实现驱动注册表、工作区、自检与 SDK。
- SDK 由 Dart Feature 驱动 TypeScript、`.d.ts`、宿主执行器和兼容发行版。
- Developer API 由 Operation Definition 驱动路由、OpenAPI、AI 目录和中间件。

### 明确的边界

- Flutter UI 不直接拼接 Core 请求、WebSocket 帧或游戏文件路径。
- Go Core 不解释游戏规则、分数和胜负。
- Go Server 不执行游戏规则，不替代 Go Core，也不能获得公共中转的端点内容密钥。
- 游戏不接触原生 Bridge、Core 地址、中转密钥或内部协议。
- 普通浏览器不获得 App Bridge 原生权限。
- 公共中转不持有端点内容密钥。

### 版本独立

App、Game SDK、App Bridge SDK、Developer API、Core、Core 协议、Catalog API、
Relay 协议和 CLI 分别评估版本，不因 App 发布而机械同步升级。

### 可验证但不夸大

代码测试、平台构建、包结构、真机运行、真实网络和生产签名是不同结论。版本日志和
验证记录必须写明已完成与未完成的层级。

## 新增平台领域

后续增加新的平台级领域时：

1. 在 `docs/platform/` 新建 `{domain}-development.md`。
2. 写清唯一注册入口、职责边界、扩展步骤、版本规则、安全要求和验证清单。
3. 将文档加入本目录和根 `README.md`。
4. 游戏作者可见的部分另写入 `docs/game/`，不要暴露内部实现。
5. 重大不可逆决策应在版本日志或独立 ADR 中保留当时的上下文。
