# 能力插件开发

Playmesh 的平台能力是编译期注册的有状态插件。通用运行时只理解“创建实例、调用方法、接收事件、释放实例”，不会假设能力一定是传感器订阅，也不会为麦克风、MIDI、USB 等设备维护统一数据转换。

## 目录与职责

每个能力使用独立目录：

```text
lib/core/capabilities/
  capability_plugin.dart          # 插件、实例和描述符接口
  capability_registry.dart        # 全平台注册表
  capability_runtime.dart         # 项目声明、确认、实例生命周期和 Bridge 路由
  default_capability_plugins.dart # 编译期注册入口
  {capability}/                    # 一个能力一个目录
    {capability}_capability_plugin.dart
  support/                         # 仅放多个插件真正共享的底层组件
```

插件必须在同一实现中提供：

- 唯一稳定 code 和独立 `apiVersion`；
- 名称、说明、App/HTML 状态；
- 创建参数、方法参数/返回值、事件数据的 JSON Schema；
- 方法是否要求用户主动触发；
- `create()` 创建的有状态实例；
- `test()` 平台自检；
- `dispose()` 底层资源释放。

Flutter 不支持可靠的运行时目录扫描，因此新增插件后需要在 `default_capability_plugins.dart` 增加一项构造注册。这是唯一集中注册点；不要再修改工作区测试列表、SDK 弹窗或另建 adapter 映射。

## 实例协议

宿主 Bridge 固定使用：

```text
app.capability.create
app.capability.invoke
app.capability.dispose
app.capability.event
app.capability.error
```

网页固定使用：

```js
const instance = await playmesh.app.capabilities.create(code, options);
const off = instance.on(event, callback);
instance.onError(reportError);
const result = await instance.invoke(method, args);
off();
await instance.dispose();
```

具体的 method、event、参数和返回值只由插件 `apiVersion` 契约定义。例如传感器插件提供 `start/stop + reading`；未来语音转写插件可以把 `start` 标为需要用户主动触发，`stop` 完成录音和本地识别后直接异步返回字符串。通用层无需新增命令或设备类型分支。

## 注册表、项目声明与测试

- `GET /dev/api/capabilities` 返回全平台注册表及完整插件描述符。
- Agent 提示词只写入全量注册表 API 和 GET/POST 测试 API，由 Agent 按需读取最新契约与执行结果，不直接内嵌全量声明。
- 对话提示词只附带当前项目 `capabilities.json.required` 已勾选插件的完整描述符；工作区“复制全平台能力”可单独复制注册表 API 的全部结果。
- 开发者工作区的新建项目和项目设置从注册表生成选项；保存结果写入该项目的 `capabilities.json.required`。
- 工作区“能力测试”始终显示全平台注册表并调用每个插件自己的 `test()`，不按当前项目声明过滤。
- 游戏运行时只允许创建已经声明、用户本次确认且当前设备可用的插件。
- 权限确认仍按能力 code 每次加载统一执行；插件内部可在要求用户主动触发的方法中再启动录音、系统选择器等敏感操作。

## 当前插件

| code | 插件 API | 创建参数 | 方法 | 事件 |
|---|---:|---|---|---|
| `sensor.accelerometer` | `1.0.0` | `{fps: 1..120}` | `start`, `stop` | `reading` |
| `sensor.gyroscope` | `1.0.0` | `{fps: 1..120}` | `start`, `stop` | `reading` |

两种传感器分别位于独立目录，共享 `support/` 中的运动采样基础设施。同种插件的多个实例共享一条原生流，并按最高请求频率采样；最后一个实例停止或释放后关闭原生流。
