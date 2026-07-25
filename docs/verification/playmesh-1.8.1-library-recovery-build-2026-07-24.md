# Playmesh 1.8.1 游戏库自救与构建验证

## 范围

- App `1.8.1+14`
- Developer API / OpenAPI `1.6.1`
- Developer CLI `1.3.1`
- Game SDK `2.2.0`
- App Bridge SDK `2.1.0`

本次验证覆盖旧 Manifest 元数据缺省、损坏项目宽松发现与拉取、最近打开排序和清理、固定临时 ZIP、详情展示，以及 Android/Windows 发布构建。

## 自动验证

全部命令按 `docs/04-dev-env.md` 使用固定工具链、在沙箱外串行执行。

| 验证 | 结果 |
| --- | --- |
| `dart format lib test` / `gofmt` | 通过 |
| `flutter analyze --no-pub lib test` | 通过，无问题 |
| `flutter test --no-pub` | 通过，153 项 |
| `go test ./...`（`dev-cli/`） | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| `node --check assets/playmesh-library/public/developer/workspace.js` | 通过 |
| `node tool/test_desktop_cli_packaging.mjs` | 通过 |
| `git diff --check` | 通过；仅现有行尾转换提示 |

回归断言包括：

- 缺少 `author` / `lastModifiedAt` 时分别得到“佚名” / “无”。
- 只含有效 `id` 的损坏 `main.json` 仍生成待修复条目；无有效 ID 的目录不阻断其余扫描。
- 最近打开记录覆盖写入包外本地文件，删除游戏同步删除，排序按时间倒序。
- Developer CLI 能解压缺少 `app/` 的恢复包。
- 宽松项目包导出不解析损坏的 `capabilities.json`，但继续执行路径和大小安全约束。
- 详情页展示作者、最后上传、最近打开和待修复状态；待修复项目不可运行。

## Android

- 构建命令：`tool/build_release.ps1 -Target android -AllowDebugSigning`
- 产物：`release/1.8.1/Playmesh-1.8.1-build14-android-universal.apk`
- 大小：96,956,599 bytes
- SHA-256：`8AE3B543F9EF808950E230AA838F6AF9DEBC23E54F9F6BE745F24C294CC2264A`
- APK Signature Scheme v2：通过
- 签名证书：`C=US, O=Android, CN=Android Debug`

该 APK 仅供内部安装验证，不是生产签名包。

## Windows

- 构建命令：`tool/build_release.ps1 -Target windows`
- 产物：`release/1.8.1/Playmesh-1.8.1-build14-windows-x64-portable.zip`
- 大小：23,583,386 bytes
- SHA-256：`269393069900E51C14762E688672E156A08B8BB2612B918726D654A670CFC089`

统一构建脚本已检查 ZIP 根目录包含 `playmesh.exe`、`playmesh-core.exe`、`playmesh-cli.exe`、`flutter_windows.dll`、`WebView2Loader.dll`、`data/app.so` 和 `data/icudtl.dat`，并确认未夹带已删除的游戏包资源。

## 仍需人工验证

- 在装有历史缺字段或损坏清单的真实游戏库上启动 App，确认可进入游戏库和开发者工作区。
- 从真实 App 使用 `playmesh-cli get` 拉取损坏项目并修复后再 `push/dev`。
- 在 Android 和 Windows 实机连续导入、导出多次，确认系统临时目录中同类中转文件不会递增。
- Android 生产发布需使用非 Debug 的正式签名密钥重新构建。
