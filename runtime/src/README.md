# Playmesh Runtime

这是 Playmesh 独立游戏导出包使用的 Flutter Runtime。Android 与 Windows 共享
`lib/runtime/`；平台目录只负责 Flutter 宿主、Go Core 和必须由原生实现的能力。

## 代码边界

- Runtime 不导入主 App 的 Dart 库，也不在构建时同步主 App 源码。
- 已从主 App 复制并独立维护协议级公共实现，包括 Game/App SDK 能力、LAN 发现、邀请、
  本地隧道和公共中转。复制后的代码属于 Runtime，后续可以独立演进。
- `assets/playmesh-library/public/sdk/v1/` 是主 App SDK 的逐字节快照，不允许加入
  Runtime 私有补丁；Runtime 差异只能位于宿主 Bridge 和 Runtime 自有模块。
- Android 和 Windows 均从仓库父工程的 `go-core` 源码构建，不保存第二份 Go Core。
- 开发工作区、编辑器、提示词、项目模板和主 App 本地化不进入 Runtime。

## 运行链

```text
runtime-config.json + game.pmp
              |
      内存校验/解密/解包
              |
本机资源网关 + SDK 注入 + Bucket
              |
 Android/Windows WebView
              |
Game/App Bridge + Go Core
              |
LAN 发现、链接/扫码加入、可选公共中转
```

游戏文件使用最新的根目录布局。`entries.game: "index.html"` 对应包内
`index.html` 和运行时 `/index.html`；不存在旧的 `/app` URL 前缀。
`playmesh/` 与 `bucket/` 是 Runtime 保留的根命名空间。

Runtime 覆盖当前 Game SDK 4.1.0 与 App SDK 3.2.0–3.3.0 的全部宿主命令。
独立底包没有 Playmesh 用户头像资料，因此 `app.identity.syncAvatar` 在没有头像时按原
协议执行为空操作。

Windows 导出器会把模板入口 EXE 重命名为游戏名称，并同步替换图标、
FileDescription、ProductName、FileVersion 与 ProductVersion。展示元数据不是持久化
身份：Runtime 固定在 `%APPDATA%/top.zfjmm/Playmesh Runtime/games/<gameId SHA-256>/`
保存该游戏的身份和数据。同名但 gameId 不同的游戏不会重合，游戏改名也不会改变目录。

与主 App 对齐的运行接线包含：能力确认、WebView 输入接管、Android 返回键菜单与游戏自定义
返回、文件选择、横竖屏/全屏、页面暂停恢复、Binary Channel、JSON 与二进制 Bucket、私有
多人头像提交，以及当前游戏范围内的 LAN 分享/加入；菜单加入入口与分享/邀请一样只对
Authority 主机显示。上述实现均位于 Runtime 自有模块，
不依赖主 App Dart 源码。Runtime 分享面板保留全部非回环 LAN 链接并允许切换二维码；启动与
等待 App SDK 接管输入期间复用 `packages/playmesh_ui` 的统一黑底加载层，只显示 Playmesh
标识与转圈。

## 全功能固定底包与模块边界

固定 MVP 包含相机、麦克风、MIDI、振动、Pose6D、WebRTC、扫码和 LAN/中转能力。
模块清单位于 `assets/runtime/runtime-modules.json`。清单保留依赖闭包和
`postBuildPrunable` 元数据，只定义模块边界；本阶段不执行注入或包后裁剪。

当前从结构上可安全后裁剪的是 Pose6D/ARCore 与 WebRTC 的独立 native library。
相机、语音、MIDI、振动、扫码、Flutter Dart AOT 和 `classes.dex` 已合并进底包，不能
仅靠删除 ZIP 条目安全裁掉。此结论用于后续主 App 导出器设计，不代表固定 MVP 已执行
裁剪。

`RuntimeModulePruningPlan` 会根据游戏能力计算依赖闭包、可删除的 APK native 条目和
仍需保留的 Android 权限，同时明确列出已合并、不能安全包后删除的模块。若以后要把
这些小模块也彻底移除，必须在编译前选择 Flutter 插件/源码集合并重新编译，不能直接
删除 `libapp.so` 或 `classes.dex` 中的一部分。

扫码模块始终保留，因为 LAN App SDK 本身不是游戏能力声明，固定游戏仍需扫码加入。
Android 固定包分别构建 x86_64 与 arm64-v8a 单架构产物，避免在同一个 APK 中装入
无关 CPU 架构。短文件名中的 `x86` 与 `arm` 分别对应这两个真实 ABI；打包清单会记录
完整 ABI，不能把 `x86` 误认为已支持 32 位 x86。

## 后续主 App 导出链（本阶段停用）

动态注入游戏、按能力裁剪、修改应用身份、加密、ZIP 对齐和最终签名都属于主 App，
Runtime 不提供导出命令，也不会在本次构建中执行这些动作。

固定 Android/Windows MVP 与动态导出都使用 `aes-gcm-v1` 的 PME1 外层。每次生成底包或
导出游戏都创建随机 AES-256 key 和 nonce，再由对应平台的 Runtime RSA-3072 公钥以
OAEP-SHA256 封装 AES key。APK 签名证书与游戏包加密密钥彼此独立，因此重签 APK 不会
改变解密结果。两个平台都不在协议不匹配时回退明文。

Android 的 RSA、AES-GCM 和 PME1 解析全部位于未公开的 Go 密码模块。主 App 的同一份
Go AAR 只包含加密端和公钥；Runtime 的同一份 Go AAR 才包含独立 Android 私钥和解密
入口。Java MethodChannel 只从固定的
`flutter_assets/assets/runtime/game.pmp` 读取密文并转发给这份 AAR，Dart 不接收 AES
key，也不允许调用方指定其他资源路径。每次构建必须扫描主 App AAR/APK，禁止 Android
私钥、PEM 或私钥生成中间文件进入主 App。

离线加密只能提高直接解压和批量搬运的门槛，不能对掌控终端的逆向者提供绝对保密；
真正的强保密仍需要在线授权或密钥服务。

### Android `aes-gcm-v1` / RSA-OAEP-SHA256 合同

Android 使用独立于 Windows 的 RSA-3072/65537 密钥对，PME1 布局、AES-256-GCM、空
AAD、每包随机 32 字节 AES key 与 12 字节 nonce 与 Windows 一致。Android 专属字段为：

```text
OAEP label = UTF-8("Playmesh Android Runtime Package Key v1")
OAEP hash = SHA-256
MGF1 hash = SHA-256
keyId = "android-rsa-oaep-sha256-v1:"
        || base64url-no-pad(SHA-256(DER SubjectPublicKeyInfo))
        || ":"
        || base64url-no-pad(RSA-OAEP-wrapped AES key[384])
```

模板 `runtime-contract.json` 必须同时携带 Android 与 Windows 的 scheme 和公钥指纹。
导出器必须在注入前校验 Android 字段；缺失、旧 scheme 或指纹不匹配都直接拒绝，不能
生成一个安装后才发现无法解密的 APK。

### Windows `aes-gcm-v1` / RSA-OAEP-SHA256 跨语言合同

Windows 动态导出继续使用与 Android 相同的 PME1 外层，不增加平台专用密文格式。每次
导出都生成独立的 AES key 和 nonce，再使用模板对应的 RSA 公钥封装 AES key：

```text
game.pmp = ASCII("PME1") || nonce[12] || ciphertext[N] || tag[16]
payload algorithm = AES-256-GCM
AAD = empty

aesKey = CSPRNG(32)
nonce = CSPRNG(12)
spkiDigest = SHA-256(DER SubjectPublicKeyInfo)
wrappedAesKey = RSA-OAEP-SHA256(
                  publicKey,
                  aesKey,
                  label = UTF-8("Playmesh Windows Runtime Package Key v1"),
                  MGF1 = SHA-256
                )

keyId = "win-rsa-oaep-sha256-v1:"
        || base64url-no-pad(spkiDigest[32])
        || ":"
        || base64url-no-pad(wrappedAesKey)
```

OAEP 主哈希和 MGF1 哈希都固定为 SHA-256。label 必须是上述字符串的准确 UTF-8 字节，
不附加 NUL 或其他终止符。`spkiDigest` 对完整 DER 编码的 SubjectPublicKeyInfo 求哈希，不能
改为 PKCS#1、公钥文本或证书哈希。密钥必须恰好为 RSA-3072、公钥指数必须为 65537，
`wrappedAesKey` 解码后必须恰好为 384 字节。AES key 与 nonce 都必须由系统 CSPRNG 在
每次导出时重新生成，不能按游戏 ID、时间、模板哈希推导，也不能在不同产物间复用。

`keyId` 是公开的传输元数据。Dart Runtime 只把它完整、原样交给 Windows MethodChannel；
C++ 薄宿主只从当前 EXE 对应的固定
`data/flutter_assets/assets/runtime/game.pmp` 读取密文，并把密文与 `keyId` 转交根目录的
`playmesh-runtime-crypto.dll`。私有 Go DLL 完成 scheme、字段、base64url、SPKI 摘要、
RSA-OAEP、PME1 和 AES-GCM 的全部验证与解密，再把已认证的明文 ZIP 经 C++ 返回 Dart。
私钥和解封装后的 AES key 都不跨出 Go 模块，Dart 也不读取密文或执行密码算法。

私钥源文件只允许位于已被 `.gitignore` 排除的 `runtime/crypto/`，构建时嵌入 Windows
Runtime 专属 Go DLL。不得把私钥作为独立文件放入分发 ZIP、`flutter_assets`、主 App 或
导出请求。主 App 的公开 Windows 导出器只保留 ZIP/合同逻辑并调用私有 Go provider；其
发布产物只有加密端和公钥，绝不能携带 Runtime DLL 或任一平台私钥。
主 App 和导出器只持有对应的 DER SPKI 公钥及其摘要。每套 Runtime 模板应有自己的密钥对；
一旦某个模板私钥泄露，所有复用该密钥对的历史和未来导出包都应视为可离线解密并安排轮换。
密钥轮换必须原子更新 Runtime 内嵌私钥、模板 `runtime-contract.json` 指纹、Go Core 内嵌
公钥和主 App 导出器，不能只替换其中一项。旧主 App 必须明确拒绝新密钥模板，新主 App 也
必须明确拒绝旧密钥模板；不能在指纹不匹配时回退到明文、旧 KDF 或跳过合同校验。

`runtime_config_test.dart` 验证 Dart 只把完整 RSA `keyId` 交给平台宿主并接收明文 ZIP。
生产私钥不进入公开测试或文档；Windows 原生桥测试使用固定的 Go RSA/PME1 向量验证 DLL
互操作、错误 keyId 和篡改 tag，并在安装目录再次解密本次构建的占位游戏，不能只依靠某一
实现内部的自生成回环测试。

这个方案消除了旧版“用公开 EXE 哈希和 salt 直接推导 key”的离线公开公式，但不等于终端
上的绝对保密。私钥最终存在本机原生二进制中，AES 明文和 key 也会在运行时内存出现；有
能力的攻击者仍可通过原生逆向、API Hook、调试或内存抓取获得它们，也可补丁或替换整个
Runtime。AES-GCM 只能在攻击者尚未取得私钥或运行时控制权时校验密文完整性，不能证明游戏
包来自 Playmesh。若要更强源码保密，需要设备绑定或在线密钥服务；若要验证发布者身份，
需要独立的载荷签名与可信公钥。Windows 代码签名可保护外层发行来源，但不能阻止游戏运行
后被本机提取。

## 固定包的可选中转

可在游戏包内的 `playmesh-runtime.json` 中预置一个 go-server HTTP/HTTPS publicURL，并
通过 `autoApproveCapabilities` 布尔值控制导出程序是否由 SDK 内部直接完成 Playmesh
能力确认。该值只经私有 bootstrap 字段传递，消费后从公开环境删除。
Runtime 发布游戏时先保留 LAN 分享，再尽力连接配置的公共中转；中转失败不会破坏
局域网分享。

该文件与游戏代码处于同一个包载荷中，后续导出只替换这一份配置；启用
`aes-gcm-v1` 后会与游戏代码一起加密，不在明文 `runtime-config.json` 中出现。

publicURL 的 `token` 会随游戏包加密，能避免直接解压读取，但 Runtime 仍必须具备解密
能力，因此它不能成为长期高权限秘密。生产环境应使用无秘密的受限公共 relay，或由
服务端签发短时、限额、可撤销的发布凭据。

## 构建

```powershell
cd runtime/src
./tool/build_runtime_packages.ps1
```

统一脚本串行构建并验证 Android x86_64、Android arm64-v8a 与 Windows x64。Windows
固定使用文档记录的 HostX64 MSVC + Ninja 备用链，不经过本机可能卡死的 MSBuild
生成器。版本唯一来源是本目录 `pubspec.yaml` 的 `MAJOR.MINOR.PATCH+BUILD`，产物位于：

```text
../resource/vMAJOR.MINOR.PATCH-buildBUILD/
  playmesh-runtime-x86.apk
  playmesh-runtime-arm.apk
  playmesh-runtime-win.zip
  runtime-packages.json
```

相同版本目录默认禁止覆盖；开发期确认需要重建同一版本时显式传 `-Force`，正式发布应
提升 `pubspec.yaml` 版本。清单记录真实平台/ABI、文件长度与 SHA-256。Windows 必须以
完整 ZIP 分发，不能只复制其中的 `playmesh-runtime.exe`。

若某个平台构建失败，阶段目录会保留已验证产物。修复原因后使用
`./tool/build_runtime_packages.ps1 -Resume` 从未完成的平台继续；它会重新验证而不会
盲目信任已有 Android APK。`-Resume` 只用于同一次版本构建，源代码或 SDK 已变化时应
重新完整构建，不得复用旧阶段产物。

仍可用底层入口单独构建：

```powershell
./tool/build_runtime.ps1 -Target android -AndroidArchitecture arm64
./tool/build_runtime.ps1 -Target windows
```

Runtime 不保存 Game SDK / App SDK 的源码快照。`build_runtime.ps1` 会先运行主 App 的
`tool/generate_sdk.mjs`，再把主 App `assets/playmesh-library/public/sdk/v1/` 中的四个
正式 SDK 产物以临时硬链接放入 Flutter asset 目录；Android/Windows 编译结束或失败后都会
清理这些链接。`-SkipSdkGeneration` 只跳过生成步骤，仍会从主 App 当前产物建立临时链接，
因此 Runtime 始终只有一个 SDK 内容来源。

Android release 启用 R8、资源收缩和 Go `-s -w -trimpath`；Windows Go Core 同样去除
符号并作为 `playmesh-core.exe` 随 Runtime 分发。符号映射不会进入底包。

提交固定底包前至少运行：

```powershell
flutter analyze
flutter test
cd ../../go-core
go test ./...
```

Android 集成验证使用 x86_64 AVD；当前内置 SDK 检测台的自身检测预期结果为
`14 通过 · 0 条件 · 0 失败`。相机、麦克风、MIDI、振动、Pose6D、扫码和跨设备联机
仍需在具备相应权限、硬件或第二客户端的环境中单独验证，不能由 AVD 自身检测结果替代。
