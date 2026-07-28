# Playmesh 3.0.0 本地验收记录

- 验收日期：2026-07-26
- App：`3.0.0+22`
- Game SDK：`2.3.0`
- App Bridge SDK：`2.1.1`
- Go Core：`0.5.0`
- Core 协议：`1.3.0`
- Catalog API：`2.0.0`
- Developer API / OpenAPI：`2.2.0`
- Developer CLI：`1.4.0`
- 执行边界：全部测试、代码生成、浏览器服务和发布构建均在沙箱外执行

## 1. 静态分析与自动化测试

| 范围 | 命令/入口 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze` | 通过，`No issues found` |
| Flutter 全量回归 | `flutter test -r compact` | 通过，`265/265` |
| Go Core | `go test ./...`、`go test -race ./...`、`go vet ./...` | 全部通过 |
| Go Server | `go test ./...`、`go test -race ./...`、`go vet ./...` | 全部通过 |
| Developer CLI | `go test ./...`、`go test -race ./...`、`go vet ./...` | 全部通过 |
| SDK 生成 | `node tool/generate_sdk.mjs` | 生成 Game SDK `2.3.0`、App SDK `2.1.1` |
| Game SDK | `test_game_sdk.mjs`、`test_game_sdk_browser.mjs` | Bridge、浏览器身份、全屏、日志和重连契约通过 |
| App Bridge SDK | `test_app_bridge_sdk.mjs` | capability plugin bridge 契约通过 |
| SDK 声明 | `test_sdk_declarations.mjs` | 中文声明与精确签名通过 |
| Authority 模板 | `test_default_authority_service.mjs` | 同步模板契约通过 |
| 平台 UI 本地化 | `test_platform_ui_localization_source.mjs` | 受限投影契约通过 |
| Flutter 本地化源 | `test_flutter_localization_source.mjs` | 432 个 App `tr` 调用、354 个静态 key、2 个启用语言通过 |
| Android 开发通知 | `test_android_developer_notification_localization.mjs` | App 统一本地化投影契约通过 |
| 桌面 CLI 打包 | `test_desktop_cli_packaging.mjs` | Windows/Linux 跟随编译与产物命名通过 |
| Go Server 本地化生成 | `node go-server/tool/generate_localization.mjs` | 通过 |

全量回归期间额外修复并重新验证：

- `publicURL` origin 规范化不再残留查询字符串或空 `?`。
- Flutter Widget 测试统一加载真实 App catalog/delegate，不维护测试专用翻译。
- 游戏工具的 F10/Escape 硬件事件不再被全局处理器和 `Shortcuts` 重复消费。
- Developer Workspace HTML 的只读项目 ID 契约更新为当前标准表单结构。
- Go Server 严格语义版本接受完整正 `int64` 上限。
- Relay Client 在没有 Join Capability 时先返回 `401`，不通过 `404` 暴露隧道存在性。
- 审核测试夹具补齐存储包路径，保持“无包不能批准”的状态机约束。

## 2. 浏览器实际联调

使用临时本地 Go Server 和内置浏览器完成以下只读/界面验证，结束后已关闭页面并停止临时服务：

- 公开门户首帧正常，无控制台 `warn/error`。
- `zh-CN` 与 `en-US` 实时切换成功，`document.lang` 和标题同步更新。
- 游戏源 URL、Token、源名称等动态值切换语言后逐字保持不变。
- 主题从 `system` 切换到 `light`、`dark`，根节点实际主题更新为 `dark`。
- 隔离管理入口仅在配置的私有路径提供登录页；页面为 `zh-CN`、首帧可见且无控制台错误。

Developer Workspace 的 App locale/theme 联动、`app.json` 单一来源、日志原样边界和
平台覆盖层受限投影同时由 Flutter/Node 契约测试覆盖。

## 3. 发布构建

执行：

```powershell
.\tool\build_release.ps1 -Target all -AllowDebugSigning
```

结果：

| 产物 | 大小 | SHA-256 |
| --- | ---: | --- |
| `Playmesh-3.0.0-build22-android-universal.apk` | 103,560,904 bytes | `9938F6CA6536A3ED555E0363F3F6DF77FC7CC423A85F09322B05EFC171847A3D` |
| `Playmesh-3.0.0-build22-windows-x64-portable.zip` | 24,520,542 bytes | `D4928BC374B31006F9ECFBE8EC9E3B040C158332F7D78DE26E93C2677395253C` |

两份产物均通过 13 项发布 Asset 源/产物 SHA-256 一致性校验。Windows ZIP 根目录包含
`playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、Flutter、WebView2 和
`data/app.so` 等必需运行入口。

Android 使用本次命令明确允许的内部 Debug 证书生成 Release APK；`apksigner`
验证 APK Signature Scheme v2 为 `true`、签名者为 1。该 APK 可用于内部验收，
不能冒充生产密钥签名包。

非阻断构建提示：

- `mobile_scanner` 仍由上游插件应用 Kotlin Gradle Plugin；Flutter 提示未来需迁移到
  Built-in Kotlin，本次 `assembleRelease` 成功。
- Windows CMake 未找到 JNI，但当前 Windows App/Go Core/CLI/WebView2 目标不依赖 JNI，
  Ninja 发布构建与产物校验均成功。

## 4. 边界复核

- Harmony/OHOS 工程、兼容插件、Go 入口、安装/测试脚本和打包目标均已删除；发布入口
  只接受 `android`、`windows`、`all`。
- `main.json.permissions` 与 `main.json.icon` 不在当前模型、Schema 和生成产物中；
  输入时与其他未知字段一样静默忽略。图标只认游戏包根目录 `icon.png`。
- App、Developer Workspace、Android 开发通知和 App 提供的游戏覆盖层统一消费
  `assets/playmesh-localization/locales/*/app.json`。
- 游戏业务只获得 `playmesh.runtime.getLocale()`；普通浏览器读取系统 locale，失败精确
  回退 `zh`。游戏内容、游戏源名、发布者、昵称、标签、API 动态值和日志正文均不翻译。
- 需求文档 `docs/下一步方案.md` 未编辑；验收后 SHA-256 仍为
  `57994AB4278261043DE3911C13787E477E7780664BDCB693EEAE14051BDBFC2A`。

## 5. 2026-07-27 UI 修正复核

本节只记录 2026-07-27 首页、设置、Developer Workspace 与游戏工具层级修正，不改写
上方 2026-07-26 发布构建结果。

| 范围 | 命令/入口 | 结果 |
| --- | --- | --- |
| SDK 生成 | `node tool/generate_sdk.mjs` | Game SDK `2.3.0`、App SDK `2.1.1` 生成通过 |
| 定向 Flutter 回归 | 首页、游戏工具、设置、Workspace/平台 UI 契约 5 个测试文件 | `22/22` 通过 |
| 完整 Flutter 回归 | 全部单元、组件与契约测试 | `266/266` 通过 |
| Flutter 静态分析 | `flutter analyze` | 通过，`No issues found` |
| 浏览器 SDK | `node tool/test_game_sdk_browser.mjs` | 日志一级入口、性能二级入口、昵称信息弹窗与焦点契约通过 |
| 平台 UI 本地化 | `node tool/test_platform_ui_localization_source.mjs` | 新增键与 App 受限投影通过 |
| Workspace JavaScript | `node --check assets/playmesh-library/public/developer/workspace.js` | 语法通过 |

复核边界：

- 首页只有简介卡中的用户资料入口和右上角设置，三项主入口顺序固定。
- 在线游戏库与设置页均可进入游戏源管理；动态游戏、源和用户名称不进入国际化。
- Workspace 继续使用 App `app.json`，但编辑器视觉固定为深色；手机工具栏不再出现
  第六项溢出，项目/目录/代码及其他文件图标可区分。
- App/浏览器游戏工具都将日志放在一级，性能放入“更多”，二级设置被移除。
- 运行日志内容继续保持原样，不参与翻译。

## 6. 2026-07-27 首页快速入口与 Workspace 图标复核

本节记录同日第二批界面修正。实现继续只更新本地实现、平台、版本和验证文档，
未编辑需求文档。

| 范围 | 命令/入口 | 结果 |
| --- | --- | --- |
| 定向 Flutter 回归 | 首页、游戏库、在线游戏库、设置、Workspace/平台 UI 契约与总入口 7 个测试文件 | `51/51` 通过 |
| 完整 Flutter 回归 | `flutter test -r compact` | `268/268` 通过 |
| Flutter 静态分析 | `flutter analyze` | 通过，`No issues found` |
| Flutter 国际化 | `node tool/test_flutter_localization_source.mjs` | 429 个调用、354 个静态键、2 个 locale 通过 |
| 平台 UI 国际化 | `node tool/test_platform_ui_localization_source.mjs` | App 注入式平台 UI 单一来源契约通过 |
| Workspace JavaScript | `node --check workspace.js`、`node --check workspace-icons.js` | 语法通过 |

复核边界：

- “游戏库－最近游戏”位于资料卡下方，最多显示三项，最近记录不足时从游戏库补位；
  点击条目直接启动，标题进入完整游戏库。
- 首页与在线游戏库扫码按钮分别进入扫码加入和扫码添加源流程；源添加页不再展示
  publicURL 与 `/apps/info` 提示。
- 设置页版本信息置顶，游戏源入口名称和副标题统一。
- Workspace 的项目与文件树使用内联 SVG 分类图标，移动端五项工具栏保持可见，
  AI 为唯一强强调按钮；页面不存在外部 SVG sprite 引用，控制台不再产生
  `[object SVGAnimatedString]` 资源错误。

## 7. 2026-07-27 Windows 首页键盘复核

| 范围 | 命令/入口 | 结果 |
| --- | --- | --- |
| Windows 首页定向回归 | `flutter test -r compact test/widget_test.dart test/features/home/home_page_test.dart` | `17/17` 通过 |
| 完整 Flutter 回归 | `flutter test -r compact` | `269/269` 通过 |
| Flutter 静态分析 | `flutter analyze` | 通过，`No issues found` |

复核边界：

- 自定义返回、菜单和游戏工具快捷键改为叠加在 Flutter 默认 `Shortcuts/Actions`
  之内，不再覆盖方向键、Tab、Enter/Space。
- Windows 首页初次显示时资料卡获得焦点；方向键能移动到下一目标，Enter 能打开
  用户资料。桌面键盘、Android TV 遥控器和外接键盘复用同一焦点策略。
