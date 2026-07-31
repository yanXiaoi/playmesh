# 游戏能力使用指南

Playmesh 只要求游戏声明两类能力：

- WebView 会通过权限回调请求的敏感能力，例如摄像头、麦克风和 MIDI SysEx。
- 由 Playmesh 做原生适配的能力，例如震动和 ARCore 空间位姿。

普通 DOM、触摸、键盘、设备方向和运动传感器等非敏感能力直接使用标准 Web API，
不写入 `capabilities.json`。文件选择必须由用户通过 `<input type="file">` 主动触发，
也不声明能力。

平台插件的实现、注册、版本和测试约定见
[能力开发约定](../platform/capability-development.md)。

## 声明能力

在 `main.json` 同级创建可选的 `capabilities.json`：

```json
{
  "required": [
    "media.camera",
    "media.microphone",
    "device.vibration",
    "sensor.pose6d"
  ],
  "controllerRequired": [
    "device.midi"
  ]
}
```

- `required` 属于主游戏页面。
- `controllerRequired` 只允许单屏多人项目使用，属于控制器页面。
- 显式空数组是有效声明，不会回退或合并另一个角色的能力。
- 未声明 `media.camera`、`media.microphone` 或 `device.midi` 时，App WebView
  会拒绝对应权限请求。
- 能力 code、版本、方法、事件和 Schema 以目标 App 的统一注册表为准。

工作区的新建项目和项目设置可以可视化编辑两组能力。Agent 使用
`GET /dev/api/capabilities` 读取完整注册表。

## Web 权限能力

以下能力可以由游戏直接调用标准 Web API。声明用于让 App WebView 放行对应的敏感
权限请求：

| code | Web API | App 行为 |
| --- | --- | --- |
| `media.camera` | `navigator.mediaDevices.getUserMedia({video: true})` | 声明后放行摄像头权限请求 |
| `media.microphone` | `navigator.mediaDevices.getUserMedia({audio: true})` | 声明后放行麦克风权限请求；另提供原生语音转文字 |
| `device.midi` | `navigator.requestMIDIAccess({sysex: true})` | 声明后放行 MIDI SysEx 权限请求；当前 App 适配状态以注册表为准 |

App 的本地游戏页和加入页使用同一个能力权限注册表。平台注册表按当前页面角色的
`required` 或 `controllerRequired` 把请求资源映射为现有能力 code，再调用该能力
注册的唯一平台授权执行器；所有请求资源都已声明、插件可用且平台授权成功时才放行，
未知资源默认拒绝。普通浏览器不进入 App 权限执行链，仍由浏览器自身决定是否授权。

示例：

```js
const stream = await navigator.mediaDevices.getUserMedia({
  video: true,
  audio: true,
});

const midi = await navigator.requestMIDIAccess({ sysex: true });
```

声明只允许 WebView 继续处理请求，不代表用户已经授予系统权限。游戏必须处理用户
拒绝、设备缺失、系统隐私设置关闭和当前 WebView 不支持等失败。

### 原生语音转文字

`media.microphone@1.1.0` 还提供适合语音命令和短句的跨平台原生识别。`listenFor` 和
`pauseFor` 均为整数秒；`localeId` 必须使用设备语音识别服务支持的语言标识：

```js
const audio = await playmesh.app.capabilities.create("media.microphone");

audio.on("textOnSoundLevelChange", ({ level }) => {
  updateInputLevel(level);
});

audio.on("textOnResult", (result) => {
  renderTranscript(result.recognizedWords, result.finalResult);
});

await audio.invoke("toText", {
  localeId: "zh_CN",
  listenFor: 30,
  pauseFor: 3,
});
```

`textOnResult` 会返回 `recognizedWords`、`finalResult`、`resultType`、置信度信息和
`alternates` 候选项。识别结束或页面退出后释放实例。该功能不用于持续、常驻录音，
系统也可能提前结束识别。

## 多平台原生能力

`device.vibration@2.0.0` 使用 `vibration` 插件做跨平台适配，通过 App SDK 创建实例。
`vibrate` 完整暴露插件参数：`duration`、`pattern`、`repeat`、`intensities`、
`amplitude`、`sharpness` 和 `preset`；省略全部参数时使用插件默认震动：

```js
await playmesh.ready;

if (playmesh.app.capabilities.getAvailable().includes("device.vibration")) {
  const vibration = await playmesh.app.capabilities.create("device.vibration");
  await vibration.invoke("vibrate", { duration: 1000, amplitude: 128 });
  await vibration.invoke("vibrate", {
    pattern: [0, 100, 50, 200],
    intensities: [0, 128, 0, 255],
    repeat: -1,
  });
  await vibration.invoke("vibrate", { preset: "quickSuccessAlert" });
  await vibration.invoke("cancel", {});
  await vibration.dispose();
}
```

`pattern` 与非空 `intensities` 长度必须一致；`repeat` 为 `-1` 或有效的 pattern
索引。`amplitude` 为 `-1`（系统默认）或 `1..255`，iOS `sharpness` 为 `0..1`。
`preset` 会按插件规则覆盖其他震动参数。能力测试只查询设备支持情况，不主动震动。

### Android 空间位姿与按需视频

`sensor.pose6d@1.0.0` 在支持 ARCore 的 Android 终端提供 6DoF 相机位姿。它与原始
加速度计、陀螺仪不同：该能力会使用相机并启动 ARCore，因此必须在当前页面角色中
显式声明，并在创建实例时取得系统相机权限。

```js
await playmesh.ready;

if (playmesh.app.capabilities.getAvailable().includes("sensor.pose6d")) {
  const pose = await playmesh.app.capabilities.create("sensor.pose6d", {
    rateHz: 30,
  });

  const onPose = (frame) => {
    // position 是米制 [x,y,z]；rotation 是 [x,y,z,w] 四元数。
    updateCamera(frame.position, frame.rotation, frame.trackingState);
  };
  pose.addEventListener("pose", onPose);

  // 可选：把当前跟踪位姿设为本实例的游戏原点。
  await pose.invoke("recenter", {});

  // 只有页面确实需要相机画面时才创建并打开媒体源。
  const source = await pose.invoke("openVideo", {
    width: 1280,
    height: 720,
    fps: 30,
  });
  const media = await playmesh.app.media.open(source);
  video.srcObject = media.stream;

  // 不再需要画面；pose 事件仍可继续使用。
  await media.close();

  pose.removeEventListener("pose", onPose);
  await pose.dispose();
}
```

`rateHz` 为 `1..60` 的整数，默认 30。`captureTimestampNs` 是纳秒时间戳字符串；
`trackingState` 为 `tracking`、`paused` 或 `stopped`。每个能力实例拥有独立
`recenter()` 原点；多个实例共享一个 ARCore Session，并由最高请求频率驱动原生采样。

`openVideo()` 返回的是当前页面运行时签发的不透明描述符，不是可请求 URL；
`createVideoSource()` 是同契约的描述性别名。源不能作为 URL 请求，
不能跨页面保存或传给其他终端。`playmesh.app.media.open()` 根据描述符选择已注册媒体
适配器并返回标准 `MediaStream`。当前 Android WebRTC 适配器在同一终端的 WebView 与
原生宿主之间通过既有 App SDK 宿主桥交换一次 offer/answer，不需要额外信令服务器，
也不会开放网络媒体地址。尺寸和帧率是请求偏好，实际图像仍由 ARCore/设备决定。

## 不需要声明的 Web 能力

- 加速度计、陀螺仪、设备方向和运动事件直接使用浏览器提供的 Generic Sensor API、
  Device Orientation API 或 Device Motion API，并先做特性检测。
- `<input type="file">` 和显式文件上传由用户每次主动选择文件，不允许静默读取文件。
- 其他不经过 Playmesh 权限回调、也没有 Playmesh 原生适配器的标准 Web API，
  由浏览器或 WebView 自身的安全策略决定。

这些 API 在不同系统和 WebView 中可能不可用，部分平台还会要求用户手势或系统级
授权。游戏必须提供可玩的降级路径。

## 用户确认与可用性

Game SDK 在每次页面加载时展示当前角色声明的能力：

- 用户拒绝时退出本次游戏加载。
- 声明但当前设备不支持的能力会标记为不可用，不伪造成功实现。
- 授权结果不持久化，也不会写入 Authority 主机或游戏目录。
- 普通浏览器不会因为存在 `playmesh.app` 安全空实现而获得 App 原生能力。

## 自检

开发者工作区“更多 → 能力测试”读取全平台注册表并调用各插件自己的 `test()`。
摄像头和 MIDI 插件的自检只报告适配状态，不主动弹系统权限或访问设备。音频插件的
自检只报告语音转文字接口可用性；`sensor.pose6d` 自检只报告 ARCore 安装与设备支持
状态。实际权限在创建实例或开始识别时由系统处理。

```text
GET  /dev/api/capability-tests
POST /dev/api/capability-tests
POST /dev/api/capability-tests/instances
POST /dev/api/capability-tests/instances/{instanceId}/invoke
DELETE /dev/api/capability-tests/instances/{instanceId}
```

能力自检用于确认当前 App/设备适配器状态，不替代游戏业务测试或真机体验验收。
