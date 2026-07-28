# 游戏包与 main.json

## 安装目录

每个已安装游戏使用一个稳定目录：

```text
playmesh-library/
  packages/
    {gameId}/
      main.json
      icon.png                # 可选，游戏列表图片
      capabilities.json        # 可选，游戏必需平台能力
      app/
        index.html
        controller/index.html
        static/...
      data/
        json/
          {bucket}.json
        data/
          {bucket}/
            {timestamp-ms}.{ext}
      cache/
        developer/local-history/...
  public/
    sdk/v1/playmesh.js
    sdk/v1/playmesh-app.js
    sdk/v1/playmesh.d.ts
    sdk/v1/playmesh-app.d.ts
    avatars/...
```

Android 与 iOS 使用系统应用支持目录中的 `playmesh-library`。所有非移动端使用当前运行可执行文件同级的 `playmesh-library`，不得放入 AppData 等用户应用支持目录。开发者工作区项目与正式项目都直接使用 `packages/{gameId}/`。

`packages/{gameId}/` 下不再增加版本层或 `files/` 层。`main.json` 中的 `id` 必须和 `{gameId}` 目录名一致。

## 公开资源边界

- `app/` 是当前游戏的发布资源映射目录，对应 `/app/...`。
- `playmesh-library/public/` 是平台公共资源目录，对应 `/playmesh/...`。
- `data/` 与 `app/` 同级。只有 `data/data` 中由 SDK 上传的文件按原 Bucket 映射为 `/bucket/{bucket}/{file}`；`data/json` 永远私有，`/bucket` 不允许目录枚举或路径穿越。
- `cache/` 与 `app/`、`data/` 同级，由平台管理，同样不参与静态映射。
- 游戏不能读取其他包、用户资料或 App 私有文件。
- SDK 固定从 `/playmesh/sdk/v1/playmesh.js` 引入，禁止使用 `../../../sdk/...` 一类跨目录路径。

## 发布包结构

游戏发布包只包含 `main.json`、可选根 `icon.png`、可选 `capabilities.json` 和 `app/`：

```text
game-package/
  main.json
  icon.png
  capabilities.json
  app/
    index.html
    controller/index.html
    static/...
```

`data/`、`cache/` 和原始安装压缩包不参与分享。App 安装目录不创建 CLI 辅助目录；CLI 本地开发副本保留包内 `app/` 并直接映射 `/app/`，使用 `playmesh/` 映射平台公共 `/playmesh/` URL 空间。安装时先在临时目录解压和校验，再原子移动到 `packages/{gameId}/`。卸载游戏删除整个游戏目录；“清除游戏数据”只删除该目录下的 `data/`，“清除缓存”则删除 `cache/` 及其中的开发历史。

## main.json 示例

```json
{
  "id": "com.example.party-game",
  "name": "派对游戏",
  "author": "当前 App 昵称",
  "lastModifiedAt": 1784851200000,
  "remarks": "示例游戏",
  "version": "1.0.0",
  "sdkVersion": "3.0.0",
  "appSdkVersion": "3.0.0",
  "orientation": "landscape",
  "controllerOrientation": "portrait",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": { "min": 2, "max": 6 },
  "entries": {
    "game": "app/index.html",
    "controller": "app/controller/index.html"
  },
  "authority": { "entry": "app/static/js/service/index.js" },
  "tags": ["party", "example"]
}
```

## 字段规则

| 字段 | 必填 | 规则 |
|---|---|---|
| `id` | 是 | 1–64 个 ASCII 字符；首字符为字母或数字，后续只能是字母、数字、点、下划线或连字符；必须等于安装目录名 |
| `name` | 是 | 非空展示名称 |
| `author` | 新发布必有，旧包可缺省 | 上传时由平台写入当前 App 设置昵称，只读；缺省时数据保持空值，App 外壳显示本地化“未知发布者”；非空值逐字显示 |
| `lastModifiedAt` | 新发布必有，旧包可缺省 | 最后上传的 Unix 毫秒时间戳，只读；缺省由 App 外壳显示本地化“无”，有值时按设备本地时区显示 |
| `remarks` | 否 | 游戏简介，缺省为空字符串 |
| `version` | 是 | `MAJOR.MINOR.PATCH` |
| `sdkVersion` | 是 | `MAJOR.MINOR.PATCH`；Game SDK 当前为 `3.0.0` |
| `appSdkVersion` | 否 | `MAJOR.MINOR.PATCH`；App Bridge SDK 当前为 `3.0.0`；CLI 发布时总会写入当前值 |
| `orientation` | 是 | `landscape` 或 `portrait` |
| `controllerOrientation` | 单屏多人必填 | 控制器全屏方向；其他显示模式禁止声明 |
| `modes` | 是 | 单元素数组，值为 `solo` 或 `multiplayer` |
| `displayModes` | 是 | 单元素数组，值为 `multi_screen` 或 `single_screen_multiplayer` |
| `players` | 是 | 整数，满足 `1 <= min <= max` |
| `entries` | 否 | 页面入口对象；`game`、`controller` 分别默认 `app/index.html`、`app/controller/index.html` |
| `authority` | 多人必填 | `entry` 必须位于当前包的 `app/` 内 |
| `tags` | 否 | 字符串数组，平台原样保存和展示 |

补充校验：

- `entries.game` 与 `entries.controller` 必须指向当前包 `app/` 内的 `.html` 文件；不能是 URL、绝对路径、带查询/片段的路径或越界路径。
- `authority.entry` 必须指向当前包 `app/` 内的 `.js` 或 `.mjs` 文件。
- `modes` 必须且只能声明一个模式；值为 `multiplayer` 时必须声明 `authority.entry`。
- `modes` 为 `solo` 时，`players.max` 不能大于 1。
- `displayModes` 必须且只能声明一个显示模式。
- 声明 `single_screen_multiplayer` 时必须提供 `entries.controller` 解析出的文件。
- 包内路径使用 `/`，不能是绝对路径、URL、反斜杠路径或包含空段、`..`。
- 文件名固定为 `main.json`，不使用 `manifest.json`。
- 游戏列表唯一自定义图标是包根目录可选 `icon.png`；`main.json` 不定义图标字段。
  读取额外字段不赋予其语义，规范化保存、CLI 重写、导入和导出都会移除
  `icon`。
- `icon.png` 只允许 PNG，最大 2 MiB；解码失败、超限或尺寸异常时忽略并显示默认
  图标，不能阻断游戏包导入或运行。
- `main.json` 不定义 `permissions`。WebView 会拦截的敏感权限，以及 Playmesh 已做
  多平台原生适配的能力，只在同级 `capabilities.json` 按需声明。普通 DOM、触摸、
  键盘、运动传感器和文件选择等标准 Web API 不依赖清单字段。读取额外字段不赋予
  其语义，规范化保存、CLI 重写、导入和导出都会移除 `permissions`。

## capabilities.json

需要受保护平台能力的游戏在 `main.json` 同级创建该可选文件；没有文件或 `required` 为空时，启动不弹能力确认：

```json
{
  "required": [
    "media.camera",
    "media.microphone",
    "device.vibration"
  ],
  "controllerRequired": [
    "device.midi"
  ]
}
```

- `required` 只授权 `entries.game` 主画面；`controllerRequired` 只授权 `entries.controller` 控制器。任一角色声明为空时不弹能力确认，也不会回退读取另一角色的声明。
- `controllerRequired` 仅允许用于 `single_screen_multiplayer`，其他模式声明会校验失败。

- `media.camera`、`media.microphone` 和 `device.midi` 是 WebView 权限声明：
  游戏直接调用标准 Web API，App 只在权限回调中核对当前角色是否声明，未声明即拒绝。
  三个能力各自拥有独立插件；`media.microphone@1.1.0` 另提供原生语音转文字方法和
  事件，其他原生扩展继续在对应插件内增加。
- `device.vibration` 是多平台原生适配能力，游戏通过 App SDK 创建实例并调用。
- 平台统一能力插件注册表把每个 code 映射为中文名、用途、`apiVersion`、方法、事件以及 App/HTML 适配状态。能力确认弹窗、开发者工作区的新建/项目设置选项和能力声明校验均以该注册表为准；工作区能力测试展示全平台注册表并调用各插件自带的自检，不按当前项目声明过滤。
- 主 SDK 在 App WebView 和普通浏览器每次加载游戏时展示全部所需能力。用户只能“同意并进入”或“拒绝并退出”；授权结果不写入房主或本机文件。
- 加速度计、陀螺仪和设备方向直接使用浏览器标准 API，不声明能力；文件选择通过
  `<input type="file">` 由用户主动选择，同样不声明能力。游戏必须先做特性检测，
  并在 WebView、来源或系统不支持时保持主流程可玩。

## 屏幕方向

游戏必须声明主画面 `orientation`；单屏多人还必须声明 `controllerOrientation`。App 在创建 WebView 前按当前角色应用方向，SDK 进入全屏时把方向传给原生宿主；普通浏览器使用 Fullscreen API 后尽力调用 Screen Orientation API。浏览器可能拒绝锁定，游戏页面仍须使用响应式布局。离开游戏后恢复系统方向。

## 存储目录

Bucket 数据分为私有 JSON 与运行时文件：

```text
packages/{gameId}/data/json/{bucket}.json
packages/{gameId}/data/data/{bucket}/{timestamp-ms}.{ext}
```

游戏必须通过 `playmesh.storage.getBucket()` 访问数据。平台不添加 `{userId}` 层，且浏览器或其他 App 玩家不会创建本地副本。运行时仅把 `data/data` 文件映射到 `/bucket/{bucket}/{file}`；`data/json` 保持私有且 `/bucket` 不提供目录枚举。

## 缓存与开发历史

开发者本地历史写入：

```text
packages/{gameId}/cache/developer/local-history/
```

该目录由平台管理，不属于发布包，也不能通过游戏 URL 或开发者普通文件 API 访问。历史采用初始基线加逐时间操作的变更后快照；连续变更按 5 分钟滚动窗口合并，默认最多保留 100 个操作。最旧操作被淘汰时，其变更后快照提升为新基线。

历史只覆盖游戏发布文件，排除 `data/` 和 `cache/`。整包恢复会同时恢复
`main.json`、可选 `icon.png`、`capabilities.json` 与 `app/`。清除游戏数据不会
删除历史；清除缓存会删除历史；卸载游戏会随整个游戏目录一起删除。

## 扫描与安装校验

游戏库在 App 启动、恢复、导入或删除后扫描 `packages/`。游戏库页面右上角提供“重新扫描游戏库”按钮，新增游戏后不要求重启 App。扫描在后台执行：当前列表继续使用旧缓存，扫描成功后才原子替换。单个项目只要 `main.json` 能解析出符合上述共享规则的 `id`，即使其他字段或入口损坏，也必须以“待修复”状态保留，不能阻断 App 或开发者工作区；运行、正式导入和发布仍执行完整校验。可恢复扫描只保留原始 `remarks` 和机器状态，不向游戏简介、显示模式或状态字段写入本地化文案；当 `remarks` 为空时，由 App UI 使用统一语言包显示修复说明。无法解析 JSON 或没有合法 `id` 的目录只记录诊断并跳过。

App 级游戏库仓库缓存排序后的清单元数据、搜索文本、`revision` 和 `refreshedAt`。最近打开时间只存于包外的 `playmesh-library/cache/app/game-library.json`，每个游戏 ID 只保留一个 Unix 毫秒值，打开时覆盖，删除游戏时同步删除，并硬性限制最多 2048 条、超限淘汰最旧记录；该文件不参与导入、导出、项目历史或游戏 URL 映射。游戏库默认按最近打开时间倒序，未打开项目排在最后并按名称稳定排序。同一时间的重复刷新复用一个扫描任务，并提供按关键字、`offset`、`limit` 查询缓存的接口，供后续搜索和分页直接使用。安装器至少拒绝：

Android 系统分享为每个任务创建唯一临时 ZIP 租约，并在下次分享或 App 启动时清理
已释放的旧租约，避免系统接收端尚未打开 URI 就提前删除。普通导入、在线下载和
Developer Gateway 中转使用各自受控的临时路径，可按入口串行并在 `finally` 清理；
所有路径都必须有容量边界和遗留清理，不能无限累积随机中转文件。

- `../`、绝对路径、链接文件和越界解压。
- 缺少 `main.json`、`entries.game` 解析出的游戏首页、大屏控制器入口或多人 Authority 文件。
- 清单 ID 与目录名不一致。
- 不合法的方向、模式、人数、版本或 Authority 路径。
- 安装脚本、原生动态库、压缩炸弹和超过限制的文件。

## 应用导入与导出

应用游戏库只导入 Playmesh ZIP 游戏包，不把任意 HTML 目录识别为可安装游戏。压缩包
根目录必须直接包含 `main.json` 和 `app/`，不能外包一层目录；内容只允许根
`main.json`、可选 `icon.png`、可选 `capabilities.json` 与 `app/**`。完整 HTML
小游戏应进入开发者工作区，通过上传、ZIP 解压、移动、复制和粘贴整理，再由项目
校验确认结构。

当前导入限制为：压缩文件 64 MiB、解压总量 256 MiB、单文件 32 MiB、文件数
4096。导入拒绝绝对路径、目录穿越、重复路径、符号链接、系统脚本、可执行文件与
原生动态库。`main.json.id` 不存在时新增游戏；同 ID 已存在时只原子替换
`main.json`、可选 `icon.png`、`capabilities.json` 与 `app/`，不覆盖或移动
`data/`、`cache/` 和其他运行内容，失败会恢复旧发布文件。网页、Agent 和 CLI
发布均经过同一开发者本地历史事务，不能绕过恢复链路。安装过程不创建实体
`.playmesh/` 元数据目录。

导出只打包当前安装目录的 `main.json`、可选 `icon.png`、可选
`capabilities.json` 与 `app/`，明确排除 `data/` 和 `cache/`。游戏详情页输出
`{游戏名称}-v{版本}.zip`，导出的包可再次导入并保持清单与入口一致；CLI
`push/dev` 使用相同发布边界。
