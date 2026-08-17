# Contributing to Playmesh

[English](#english) | [简体中文](#简体中文)

## English

Thank you for contributing to Playmesh. Issues and pull requests are welcome.

### Before opening a pull request

- Search existing issues and pull requests first.
- Open an issue before substantial changes to public SDKs, compatibility, multiplayer authority, storage, package formats, security boundaries, generated artifacts, or release workflows.
- Keep each pull request focused on one problem and avoid unrelated formatting or refactoring.
- Do not commit credentials, private endpoints, generated build directories, or local machine configuration.
- Preserve third-party copyright, license, and attribution notices.

### Development rules

- Follow `docs/06-engineering-standards.md` and the relevant documents under `docs/platform/` or `docs/game/`.
- Treat `lib/core/game_sdk/features/` as the handwritten SDK source of truth. Do not directly maintain generated SDK artifacts as independent sources.
- Keep trusted multiplayer state in Authority code and derive player identity from trusted session context.
- Add or update tests and documentation when behavior, contracts, or compatibility changes.

### Verification

Run the checks relevant to your change. Flutter commands must run serially because they share an SDK lock.

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub lib test
flutter test --no-pub
```

For SDK changes, regenerate the SDK first and run the affected Node contract tests. For Go changes, run `go test ./...` from each changed module (`go-core`, `go-server`, or `dev-cli`). Document any check that could not be run and why.

### Pull request description

Explain the problem, the chosen solution, affected platforms or compatibility boundaries, verification performed, and remaining manual checks. Include screenshots or recordings for visible UI changes.

By submitting a contribution, you agree that your contribution is licensed under the MIT License used by this repository and that you have the right to submit it.

## 简体中文

感谢参与 Playmesh。项目欢迎 Issue 和 Pull Request。

### 提交 Pull Request 前

- 先搜索已有 Issue 和 Pull Request，避免重复工作。
- 修改公开 SDK、兼容范围、多人 Authority、存储、包格式、安全边界、生成产物或发布流程前，先通过 Issue 说明方案。
- 每个 Pull Request 只解决一个明确问题，不混入无关格式化或重构。
- 不得提交凭证、私有地址、构建目录或本机配置。
- 必须保留第三方版权、许可证和署名声明。

### 开发约束

- 遵守 `docs/06-engineering-standards.md` 以及相关的 `docs/platform/`、`docs/game/` 文档。
- `lib/core/game_sdk/features/` 是 SDK 唯一手写源；不得把生成的 SDK 文件当作独立源码维护。
- 多人可信状态由 Authority 持有，玩家身份从可信会话上下文取得。
- 行为、契约或兼容范围变化时，同步补充测试和文档。

### 验证

执行与改动相关的检查。Flutter 命令共享 SDK 锁，必须串行运行。

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub lib test
flutter test --no-pub
```

修改 SDK 时先重新生成 SDK，再运行受影响的 Node 契约测试。修改 Go 代码时，在发生变化的模块（`go-core`、`go-server` 或 `dev-cli`）中执行 `go test ./...`。无法执行的检查必须说明具体原因。

### Pull Request 说明

请说明问题、所选方案、受影响的平台或兼容边界、已经完成的验证和仍需人工检查的事项。可见 UI 变化应附截图或录屏。

提交贡献即表示你同意按本仓库使用的 MIT 许可证授权该贡献，并确认你有权提交相关内容。
