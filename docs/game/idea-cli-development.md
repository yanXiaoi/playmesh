# IDEA 与 CLI 游戏开发

Playmesh Developer CLI 把外部 IDE 中的本地目录与已开启开发者模式的 Playmesh App
连接起来。源码在 IDEA、WebStorm、VS Code 等编辑器中修改，校验、安装和实际运行仍由
目标 App 完成。

## 准备工作

1. 在目标 App 中开启开发者模式。
2. 复制完整工作区链接。
3. 安装目标桌面 App 自带的 `playmesh-cli`，或从 `dev-cli/` 构建 CLI。
4. 将 CLI 加入 `PATH`。

配置目标 App：

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
```

token 保存在当前用户配置目录，不得提交到游戏项目或版本控制。

## 创建项目

```powershell
mkdir my-game
cd my-game
playmesh-cli create
```

`create` 从目标 App 的统一能力注册表读取选项，并使用与网页工作区相同的项目创建 API。
创建完成后立即下载游戏源码、当前兼容 SDK 文件和 `.d.ts`。

## 拉取已有项目

```powershell
playmesh-cli get com.example.game
```

`get` 是修复通道：只要 `main.json` 仍有有效 ID，即使 Manifest 其他字段损坏或缺少
`app/`，也会尽量拉取现有内容。运行、`push/dev` 和正式导入仍执行完整严格校验。

## 本地目录

```text
main.json
capabilities.json           # 可选
app/                        # 发布内容，映射运行时 /app/
playmesh/                   # 本地开发镜像，永不上传
  sdk/
    playmesh.js
    playmesh-app.js
    playmesh.d.ts
    playmesh-app.d.ts
```

IDE 可将 `playmesh/sdk/*.d.ts` 纳入 JavaScript Library。两份声明包含完整中文 JSDoc，
并与目标 App 的 SDK 注册表同源。

## 日常开发

```powershell
# 只发布，不启动
playmesh-cli push

# 发布后启动或重启，并跟随本次 WebView 日志
playmesh-cli dev

# 更新本地 SDK 和类型到目标 App 当前版本
playmesh-cli sdk
```

`push/dev` 会从本地 SDK 读取真实版本，更新
`main.json.sdkVersion/appSdkVersion`，然后只上传：

```text
main.json
capabilities.json
app/
```

`playmesh/`、`data/`、`cache/` 和任何本地 IDE 文件都不能进入发布包。

## 发布与数据边界

- 相同游戏 ID 表示更新，只替换发布内容。
- 目标 App 中的 `data/` 和 `cache/` 保持不变。
- 发布继续复用正式游戏包导入器的路径、大小、Manifest、能力和入口校验。
- 上传进入项目本地历史，网页工作区可以审阅和恢复整包变化。
- `Ctrl+C` 只停止 CLI 日志跟随，不结束 App 中的游戏。

## SDK 版本

`playmesh-cli sdk` 获取目标 App 当前 SDK，用于新开发和类型提示；它不下载历史静态
SDK 文件。已经安装的游戏运行时会根据自身 `main.json.sdkVersion/appSdkVersion`
从目标 App 注册表选择兼容 Bundle 和对应执行器。

不要手工修改 `playmesh/sdk/` 生成物来伪造 SDK 版本，也不要把 URL 中的
`/sdk/v1/` 当作语义版本。

## 推荐开发闭环

```text
get/create
  -> 在 IDE 修改 app/
  -> playmesh-cli dev
  -> 查看 App WebView 日志
  -> 修复代码
  -> 再次 dev
  -> 使用网页工作区审阅校验和本地历史
```

详细命令、构建 CLI 和配置文件位置见
[`dev-cli/README.md`](../../dev-cli/README.md)。游戏运行语义见
[游戏开发指南](development-guide.md)。

## 后续扩展

新增 CLI 命令时必须优先复用现有 Developer Operation API，不得增加只供 CLI 使用的
第二套项目、文件、校验或发布实现。新命令需要同步：

- CLI 帮助与版本；
- `dev-cli/README.md`；
- Developer API 操作定义；
- 对应测试和版本日志；
- 本文档的工作流入口（如果用户操作发生变化）。
