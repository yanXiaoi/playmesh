# Playmesh 1.5.0 自动验证记录

日期：2026-07-21  
版本：App `1.5.0+6`、Game SDK `1.4.0`、App Bridge SDK `1.2.0`、Developer API `1.3.0`、Developer CLI `1.0.0`

## 验证范围

- TypeScript 单一 SDK 源生成 JavaScript、`.d.ts`、Dart 版本常量、SDK Manifest/Schema 与默认模板。
- Developer Gateway SDK bundle、当前全局运行状态、项目包导出及整包导入接口。
- 同 ID 游戏包更新只替换发布文件并保留 `data/cache`。
- Go CLI 工作区 URL 解析、SDK 版本提取、Manifest 自动改写、发布包边界、上传提交与编译。
- `/app/` 游戏 URL 空间、默认模板、AI 提示词、SDK Manifest 与无 `/game/` 兼容层断言。
- Dart 静态分析、SDK 浏览器/Bridge 契约和 JSON 机器契约语法。

## 已通过

| 检查 | 命令或方式 | 结果 |
| --- | --- | --- |
| SDK 生成 | `node tool/generate_sdk.mjs` | 通过；生成 Game `1.4.0`、App `1.2.0` |
| SDK JavaScript 语法 | `node --check` 两个生成 JS | 通过 |
| Game SDK Bridge 契约 | `node tool/test_game_sdk.mjs` | 通过 |
| 浏览器身份/昵称契约 | `node tool/test_game_sdk_browser.mjs` | 通过 |
| App Bridge 身份/设备契约 | `node tool/test_app_bridge_sdk.mjs` | 通过 |
| SDK 中文声明与精确签名 | `node tool/test_sdk_declarations.mjs` | 通过；检查中文 JSDoc、版本、补全标记、关键签名、`appUrlRoot`，并拒绝模板/提示词中的旧 `/game/` |
| 桌面 CLI 跟随编译规则 | `node tool/test_desktop_cli_packaging.mjs` | 通过；检查 Windows/Linux CMake、macOS Build Phase、文件名与 Windows ZIP 必需项 |
| Developer CLI 测试 | `go test -count=1 ./...`（`dev-cli/`） | 通过，最终复测 `ok github.com/yanXiaoi/playmesh/dev-cli 0.904s` |
| Developer CLI 编译 | `go build -buildvcs=false -trimpath -ldflags "-s -w" -o playmesh-cli.exe .` | 通过 |
| Flutter 静态分析 | `flutter analyze --no-pub` | 通过，`No issues found` |
| JSON 契约解析 | Node 解析 OpenAPI、SDK Manifest、两个 Schema 与默认 main.json | 通过 |

CLI 测试覆盖完整工作区 URL 的 Base URL/token 解析与缺 token 失败路径；下载和上传均保持 `app/` 原名且不创建 `game/` 兼容目录；`playmesh/sdk/` 版本覆盖 `main.json.sdkVersion/appSdkVersion` 且不进入 ZIP；上传包仅包含 `main.json`、`capabilities.json`、`app/`；模拟 Developer Gateway 接收上传并确认提交。Dart 测试代码补充了 App SDK 版本兼容/拒绝规则、导入更新保留 `data/cache`、SDK bundle、全局 `runId`、`/app/` 资源访问以及旧 `/game/` 返回 404 的断言。

当前 Windows 开发成品已生成在 `dev-cli/playmesh-cli.exe`，大小 `6,841,856` bytes，SHA-256 为 `B1203F2B6BDE399B498795EFE9173D204DD37911BC2CE77C7AD77D0711C0D2B1`；`--help` 已确认显示五个命令。正式 Windows App 构建会另行把同名文件复制到 `playmesh-core.exe` 同级 bundle 根目录。

## 未完成的自动执行

定向 Flutter 测试命令在当前环境中多次没有任何输出，超过工程规定的 60 秒无输出阈值后终止；本轮最后一次覆盖：

```text
test/core/game_package/game_asset_gateway_test.dart
test/core/game_web/game_web_gateway_test.dart
test/core/developer/developer_project_validation_test.dart
```

本轮测试增加 `/app/` 入口、静态资源、嵌套页面 base URL 与旧 `/game/` 404 断言。此前编写的游戏详情测试覆盖点击 ID 写入剪贴板、成功反馈、`游戏名称-v版本.zip` 和非法字符清理。上述 Flutter 测试只能记录为“已编写、静态分析通过，运行结果未取得”，不能记为测试通过。无输出进程已按本轮启动时间清理；没有终止更早存在、归属不明的 Dart 进程。

## 平台与人工验证

按 `docs/04-dev-env.md` 的自动任务边界，本次未执行 Android、Windows、iOS、macOS 或 Linux 平台构建。桌面跟随编译只完成构建规则静态契约校验，仍需分别在目标平台进行一次真实构建。发布前建议在 Windows App 与 Android App 各完成一次真实链路：

1. 复制完整 Developer workspace URL，执行 `playmesh-cli to`，确认无需手工拆 token。
2. 在空目录执行 `playmesh-cli get`，确认包内 `app/` 保持为本地 `app/`，不存在 `game/` 兼容目录；IDEA 自动索引四个 `playmesh/sdk/` 文件，并能解析 `/app/...`、`/playmesh/...` 绝对路径。
3. 修改项目后执行 `push`，确认 App 不启动游戏，且已有 `data/cache` 保留。
4. 先运行另一项目再执行当前项目的 `dev`，确认旧 WebView 关闭、当前项目启动且日志持续输出。
5. 从 App 退出 WebView，确认 CLI 自动退出；重新运行后按 `Ctrl+C`，确认 CLI 退出而游戏继续。

当前工作区的 `.git` 元数据不可用，无法用 `git status/diff` 生成变更清单；本次通过文件级检查、格式化、静态分析和各语言测试完成校验，未对无关文件执行回退或删除。
