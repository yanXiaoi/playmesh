# Playmesh 1.6.2 AI 能力上下文验证（2026-07-22）

## 验证范围

- Agent 提示词中的全量能力发现 API 与能力测试 API。
- 对话提示词中的当前项目已勾选能力完整声明。
- 开发者工作区独立复制全平台注册能力。
- 提示词模板、开发文档与回归测试。

## 已验证行为

- Agent 提示词不直接内嵌全平台注册表 JSON；正文提供带所选 Base URL 的 `GET /dev/api/capabilities`，用于读取当前所有能力及完整插件声明。
- Agent 提示词同时提供 `GET /dev/api/capability-tests` 与 `POST /dev/api/capability-tests`，并写明指定 code、测试全部和 `timeoutMs` 的请求格式。
- 对话提示词只内嵌当前项目 `capabilities.json.required` 已勾选插件的完整 JSON 描述符；项目未声明能力时不会出现平台注册能力声明。
- 工作区“复制全平台能力”独立调用 `GET /dev/api/capabilities`，复制内容不受当前项目勾选过滤。

## 自动验证

| 命令 | 结果 |
|---|---|
| `node --check assets/playmesh-library/public/developer/workspace.js` | 通过 |
| `flutter test --no-pub test/core/developer/developer_web_gateway_test.dart` | 通过；7 项测试全部通过 |
| `flutter test --no-pub` | 通过；134 项测试全部通过 |
| `dart analyze lib/core/developer` | 通过；No issues found |
| `dart analyze test/core/developer/developer_web_gateway_test.dart` | 通过；No issues found |
| `git diff --check` | 通过；仅有仓库现有的 LF/CRLF 转换提示，无空白错误 |

Flutter 测试与定向分析按要求在沙盒外执行。无参数的全仓 `flutter analyze --no-pub` 会扫描现有 `build/harmony-release/` 复制目录，并因该构建副本未声明 Windows WebView 依赖报告 11 条问题；本次修改所在的 `lib/core/developer` 与对应测试文件单独分析均为零问题。
