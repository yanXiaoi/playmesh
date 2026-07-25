# 游戏能力使用指南

Playmesh 的设备能力通过有状态插件提供。游戏只能使用当前页面角色已经在
`capabilities.json` 声明、用户本次确认且当前设备可用的能力。

平台插件的实现、注册、版本和测试约定见
[能力开发约定](../platform/capability-development.md)。

## 声明能力

在 `main.json` 同级创建可选的 `capabilities.json`：

```json
{
  "required": [
    "sensor.accelerometer",
    "device.vibration"
  ],
  "controllerRequired": [
    "sensor.gyroscope"
  ]
}
```

- `required` 属于主游戏页面。
- `controllerRequired` 只允许单屏多人项目使用，属于控制器页面。
- 显式空数组是有效声明，不会回退或合并另一个角色的能力。
- 能力 code、版本、方法、事件和 Schema 以目标 App 的统一注册表为准。

工作区的新建项目和项目设置可以可视化编辑两组能力。Agent 使用
`GET /dev/api/capabilities` 读取完整注册表。

## 用户确认与可用性

Game SDK 在每次页面加载时展示当前角色所需能力：

- 用户拒绝时退出本次游戏加载。
- 声明但当前设备不支持的能力会标记为不可用，不伪造成功实现。
- 授权结果不持久化，也不会写入 Authority 主机或游戏目录。
- 普通浏览器不会因为存在 `playmesh.app` 安全空实现而获得 App 原生能力。

## 创建和释放实例

```js
await playmesh.ready;

if (!playmesh.app.isAvailable()) {
  // 普通浏览器降级逻辑。
}

const sensor = await playmesh.app.capabilities.create(
  "sensor.accelerometer",
  { fps: 30 },
);

const offReading = sensor.on("reading", (sample) => {
  console.log(sample.x, sample.y, sample.z);
});

sensor.onError((error) => {
  console.error("传感器错误", error);
});

await sensor.invoke("start");

// 页面业务结束时：
await sensor.invoke("stop");
offReading();
await sensor.dispose();
```

具体 method、event 和参数不能靠猜测，应读取注册表描述符或 `.d.ts`。

## 当前内置能力

| code | 插件 API | 创建参数 | 方法 | 事件 |
| --- | ---: | --- | --- | --- |
| `sensor.accelerometer` | `1.0.0` | `{fps: 1..120}` | `start`, `stop` | `reading` |
| `sensor.gyroscope` | `1.0.0` | `{fps: 1..120}` | `start`, `stop` | `reading` |
| `device.vibration` | `1.0.0` | `{}` | `vibrate` | 无 |

示例震动：

```js
const vibration = await playmesh.app.capabilities.create("device.vibration");
await vibration.invoke("vibrate", { style: "light" });
await vibration.dispose();
```

支持的 `style` 以注册表 Schema 为准。平台能力测试不会主动持续震动。

## 游戏侧约定

- 创建前先等待 `playmesh.ready`。
- 不直接调用传感器插件、MethodChannel、ArkTS/Kotlin/Swift 或浏览器私有接口。
- 不把“已声明”当成“当前设备可用”。
- 不复制平台能力确认 UI。
- 每个实例都必须释放；页面退出时平台会兜底，但游戏仍应主动停止业务订阅。
- Authority 不能信任玩家上传的传感器数据作为无需验证的最终结果。
- 页面应为能力不可用、用户拒绝和运行中错误提供可玩的降级路径。

## 自检

开发者工作区“更多 → 能力测试”读取全平台注册表并调用插件自己的 `test()`。
Agent 可使用：

```text
GET  /dev/api/capability-tests
POST /dev/api/capability-tests
```

能力自检用于确认当前 App/设备适配器状态，不替代游戏业务测试或真机体验验收。
