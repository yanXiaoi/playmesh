# 游戏包与 main.json

## 安装目录

每个已安装游戏使用一个稳定目录：

```text
playmesh-library/
  packages/
    {gameId}/
      main.json
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

游戏发布包只包含 `main.json`、可选 `capabilities.json` 和 `app/`：

```text
game-package/
  main.json
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
  "icon": "app/static/image/icon.png",
  "id": "com.example.party-game",
  "name": "派对游戏",
  "author": "当前 App 昵称",
  "lastModifiedAt": 1784851200000,
  "remarks": "示例游戏",
  "version": "1.0.0",
  "sdkVersion": "2.2.2",
  "appSdkVersion": "2.1.1",
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
  "tags": ["party", "example"],
  "permissions": ["keyboard"]
}
```

## 字段规则

| 字段 | 必填 | 规则 |
|---|---|---|
| `id` | 是 | 非空稳定标识；必须等于安装目录名 |
| `name` | 是 | 非空展示名称 |
| `author` | 新发布必有，旧包可缺省 | 上传时由平台写入当前 App 设置昵称，只读；缺省显示“佚名” |
| `lastModifiedAt` | 新发布必有，旧包可缺省 | 最后上传的 Unix 毫秒时间戳，只读；缺省显示“无”，有值时按设备本地时区显示 |
| `remarks` | 否 | 游戏简介，缺省为空字符串 |
| `version` | 是 | `MAJOR.MINOR.PATCH` |
| `sdkVersion` | 是 | `MAJOR.MINOR.PATCH`；Game SDK 当前为 `2.2.2` |
| `appSdkVersion` | 否 | `MAJOR.MINOR.PATCH`；App Bridge SDK 当前为 `2.1.1`；CLI 发布时总会写入当前值 |
| `orientation` | 是 | `landscape` 或 `portrait` |
| `controllerOrientation` | 单屏多人必填 | 控制器全屏方向；其他显示模式禁止声明 |
| `modes` | 是 | 单元素数组，值为 `solo` 或 `multiplayer` |
| `displayModes` | 是 | 单元素数组，值为 `multi_screen` 或 `single_screen_multiplayer` |
| `players` | 是 | 整数，满足 `1 <= min <= max` |
| `entries` | 否 | 页面入口对象；`game`、`controller` 分别默认 `app/index.html`、`app/controller/index.html` |
| `authority` | 多人必填 | `entry` 必须位于当前包的 `app/` 内 |
| `icon` | 否 | 当前包内 `app/` 路径 |
| `tags` | 否 | 字符串数组，平台原样保存和展示 |
| `permissions` | 否 | 保留给键盘等既有 App 输入声明；传感器等必需能力改用同级 `capabilities.json` |

补充校验：

- `entries.game` 与 `entries.controller` 必须指向当前包 `app/` 内的 `.html` 文件；不能是 URL、绝对路径、带查询/片段的路径或越界路径。
- `authority.entry` 必须指向当前包 `app/` 内的 `.js` 或 `.mjs` 文件。
- `modes` 必须且只能声明一个模式；值为 `multiplayer` 时必须声明 `authority.entry`。
- `modes` 为 `solo` 时，`players.max` 不能大于 1。
- `displayModes` 必须且只能声明一个显示模式。
- 声明 `single_screen_multiplayer` 时必须提供 `entries.controller` 解析出的文件。
- 包内路径使用 `/`，不能是绝对路径、URL、反斜杠路径或包含空段、`..`。
- 文件名固定为 `main.json`，不使用 `manifest.json`。
- `permissions` 保留给键盘等既有输入声明；传感器及后续受保护设备能力使用 `capabilities.json`。两者都不会关闭浏览器自身的 DOM、触摸、键盘或浏览器原生权限 API。

## capabilities.json

需要受保护平台能力的游戏在 `main.json` 同级创建该可选文件；没有文件或 `required` 为空时，启动不弹能力确认：

```json
{
  "required": [
    "device.vibration"
  ],
  "controllerRequired": [
    "sensor.accelerometer",
    "sensor.gyroscope"
  ]
}
```

- `required` 只授权 `entries.game` 主画面；`controllerRequired` 只授权 `entries.controller` 控制器。任一角色声明为空时不弹能力确认，也不会回退读取另一角色的声明。
- `controllerRequired` 仅允许用于 `single_screen_multiplayer`，其他模式声明会校验失败。

- 能力 ID 与实现环境解耦。当前两个传感器能力由 App 适配器提供；未来摄像头、麦克风等通用能力可由 App 和 HTTPS 浏览器分别实现同一 ID。
- 平台统一能力插件注册表把每个 code 映射为中文名、用途、`apiVersion`、方法、事件以及 App/HTML 适配状态。能力确认弹窗、开发者工作区的新建/项目设置选项和能力声明校验均以该注册表为准；工作区能力测试展示全平台注册表并调用各插件自带的自检，不按当前项目声明过滤。
- 主 SDK 在 App WebView 和普通浏览器每次加载游戏时展示全部所需能力。用户只能“同意并进入”或“拒绝并退出”；授权结果不写入房主或本机文件。
- 普通浏览器当前局域网 HTTP 分享不可靠支持运动传感器，因此这两个能力显示“本平台暂不支持”。该标记不阻止用户同意后进入，游戏必须在能力不可用时保持主流程可玩。

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

历史只覆盖游戏发布文件，排除 `data/` 和 `cache/`。整包恢复会同时恢复 `main.json`、`capabilities.json` 与 `app/`。清除游戏数据不会删除历史；清除缓存会删除历史；卸载游戏会随整个游戏目录一起删除。

## 扫描与安装校验

游戏库在 App 启动、恢复、导入或删除后扫描 `packages/`。游戏库页面右上角提供“重新扫描游戏库”按钮，新增游戏后不要求重启 App。扫描在后台执行：当前列表继续使用旧缓存，扫描成功后才原子替换。单个项目只要 `main.json` 能解析出非空 `id`，即使其他字段或入口损坏，也必须以“待修复”状态保留，不能阻断 App 或开发者工作区；运行、正式导入和发布仍执行完整校验。无法解析 JSON 或没有有效 `id` 的目录只记录诊断并跳过。

App 级游戏库仓库缓存排序后的清单元数据、搜索文本、`revision` 和 `refreshedAt`。最近打开时间只存于包外的 `playmesh-library/cache/app/game-library.json`，每个游戏 ID 只保留一个 Unix 毫秒值，打开时覆盖，删除游戏时同步删除，并硬性限制最多 2048 条、超限淘汰最旧记录；该文件不参与导入、导出、项目历史或游戏 URL 映射。游戏库默认按最近打开时间倒序，未打开项目排在最后并按名称稳定排序。同一时间的重复刷新复用一个扫描任务，并提供按关键字、`offset`、`limit` 查询缓存的接口，供后续搜索和分页直接使用。安装器至少拒绝：

导入、导出、在线下载和 Developer Gateway 包传输使用各自固定名称的临时 ZIP；每次操作前删除或覆盖旧文件，完成后清理。并发入口必须串行复用固定文件，不能按操作生成无限增长的随机中转文件。

- `../`、绝对路径、链接文件和越界解压。
- 缺少 `main.json`、`entries.game` 解析出的游戏首页、大屏控制器入口或多人 Authority 文件。
- 清单 ID 与目录名不一致。
- 不合法的方向、模式、人数、版本或 Authority 路径。
- 安装脚本、原生动态库、压缩炸弹和超过限制的文件。

## 应用导入与导出

应用游戏库只导入 Playmesh ZIP 游戏包，不把任意 HTML 目录识别为可安装游戏。压缩包根目录必须直接包含 `main.json` 和 `app/`，不能外包一层目录；内容只允许根 `main.json`、可选 `capabilities.json` 与 `app/**`。完整 HTML 小游戏应进入开发者工作区，通过上传、ZIP 解压、移动、复制和粘贴整理，再由项目校验确认结构。

当前导入限制为：压缩文件 64 MiB、解压总量 256 MiB、单文件 32 MiB、文件数 4096。导入拒绝绝对路径、目录穿越、重复路径、符号链接、系统脚本、可执行文件与原生动态库。`main.json.id` 不存在时新增游戏；同 ID 已存在时只原子替换 `main.json`、`capabilities.json` 与 `app/`，不覆盖或移动 `data/`、`cache/` 和其他运行内容，失败会恢复旧发布文件。网页、Agent 和 CLI 发布均经过同一开发者本地历史事务，不能绕过恢复链路。安装过程不创建实体 `.playmesh/` 元数据目录。

导出只打包当前安装目录的 `main.json`、可选 `capabilities.json` 与 `app/`，明确排除 `data/` 和 `cache/`。游戏详情页建议输出 `{游戏名称}-v{版本}.zip`，导出的包可再次导入并保持清单与入口一致；CLI `push/dev` 使用相同发布边界，直接上传本地 `app/`。
