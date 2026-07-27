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

## 当前完整能力注册表

当前内置注册表只有以下三项。code 区分大小写，是运行时、项目声明、工作区和 SDK
调用共同使用的唯一主键。

| code / API 版本 | 创建参数 | 方法 | 事件 | 当前适配声明 |
| --- | --- | --- | --- | --- |
| `sensor.accelerometer` / `1.0.0` | 可选 `fps`，整数 `1..120`，默认 30 | `start`、`stop` | `reading`：`x/y/z/timestamp/unit`，单位 `m/s^2` | App 支持；普通 HTML 未适配；设备是否可用取决于原生传感器 |
| `sensor.gyroscope` / `1.0.0` | 可选 `fps`，整数 `1..120`，默认 30 | `start`、`stop` | `reading`：`x/y/z/timestamp/unit`，单位 `rad/s` | App 支持；普通 HTML 未适配；设备是否可用取决于原生传感器 |
| `device.vibration` / `1.0.0` | 不接受创建参数 | `vibrate({style})`；style 为 `selection/light/medium/heavy/vibrate` | 无 | App 支持；普通 HTML 未适配；设备是否可用取决于原生触觉反馈 |

`GET /dev/api/capabilities`、App bootstrap、AI 项目提示词、工作区能力设置和能力确认
都投影这份注册表。普通浏览器分享网关只把 `htmlSupported == true` 的 code 放入
`availableCapabilities`；描述符仍可用于说明未适配项。

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

描述符 Schema 当前是契约和发现信息，不是通用运行时自动校验器。
`CapabilityRuntime` 只校验 code、声明、确认、平台可用性、实例 ID 和 JSON 对象形状；
`optionsSchema`、方法是否存在、`argumentsSchema`、`resultSchema` 和
`requiresUserActivation` 必须由插件 `create()/invoke()` 或对应平台适配器执行。
不能只写描述符而不实现同等校验。

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

## 完整注册流程

新增能力必须走完以下步骤：

1. 在 `lib/core/capabilities/{domain}/` 实现 `CapabilityPlugin`，并提供稳定的静态
   `CapabilityDescriptor`。`descriptor.code`、`apiVersion`、options、methods 和
   events 必须完整。
2. 实现 `isAvailable`、`create(options)`、`test(timeout)` 和插件级 `dispose()`。
   `isAvailable == false` 必须代表真实平台不可用，不能返回假数据。
3. `create()` 返回一个 `CapabilityInstance`；实例实现 `events`、
   `invoke(method, arguments)` 和幂等 `dispose()`。插件在 `invoke()` 内按方法名
   精确分支并校验参数。
4. 在 `default_capability_plugins.dart` 的 `defaultCapabilityRegistrations` 增加一个
   `DefaultCapabilityRegistration`。`descriptor` 指向插件的同一静态描述符，
   `create(dependencies)` 构造真实插件。只注册这一次。
5. 需要共享平台服务时扩展 `DefaultCapabilityDependencies`，由
   `createDefaultCapabilityRegistry()` 注入；不得让插件直接读取页面 Widget 或建立
   第二个全局能力表。
6. 不新增 `app.sensor.*` 等设备专用 Bridge 命令。公开调用继续使用通用
   `app.capability.create/invoke/dispose`，事件继续使用
   `app.capability.event/error`。
7. 更新游戏作者文档和版本记录，并验证 App bootstrap、工作区能力列表、项目能力
   设置、AI 提示词、能力自检和普通浏览器支持过滤都自动反映新插件。

构造 `CapabilityRegistry` 时执行：

```text
_plugins = { plugin.descriptor.code: plugin }

_plugins.length != 输入 plugins.length
  => 失败："能力插件 code 不能重复"
```

因此两个插件的 `descriptor.code` 完全相等时启动即失败；大小写不同会被视为两个不同
code，但能力 code 规范禁止用大小写制造别名。`defaultCapabilityDescriptors` 和
`defaultCapabilityDescriptorRegistry` 都从同一 registration 列表派生，不能另行添加。

## 从项目声明到 SDK 可调用的完整链路

### 1. 角色声明

游戏包从 `capabilities.json` 读取：

```text
主画面/普通游戏页 => required
单屏多人控制器   => controllerRequired
```

当前页面角色只取自己的列表。某角色显式为空时结果就是空，不回退到另一角色。
`GameLauncher` 把该列表作为 `declaredCapabilities` 传给 `AppWebViewBridge`；
浏览器网关把当前页面列表写入 `requiredCapabilities`。

### 2. App Bridge 建表和 bootstrap

`AppWebViewBridge` 使用 `createDefaultCapabilityRegistry()` 实例化全部插件，再创建：

```text
CapabilityRuntime(
  registry: capabilityRegistry,
  declaredCapabilities: 当前角色声明
)
```

bootstrap 返回两类不同数据：

```text
capabilityRegistry
  = registry.descriptors 的完整列表

device.capabilities
  = declaredCapabilities.where(
      code => registry.plugin(code)?.isAvailable == true
    )

device.declaredCapabilities
  = 当前角色原始声明集合
```

也就是说，某 code 只有同时满足“声明中存在完全相等 code、注册表能按该 code 找到插件、
插件 `isAvailable == true`”才出现在 `getAvailable()`；未声明插件即使设备支持也不会
暴露为当前游戏可用。

### 3. 每次加载确认

Game SDK 根据当前角色声明生成能力确认界面。用户选择允许时：

```text
decision == "allow"
且 playmesh.app.isAvailable() == true
且 __confirmCapabilities 是函数
  => request("app.capabilities.confirm")
  => CapabilityRuntime.confirm()
  => _confirmed = true
```

拒绝不会调用 confirm，并进入退出流程。确认不持久化；WebView 重载、Bridge reset 或
页面退出都会把 `_confirmed` 恢复为 `false`。

### 4. `capabilities.create()` 的双层判断

网页 SDK 首先判断：

```text
code 不是非空 String
  => TypeError

options 不是非数组 Object
  => TypeError

bootstrap 不存在
  => 要求先等待 playmesh.ready

bootstrap.device.declaredCapabilities 不 includes(code)
  => 当前游戏未声明

bootstrap.device.capabilities 不 includes(code)
  => 当前设备不支持
```

全部通过才发送：

```json
{
  "command": "app.capability.create",
  "payload": {"code": "能力 code", "options": {}}
}
```

`SdkFeatureRegistry` 只有在 `command.name == "app.capability.create"` 且 App SDK
版本命中 `_AppCapabilityFeature.supportedVersions` 时才调用
`CapabilityRuntime.create()`。宿主再次判断：

```text
registry.plugin(code) == null
  => 未知能力

declaredCapabilities.contains(code) == false
  => 未声明

_confirmed == false
  => 尚未完成本次确认

plugin.isAvailable == false
  => 当前设备不支持

否则
  => plugin.create(options)
```

创建成功后生成唯一 `instanceId`，订阅实例事件，保存到 `_instances[instanceId]`，
并向网页返回 `instanceId/code/apiVersion`。网页再构造 `CapabilityHandle`。

### 5. 方法、事件和错误

`handle.invoke(method, arguments)` 的链路为：

```text
网页 state.active == false
  => 拒绝：实例已释放

method 不是非空 String，或 arguments 不是非数组 Object
  => TypeError

command.name == "app.capability.invoke"
  => CapabilityRuntime.invoke(payload)

_instances[instanceId] == null
  => 实例不存在或已释放

否则
  => open.instance.invoke(method, arguments)
```

具体方法是否存在由插件精确判断。例如震动插件只有
`method == "vibrate"` 才执行；其他值直接失败。传感器共享实例只有
`method == "start"` 或 `method == "stop"` 才执行。

实例产生事件后：

```text
CapabilityInstance.events
  => app.capability.event(instanceId, event.name, event.data)
  => 网页 capabilityInstances.get(instanceId)
  => state.listeners.get(message.event)
  => 只调用该精确事件名下的监听器
```

Stream 错误转换为 `app.capability.error`；存在 `onError` 监听器时逐个调用，否则写入
浏览器控制台。这里的日志文本属于运行日志，不做国际化。

### 6. 释放

网页 `dispose()` 第一次调用时把 `state.active = false`、删除本地句柄和监听器，再发送
`app.capability.dispose`。重复调用直接返回。宿主执行：

```text
open = _instances.remove(instanceId)
open == null => 直接完成
open != null => 取消事件订阅，再 instance.dispose()
```

Bridge reset、WebView 重载、页面退出或 Bridge close 会遍历全部实例执行同样清理，
并最终调用各插件的 `dispose()`。

## 工作区发现与自检调用链

能力开发完成后不需要再注册工作区 API：

```text
GET /dev/api/capabilities
  => gateway.capabilityTests.registry.descriptors
  => 返回全部 CapabilityDescriptor

GET /dev/api/capability-tests
  => registry.plugins
  => descriptor + testable=true + platformAvailable=isAvailable
```

`POST /dev/api/capability-tests` 先经过 Developer Token 和前台 View 中间件，再判断：

```text
codes 缺省或 codes.isEmpty
  => 测试 registry.plugins 全部插件

codes 包含某 code
且 registry.plugin(code) == null
  => 400 未知能力 code

timeoutMs 不是 250..10000 的整数
  => 400

plugin.isAvailable == false
  => status = unavailable，不调用 test()

test() 在 timeout 内完成
  => status = passed

抛 TimeoutException
  => status = timeout

抛 UnsupportedError
  => status = unavailable

其他异常
  => status = failed
```

自检结果不等于用户授权，也不把能力加入游戏声明；它只验证当前 App 平台适配。

交互测试同样不需要为具体能力注册工作区页面。Workspace 从同一描述符递归生成实例
参数表单、每个方法的参数表单和持续事件区：

```text
POST /dev/api/capability-tests/instances
  body = {"code": code, "options": optionsSchema 表单生成的对象}
  -> registry.plugin(code) == null
     => 400 invalid_request
  -> plugin.isAvailable == false
     => 409 capability_unavailable
  -> plugin.create(options)
  -> 返回 instanceId，并订阅 instance.events

POST /dev/api/capability-tests/instances/{instanceId}/invoke
  body = {"method": methodName, "arguments": argumentsSchema 表单生成的对象}
  -> instanceId 不存在
     => 404 not_found
  -> descriptor.methods 中不存在 name == methodName
     => 400 invalid_request
  -> instance.invoke(methodName, arguments)
  -> 返回 result

DELETE /dev/api/capability-tests/instances/{instanceId}
  -> 取消事件订阅
  -> instance.dispose()
```

实例事件只有在 `descriptor.events.any((item) => item.name == event.name)` 时才通过
`capability.test.event` SSE 发给工作区；未声明事件转换为
`capability.test.error`。描述符包含事件时统一显示持续测试；精确声明 `start` /
`stop` 方法时按钮调用对应方法，否则创建即开始接收、停止即释放。关闭弹窗、切换
能力和 Gateway 退出都会释放实例。

表单渲染覆盖对象 `properties/required`、数组 `items`、枚举、布尔、数字、整数和
字符串。参数区不要求手写 JSON；JSON 只用于回显调用结果和事件。插件不得要求
Workspace 按能力 code 写死参数或测试逻辑。

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

平台实现可以位于 Kotlin、Swift、C++ 或 Dart，但必须通过同一个插件接口进入
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
- Android/iOS/桌面支持状态与真实实现一致。
