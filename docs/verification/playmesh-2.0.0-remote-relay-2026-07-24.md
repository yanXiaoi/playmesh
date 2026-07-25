# Playmesh 2.0.0 双链路与公共中转验证

## 范围

- Playmesh App `2.0.0+18`
- Go Core `0.4.0`
- Core 协议 `1.2.0`
- Catalog API `1.3.0`
- Relay 协议 `1.0.0`
- Game SDK `2.2.1`
- App Bridge SDK `2.1.0`

> 本文记录 `2.0.0+18` 安装包构建时的协议状态。后续声明入口与短邀请变更已将
> 当前工作区 Relay 协议升级到 `2.0.0`，代码级验证见
> `playmesh-2.0.0-declared-entry-invitation-2026-07-24.md`；本文列出的 Android
> 与 Windows 产物尚未包含该后续修正。

本次验证覆盖游戏分享 Authority 最小公开面、局域网与公共中转并存、App
本地回环 Origin、端点持钥透明加密隧道、游戏源中转声明和统一房间状态。
Game SDK 与 App Bridge SDK 的游戏侧公共 API 未改变，现有游戏包、默认模板和
SDK 声明未修改；AI 提示词只增加传输透明、统一使用 SDK 的行为约束，不包含
回环代理、中转鉴权、密钥协商或加密通道实现。

Catalog `1.3.0` 的 Relay 声明新增 `publicBaseUrl`。Go Server 由
`server.json` 明确配置并返回 HTTP/HTTPS 公共 Origin；主机 App 使用它建立隧道
并生成二维码，不再从游戏源 Host 推导。Go Server 仍只返回隧道公开凭据，不
生成完整邀请，也不会获得只存在于 fragment 的端点密钥。
外层是否使用 TLS 直接由 `publicBaseUrl` 的协议决定，不再声明独立策略字段。
Go Server 负责校验自身配置；App 只校验建立连接所需的公共 URL、端点路径和
传输类型，不判断服务器的部署策略。

## 密钥隔离结论

Go Server 不是“选择不解析”游戏密文，而是协议上没有解密能力：

- 256 位端点密钥由主机 App 在本地生成。
- 密钥只进入邀请 URL 的 fragment，由加入方 App 在本地读取。
- fragment 不进入创建隧道、Host Upgrade 或 Client Upgrade 请求。
- Go Server 只收到 `tunnelId`、Host Lease 和 Join Capability；三者只用于
  临时隧道鉴权与配对，不参与内容密钥派生。
- 每条 TCP 连接使用独立随机 Salt，经 HKDF-SHA256 派生双向 AES-256-GCM
  密钥；Go Server 因未持有端点密钥，无法还原游戏路径、静态资源、SDK
  消息、WebSocket 内容或玩家昵称。

Flutter 隧道回归测试会记录模拟中转收到的全部 HTTP 与 Upgrade 请求，并断言
邀请中的端点密钥没有出现在任何请求元数据中；同时断言中转观察到的字节不包含
测试明文。Go Server 回归测试还将创建隧道响应限制为 `tunnelId`、`hostLease`、
`joinCapability` 和 `expiresAt` 四个字段，禁止中转生成或返回内容密钥。

## 自动验证

所有 Dart、Flutter 和 Go 命令均按 `docs/04-dev-env.md` 使用固定工具链，并在
沙箱外执行。

| 验证 | 结果 |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test` | 通过，155 个文件，0 个变化 |
| `flutter analyze --no-pub lib test` | 通过，无问题 |
| `flutter test --no-pub` | 通过，160 项 |
| 游戏源声明、公共中转与邀请解析定向测试 | 通过，8 项 |
| 局域网回环 1 MiB 原始字节完整性与显式背压测试 | 通过 |
| 公共中转 128 KiB 双向多记录加密流完整性测试 | 通过 |
| `go test ./...`（`go-server`） | 通过 |
| `go test ./...`（`go-core`） | 通过 |
| `gofmt -l`（`go-core`、`go-server`） | 通过，无待格式化文件 |
| `node tool/test_game_sdk.mjs` | 通过 |
| `node tool/test_app_bridge_sdk.mjs` | 通过 |
| `node tool/test_game_sdk_browser.mjs` | 通过 |
| `node tool/test_sdk_declarations.mjs` | 通过 |
| 开发者工作区与 AI 提示词生成定向测试 | 通过，8 项 |

设置页原有的发行日志测试把特定版本号、构建号和文案当成固定断言，每次正常升级
都会产生无意义失败；本次按产品决定删除该用例，不再把发行文案视为稳定 API。
设置页其余 Core 状态、刷新、错误和开发者模式测试继续保留。

## 平台构建

Android 与 Windows 均通过 `tool/build_release.ps1` 使用固定工具链在沙箱外串行构建。
构建入口在打包前重新生成并确认 Game SDK `2.2.1` 与 App Bridge SDK `2.1.0`，
Android 同时从当前 `go-core/mobile` 源码重新生成 Core AAR。

| 平台 | 产物 | 大小 | SHA-256 |
| --- | --- | ---: | --- |
| Android universal | `Playmesh-2.0.0-build18-android-universal.apk` | 97,564,938 字节（93.05 MiB） | `89CCBFF35645822DB4024C3FA82654D863C9C6F69B1A85AC4796A82D94FFCBE0` |
| Windows x64 portable | `Playmesh-2.0.0-build18-windows-x64-portable.zip` | 23,669,545 字节（22.57 MiB） | `4AA491F40AB1416F20F13B063BA145120204572924975B128EE205F7DB5ECF98` |

Android 当前没有生产 `key.properties`，因此按用户要求生成内部安装包并使用
`CN=Android Debug` 的 RSA 2048 证书签名。`apksigner` 验证通过，使用 APK
Signature Scheme v2，签名者证书 SHA-256 为
`1E4BFC405CD7E5F6E63DDC0327A4141ACA7AA83D79D115BAC716652D312EF9C2`。
该 APK 可用于内部安装测试，不能作为生产商店签名包。
APK 清单已核对为 `versionName=2.0.0`、`versionCode=18`、
`minSdkVersion=24`、`targetSdkVersion=36`。

Windows ZIP 共 154 个条目；脚本确认根目录包含 `playmesh.exe`、
`playmesh-core.exe`、`playmesh-cli.exe`、`flutter_windows.dll`、
`WebView2Loader.dll`，并包含 `data/app.so` 与 `data/icudtl.dat`。
`playmesh.exe` 文件版本与产品版本均为 `2.0.0+18`。
进一步直接读取 APK 与 Windows ZIP 内置资源，均确认多人 AI 提示词已经包含
“底层传输由平台透明处理”的 SDK 使用边界，默认模板仍声明 Game SDK `2.2.1`
与 App Bridge SDK `2.1.0`；单机提示词不再包含旧“HTTP 存储”实现表述。

## 未执行项

- 未执行 OpenHarmony 平台发布构建，本次用户只要求 Android 与 Windows。
- 未执行真实公网中转服务器与两台实体设备的端到端联机验收。
- 未执行移动系统对回环 Origin、安全上下文、权限弹窗和 WebView 生命周期的
  真机行为验收。

以上项目属于平台或真实网络验收，不影响本次代码级、协议级和自动回归结论。
