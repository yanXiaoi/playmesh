# 能力开发约定

本约定适用于 Playmesh 平台能力插件。游戏作者如何声明和调用能力见
[游戏能力使用指南](../game/capability-plugins.md)。

## 目标

每个能力在同一插件实现中定义：

- 稳定 code 和独立 `apiVersion`；
- 中文名称、用途和 App/HTML 支持状态；
- 创建参数、方法、事件和错误数据 Schema；
- 有状态实例的创建、调用、事件、错误与释放；
- 当前平台可用性和自检；
- 真实底层资源的生命周期。

通用运行时只理解“创建实例、调用方法、接收事件、释放实例”，不能为具体设备类型增加
平行分支。

## 目录

```text
lib/core/capabilities/
  capability_plugin.dart
  capability_registry.dart
  capability_runtime.dart
  default_capability_plugins.dart
  {domain}/
    {domain}_capability_plugin.dart
  support/
```

- 一个能力一个目录。
- `support/` 只存放两个以上插件真正共享的底层组件。
- `default_capability_plugins.dart` 是唯一编译期注册入口。
- 不在工作区、SDK 弹窗、自检页面或平台层另建能力列表。

## 命名和版本

- code 按功能命名，不绑定供应商或平台，例如 `sensor.accelerometer`。
- code 发布后保持稳定；语义改变时新增 code，而不是复用旧名称。
- `apiVersion` 使用 `MAJOR.MINOR.PATCH`。
- 方法、参数、返回值或事件发生不兼容变化时升级插件 `MAJOR`。
- 新增兼容方法、事件或可选字段升级 `MINOR`。
- 不改变契约的实现修复升级 `PATCH`。
- 插件版本与 App、Game SDK、App Bridge SDK 分别评估。

## 描述符

描述符必须完整表达：

- `code`、`apiVersion`、名称和说明；
- App 与普通 HTML 环境的支持状态；
- 创建参数 JSON Schema；
- 每个方法的参数、返回值和是否要求用户主动触发；
- 每个事件的数据 Schema；
- 可预期错误及恢复建议。

工作区、Agent、能力确认和自检只能消费该描述符，不能用硬编码补充缺失信息。

## 实例生命周期

宿主 Bridge 固定使用：

```text
app.capability.create
app.capability.invoke
app.capability.dispose
app.capability.event
app.capability.error
```

插件实例必须满足：

1. `create()` 只创建当前游戏、当前页面角色已声明并获准的能力。
2. `invoke()` 校验方法名、参数 Schema 和实例状态。
3. `event` 只发送该实例声明的事件。
4. 运行错误通过实例错误通道报告，不静默吞掉。
5. `dispose()` 幂等，释放订阅、计时器、句柄和原生资源。
6. WebView 重载、页面退出或 Bridge 关闭时，运行时可以统一兜底释放全部实例。

共享原生资源时应使用引用计数或 Hub。最后一个实例释放后必须停止底层采样或设备占用。

## 权限和安全

- `capabilities.json.required` 属于主画面。
- `controllerRequired` 只属于单屏多人控制器。
- 当前角色的显式空声明是最终结果，不能回退到另一角色。
- 能力声明、用户本次确认、设备可用性三项全部满足后才能创建实例。
- 用户确认不持久化；插件不能自行扩大到未声明能力。
- 摄像头、麦克风、文件选择等需要用户动作的能力，应把对应方法标为需要主动触发。
- 普通浏览器的标准 Web API 权限与 Playmesh 插件权限是两个边界，不能互相冒充。
- 自检不得产生不可预期副作用，例如持续震动、录音或修改用户文件。

## 平台适配

平台实现可以位于 Kotlin、Swift、ArkTS、C++ 或 Dart，但必须通过同一个插件接口进入
运行时。平台不支持时返回明确不可用状态，不提供假数据。

新增平台适配时需要说明：

- 支持的系统和最低版本；
- 系统权限与清单配置；
- 前后台、锁屏和页面销毁行为；
- 数据单位、坐标系、频率或精度；
- 真机验证方式和当前未验证边界。

## 新增插件步骤

1. 新建独立插件目录和实现。
2. 完成描述符、Schema、实例、`test()` 与 `dispose()`。
3. 在 `default_capability_plugins.dart` 注册一次。
4. 检查 App Bridge 能否通过通用实例协议完成调用，不新增设备专用 Bridge 命令。
5. 确认工作区能力列表、项目设置、能力测试和 Agent 注册表自动出现新插件。
6. 更新游戏作者文档、版本日志和 App 简略日志。
7. 按受影响契约分别评估插件 API、App Bridge SDK、Developer API 和 App 版本。

## 验证清单

- 重复 code 注册被拒绝。
- 描述符 Schema 可序列化并被 Developer API 返回。
- 未声明、未确认、不可用三种情况均不能创建实例。
- 方法参数、事件和错误符合描述符。
- 多实例共享资源不会重复开启或过早关闭底层设备。
- `dispose()`、页面重载和退出都能释放资源。
- App/浏览器、主画面/控制器角色隔离正确。
- 自检有超时、明确状态且无危险副作用。
- Android/iOS/OpenHarmony/桌面支持状态与真实实现一致。
