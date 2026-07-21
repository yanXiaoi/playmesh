# 第五阶段可配置入口验证记录（2026-07-17）

## 范围

本记录覆盖第五阶段第一批“可配置 game/controller/authority 入口”纵向链路，以及本轮确认的 Flutter/Dart 自动测试执行方式。功能中间状态见 `docs/status/phase-05-in-progress.md`，长期环境规则见 `docs/04-dev-env.md`。

## 执行环境结论

第一次在受限沙箱内直接执行：

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\dart.bat' format <本轮文件>
```

进程超过 60 秒没有任何输出，因此主动中止。随后使用相同绝对 SDK 路径在沙箱外的本机开发环境执行，约 2 秒完成。后续 Flutter/Dart 验证全部采用沙箱外执行，并在依赖已准备好后使用 `--no-pub`。

## 定向测试

首次定向测试执行时没有添加 `--no-pub`，Flutter 先完成了一次依赖解析；测试通过后，后续重复执行统一使用下面的无依赖解析形式：

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' test --no-pub `
  test\models\game_manifest_test.dart `
  test\core\game_package\asset_game_package_loader_test.dart `
  test\core\game_package\file_game_library_scanner_test.dart `
  test\core\developer\developer_project_validation_test.dart `
  test\core\game_web\game_web_gateway_test.dart
```

结果：通过，27 项测试全部成功。覆盖入口默认值、自定义嵌套路径、URL/越界/文件类型拒绝、Asset 与文件扫描、缺失 Authority、开发项目诊断和浏览器基准路径。

## 静态分析

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' analyze --no-pub
```

结果：通过，`No issues found`。

## 全量回归

```powershell
& 'D:\KaiFaTool\runtime\flutter\bin\flutter.bat' test --no-pub
```

首次全量回归发现测试假游戏没有真实包根时，`GameLauncher` 对 Asset 包结果进行了空值强制解引用；同时首页测试仍假设“游戏库”文字只出现一次。修复 Launcher 回退并让测试按当前标题加入口的 UI 语义检查后再次执行。

最终结果：通过，73 项测试全部成功。

## 资源契约检查

使用 Node.js `JSON.parse` 读取以下资源：

- `contracts/schemas/game-manifest.json`
- `contracts/sdk-manifest.json`
- `contracts/openapi.json`
- `templates/default-game/package/main.json`

结果：4 份 JSON 均可解析；未发现旧 `0.4.0-phase4` 契约版本或“必须存在 app/index.html”的过期 AI 规则。

## 边界

本轮没有执行 Android、iOS、Windows、macOS 或 Linux 平台构建，也没有进行真机/WebView 手工验证，符合项目自动任务边界。
