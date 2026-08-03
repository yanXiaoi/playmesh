# Playmesh 下一版本临时更新日志

## 状态

- 状态：`4.1.0+27` 已于 2026-08-03 正式发布；当前没有未发布变更。
- 当前发行基线：App `4.1.0+27`、Go Core `0.5.0`、Core 协议 `1.3.0`、
  Game SDK `4.0.0`、App Bridge SDK `3.2.0`、Catalog API `3.0.0`、
  Relay 协议 `3.0.0`、Developer API / OpenAPI `4.1.0`、Developer CLI `2.0.0`。
- 最新正式发布日志：`docs/version/4.1.0.md`；本文件保留 4.1.0 与 4.0.0 发布归档。

## 4.1.0 发布归档

- 根 `README.md` 改为完整英文默认入口，原中文内容保留为 `README.zh-CN.md`，两者在
  顶部互链；`docs/` 继续作为中文权威资料，不建立英文镜像。
- AI 提示词模板按全局 locale 分入
  `assets/playmesh-library/public/developer/prompts/{locale}/`，同一清单为全局语言配置中
  每个启用 locale 声明完整模板映射。英文版覆盖 ChatAI、AgentAI、单机、多人及两种
  显示模式，中文模板内容保持不变。
- 提示词不再维护 App 级文案或第二份 locale/fallback 配置。模板名称、分类、动态标题、
  说明和能力描述统一读取全局 `app.json`；默认 locale、启用语言和 fallback 统一读取
  `assets/playmesh-localization/manifest.json`。Dart/JavaScript 只保留公共解析与拼装逻辑。
- Developer API / OpenAPI 兼容升级到 `4.1.0`：提示词模板列表、保存、恢复和项目提示词
  导出接受可选 BCP 47 `locale` 查询参数，返回解析后的 locale；未精确命中时按全局语言
  清单选择同语言资源或 default locale。不同 locale 的用户模板覆盖相互隔离。
- Developer Workspace 自动把当前 App locale 传给模板与项目提示词接口。新增语言只需
  补齐全局语言声明、对应 `app.json`、提示词语言目录、清单映射和 Flutter 资产目录，
  不修改提示词业务代码。

## 4.0.0 发布归档

- 游戏包物理结构继续保留根 `main.json`、可选 `capabilities.json`、可选
  `icon.png` 与 `app/`，外层物理 `app/` 直接挂载为运行时 `/`。清单入口使用
  `index.html`、`controller/index.html`、`static/js/service/index.js` 这类相对于
  外层 `app/` 的路径；用户首段 `app` 合法，例如入口 `app/index.html` 对应物理
  `app/app/index.html` 和运行时 `/app/index.html`，但不会别名到外层
  `app/index.html`。
- 所有游戏必须显式声明 `entries.game`；`single_screen_multiplayer` 必须显式声明
  `entries.controller`；`multiplayer` 必须显式声明 `authority.entry`。运行时只按
  清单实际值解析，缺失字段直接拒绝，不硬编码模板路径回退。
- `entries.game` 与 `entries.controller` 现统一支持 `relative.html?query`；物理包
  校验只使用 `?` 前路径，本地 CLI/App 保留查询参数段顺序、重复键与编码值语义。
  页面查询仅是自定义启动配置；App 身份、昵称、能力和 Core 地址统一由标准 App SDK
  通过原生 Bridge 调用 Dart `app.bootstrap` 获取，不再使用 App 模式、SDK URL 或
  昵称查询参数。go-server 云分发上传会对
  查询串递归 URL 解码并执行外链主动内容扫描；`authority.entry` 仍禁止查询串。
- 局域网邀请改为 `/playmesh/join#inviteToken=...` 两段式握手：落地页以 POST
  交换短期 HttpOnly Cookie 后重定向到 manifest 完整入口。最终游戏 URL 不再追加
  或覆盖 `channelId/token`，普通浏览器和 App WebView 使用同一协议。
- Game SDK 升级到 `4.0.0`，App Bridge SDK 升级到 `3.2.0`。公共游戏域只位于
  `playmesh.main.*`，当前客户端域只位于 `playmesh.app.*`；locale 固定为
  `playmesh.app.runtime.getLocale()`，性能固定为 `playmesh.app.performance.*`，
  不存在 `playmesh.main.performance`。面向游戏开发者的唯一全局对象是
  `window.playmesh`，其根级公开成员严格只有 `ready`、`main` 与 `app`；
  `window.playmeshApp` 与公开 `__*` 内部桥接均被删除，内部协作改为不可枚举的私有
  `Symbol` runtime。`main.ready` 内部先等待 `app.ready`，根 `playmesh.ready`
  只复用这条初始化链并返回 `{main, app}`。运行文件成对改为
  `/playmesh/sdk/v1/playmesh-main.js` 与
  `/playmesh/sdk/v1/playmesh-app.js`，类型文件成对改为 `playmesh-main.d.ts` 与
  `playmesh-app.d.ts`；旧 `playmesh.js` 和旧 Game 类型文件均不兼容、不回退。
- 性能浮层唯一由 App SDK 创建和维护；Game SDK 的旧浏览器性能 panel 已删除。
- `main.json.sdkVersion` 只接受 `4.0.0`，`appSdkVersion` 只接受 `3.2.0`；
  旧值、未知值或格式错误值直接拒绝，不解析旧清单版本，也不提供版本回退或旧命名空间
  shim。
- `/playmesh/**` 与 `/bucket/**` 成为唯一平台保留命名空间。App、CLI 与 Go Server
  统一拒绝物理 `app/playmesh/`、`app/bucket/` 的大小写变体，以及百分号编码、
  反斜杠、空段、`.`、`..` 和符号链接绕过；游戏/控制器入口只允许 `.html`，
  Authority 入口只允许 `.js/.mjs`。`app` 不属于保留名，物理 `app/app/**` 和
  运行时 `/app/**` 均按普通用户资源处理。
- App 只区分正式已安装游戏资源和临时开发资源，二者共用
  `GameWebResourceSource` / `GameWebResourceProvider` 接口。游戏 WebView、局域网
  分享和开发运行复用同一资源边界；开发态只把普通路径代理到固定开发源，
  `/playmesh/**`、`/bucket/**` 仍由 App 本地处理，并支持 GET、HEAD 与保留
  WebSocket 子协议。在开发资源链路中，Developer Gateway 位于控制面，负责建立和
  撤销开发会话；页面资源请求仍经 `GameAssetGateway` 与开发 Provider 转发。主机/
  加入端、浏览器/App、局域网/公共中转是正交的共享与传输维度，不改变资源源类型。
- 游戏启动全屏改为入口显式策略：游戏库详情与首页快速游戏固定全屏；开发者工作区、
  CLI `run` 和 CLI `dev` 在 Android/iOS 手持端仍全屏并应用方向，在 Windows、
  macOS、Linux 桌面端默认窗口化；控制器/加入端继续默认全屏。SDK 后续主动切换
  全屏的能力不受限制，退出窗口化开发页时会清理 SDK 临时进入的全屏状态。
- Developer API 升级到 `4.0.0`，新增
  `GET/POST/DELETE /dev/api/projects/{projectId}/development`。开发会话绑定项目、
  当前 CLI 来源、一次性凭据与最长 24 小时有效期，只驻留内存；重复 `dev`、正式
  `run/restart`、DELETE 和到期清理按 `runId` 串行，替换前关闭旧页面、资源网关及
  既有 WebSocket，停止失败保留可重试句柄。
- Developer CLI 升级到 `2.0.0`。所有项目必须使用根 `playmesh-cli.json`、隔离的
  `playmesh/package` 与 `playmesh/sdk`，不再兼容
  `main.json/app/playmesh/sdk` 直接位于项目根的 1.x 结构；旧 JavaScript 项目只可在
  空目录重新 `get`，不可逆的 TypeScript/Cocos 源码必须从版本库迁移。上传只读取
  `playmesh/package/` 中的必需 `main.json`、可选 `capabilities.json`、可选安全根
  `icon.png` 与必需 `app/`；`playmesh/sdk/` 永不上传。
- CLI 新增 `run`（正式构建、完整上传并运行，不附加日志）、`logs`
  （只附加当前项目实时日志）和 `update`（更新 SDK 后转交项目适配器）。`dev` 改为
  本地开发资源代理 + 真实 App 运行 + 日志：仅目标缺少项目时上传包含必需清单、可选
  能力声明、可选 `icon.png` 和必需入口占位文件的最小基础包。公开
  `create/push/sdk` 已删除。
- CLI Go 源码按职责迁入 `dev-cli/internal/`：模块根只保留薄入口 `main.go`；命令、
  项目模型、打包、SDK、目标凭据、开发资源和各引擎适配器分别成包。Cocos 扩展资源
  随适配器归档，Windows/Linux 构建递归跟踪内部源码与嵌入资源。
- `dev` 的开发资源统一收口为公共 `development.Source` /
  `development.Mapping`：Adapter 只提供来源、路径、headers 与 `Start/Stop`
  生命周期，CLI 公共代理和 App Developer Gateway 都不包含 Cocos 或其他引擎分支。
  JavaScript、TypeScript、Cocos 及未来 Godot 只在 CLI 的唯一 `adapter.Registry`
  注册；新增引擎不修改 App 代码或 App 资源源类型，也不新增第二份适配器实例表或
  第三套代理。
- CLI 目标 App token 不再明文写入 `cli-target.json`：Windows 使用当前用户 DPAPI，
  macOS 使用 Keychain，Linux 使用 Secret Service；旧版明文配置不迁移，必须重新
  执行 `playmesh-cli to`。安装目录不保存凭据，避免只读、多人共享和应用升级替换。
- 项目创建统一为公共 `init [平台]` 入口。无平台参数时用数字选择 JavaScript 或
  TypeScript，并生成 Vue 风格的根 `package.json`、`src/` 源码目录、
  `jsconfig.json/tsconfig.json` 和 npm `build/dev/run/logs/update` 脚本；IDEA 可直接
  点击 npm `dev` 运行按钮把开发 Web 根代理到真实 App。空目录 `get` 固定把
  App 发布包恢复为 JavaScript 2.0 工程；由于发布包不含 TypeScript 类型或 Cocos
  工程源码，生成结果不能还原这两类原始工程，它们必须从源码版本库恢复。
- 首个 `init cocos` 适配器支持 Cocos Creator 3.x，从项目描述文件自动读取名称，
  通过带可见默认值和数字选项的向导调用现有创建 API，并生成隔离包目录、SDK 类型
  引用、配置 Schema 和项目级 Cocos 扩展。已初始化或已经是 Playmesh 项目的目录会
  在任何写入和远端创建前拒绝重复初始化。
- CLI 生成的 `playmesh-cli.schema.json` 完全使用项目内本地引用，不声明虚构域名或
  外部 JSON Schema 地址；内置 SDK、Manifest 与能力契约 Schema 同样使用本地相对
  标识。
- Cocos 扩展接入 Web Mobile/Web Desktop `onAfterBuild`，并在两个 Web 构建面板
  显示“启用 Playmesh 发布”和“构建后上传并运行到 App”选项。构建结果先进入临时
  目录，注入标准 Game SDK 标签后原子替换 `playmesh/package/app/`，再按选项调用
  `playmesh-cli run` 在真实 App 中上传并启动；“扩展 -> Playmesh”菜单可打开构建
  发布、使用浏览器预览地址启动 `dev`、运行最近构建、附加日志和执行完整集成更新。
  预览地址按消息参数、`PLAYMESH_DEV_SERVER_URL`、`integration.developmentServerUrl`
  依次解析；Cocos 3.8 的公开扩展接口不支持向发布平台或顶部预览设备下拉框注册
  自定义项。
- 游戏库本地导入新增普通网页 ZIP 转换。压缩包根目录没有 `main.json` 但包含 HTML 时，
  App 会让用户确认游戏名称、主屏方向、游戏模式、显示模式和主入口；单屏多人另外确认
  控制器方向与控制器入口。找到 `index.html` 时默认使用其非空 `<title>` 作为游戏名，
  否则回退到压缩包文件名。
- 普通网页包转换会剥离统一公共外层目录，把全部内容迁入标准包物理 `app/`。由于
  `app/` 已直接挂载为运行时 `/`，原相对路径和 `/assets/**` 等根路径保持不变，
  转换器不会为外层物理目录自动添加 `/app` 前缀；用户内容原有的 `app/` 目录和
  `/app/**` 引用、外部 URL、协议相对 URL、未知 `/api`/路由和二进制文件同样保持
  不变。转换结果重新经过标准包清单、入口、保留目录、路径、大小和危险文件校验后
  原子提交；已有根 `main.json` 的包继续走严格导入，没有 HTML 的压缩包明确拒绝。
- 普通网页包选择多人不表示导入器自动增加联机玩法；转换只生成平台所需的模式、玩家
  和入口声明。单屏多人会保留独立主屏与控制器 HTML，并生成内部兼容 Authority 入口，
  页面之间的游戏业务和通信逻辑仍由原网页包负责。
- 普通网页包导入新增标准包识别、非网页包拒绝、`index.html` 标题、公共外层目录、
  原相对路径与根资源保留和单屏多人条件表单回归测试；`dart analyze lib test` 无问题，
  全量 `flutter test --no-pub` 共 336 项通过。
- 为兼容 Cocos HTML 游戏较大的 `.wasm`、`.data` 和资源合包，游戏包导入预算提高为
  压缩文件 100 MiB、解压总量 512 MiB、单文件 128 MiB、最多 8000 个文件；目录穿越、
  符号链接、重复路径、危险文件类型和原子提交保护保持不变。
- Catalog API 升级到 `3.0.0`。Go Server 在接收并规范化游戏包时把 ZIP 实际字节数
  写入 SQLite，后续游戏列表以可选 `packageSizeBytes` 返回，不再为每次列表请求读取
  文件；默认上传预算同步为 100 MiB 压缩、512 MiB 解压、128 MiB 单文件和 8000 文件，
  并采用与 App 相同的根相对入口、入口扩展名和一级保留目录校验。
- Relay 协议升级到 `3.0.0`。局域网邀请和端点加密公共邀请都封装
  `/controller/index.html` 这类根相对入口；若清单声明 `app/controller/index.html`，
  则原样生成 `/app/controller/index.html` 并解析到物理 `app/app/controller/index.html`。
- 下载弹框新增“准备游戏包”“下载”“校验并安装”阶段。App 临时局域网源按需压缩时
  显示不定进度，收到响应后按 1024 进位展示总大小、当前速率和已下载/总量；列表未
  提供大小时使用响应 `Content-Length`，无需为 App 临时分发预生成或持久化 ZIP。
- 修复 App 加入端加载权威主机游戏或单屏多人控制器时，虽已通过
  `controllerRequired` 声明并获得系统摄像头/麦克风权限，WebView 仍因没有接通权限
  回调而拒绝 `getUserMedia()` 的问题。
- Android、iOS 与 macOS 加入端现在按权威页面下发的最新运行时能力声明处理 WebView
  摄像头、麦克风和 MIDI SysEx 权限；Windows 加入端改为读取 App Bridge 的运行时
  声明，不再使用构造阶段的空能力数组。
- App WebView 敏感权限改为统一能力注册表模型：统一层按当前页面角色声明把请求资源
  映射为现有能力 code，检查插件可用性，再按 code 调用能力注册时绑定的唯一平台授权
  执行器。执行器不再维护额外 ID，也不负责路由或声明判断；本地页、加入页、Windows
  WebView 和 Android Activity 不再维护摄像头、麦克风或 MIDI 的外部 switch。普通
  浏览器不进入 App 原生权限执行链；新增权限型能力只需注册资源映射与唯一执行器，
  系统静态权限声明仍按平台要求同步配置。
- 加入端开始新导航时立即清除上一页面的动态能力声明和确认状态，避免旧页面权限被
  后续页面短暂沿用；未知、未声明或平台不支持的权限继续默认拒绝。
- Android 加入端补齐网页文件选择器接入，与本地游戏 WebView 保持一致，文件选择仍由
  用户主动触发且不申请存储权限。
- 新增 Android `sensor.pose6d@1.0.0` 能力。游戏可按 `1..60 Hz` 接收 ARCore 的
  米制 XYZ 与 XYZW 四元数，实例支持独立 `recenter()`，多个实例共享一个 ARCore
  Session 并以最高订阅频率驱动原生采样。
- 新增协议无关的 `playmesh.app.media`。能力实例只签发不透明媒体源，网页需要画面时
  才调用 `media.open(source)` 得到 `MediaStream`；停止消费或释放能力实例会回收媒体
  会话和源。公共层只负责适配器注册、选择、签发和生命周期，`adapterOptions` 由具体
  适配器自行解析。
- 首个 Android 媒体适配器为 WebRTC。offer/answer 通过现有 App Bridge 单次交换，
  PeerConnection 只在同一终端的原生宿主与 WebView 之间建立，不增加 HTTP 地址、开放
  端口或信令服务器。后续协议只需实现并注册自己的 Dart/网页适配器。
- 能力句柄新增 DOM 风格 `addEventListener/removeEventListener` 别名；既有
  `on()`、`onError()` 与 `dispose()` 保持不变。
- 能力平台注册改为 `CapabilityPlatform.WINDOWS/ANDROID/HTML` 枚举列表
  `supportedPlatforms`。运行时、WebView 权限和开发者自检统一按当前平台列表门控；
  项目创建/修改弹窗只展示列表中的支持平台。游戏包的能力 code 声明及既有
  `playmesh.app.platform` 协议值不变。
- App bootstrap 不再预探测任何能力、硬件或原生服务。`sensor.pose6d` 只在网页实际
  创建能力实例时启动 ARCore，安装、设备支持和 Session 创建错误直接返回。开发者
  一键自检统一改为 `create({})` 后立即 `dispose()`，创建失败即自检失败。
- Developer API 的能力描述符继续使用 `3.0.0` 阶段引入的
  `supportedPlatforms`，Developer CLI 的能力选择只输出列表中支持的平台；本轮又因
  新增开发资源会话契约整体升级到 `4.0.0`。
- 新增动态权限声明、权限重置及加入端跨平台权限接线回归测试；全量
  `flutter test` 共 324 项通过，`flutter analyze lib test` 无问题，
  `flutter build apk --debug` 构建成功。摄像头、麦克风系统弹窗及 Windows WebView2
  行为仍需目标平台真机/实机验收。
