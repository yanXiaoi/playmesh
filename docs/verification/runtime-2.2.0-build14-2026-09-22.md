# Runtime 2.2.0+14 构建验证（2026-09-22）

## 范围与结果

按 `runtime/src/tool/build_runtime_packages.ps1` 从同一源码串行完整构建 Android x86_64、
Android ARM64、Windows x64，未使用旧阶段包或 `-Resume`。三端均包含 Bucket HEAD/Range、
原生下载队列、任务详情、手动隐藏下载入口和退出取消。Game SDK `4.3.0`、App Bridge SDK
`3.5.0`、Go Core `0.7.1` 和 Core 协议 `1.6.0` 保持不变。

## 制品

| 文件 | 平台/架构 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `playmesh-runtime-x86.apk` | Android x86_64 | 59,362,167 | `fcb4e500d58fc709fd88d4e081ec6ee842c79926753705a47cf582f76b518a47` |
| `playmesh-runtime-arm.apk` | Android ARM64 | 51,973,000 | `b788963c40157c3f1f66335be93751035104e179103fd92f0d88c506379612ad` |
| `playmesh-runtime-win.zip` | Windows x64 | 20,710,940 | `1bcb5c0b2e530c2d0f387ec2b284a93f6d5687bcfe30472c68ee28a6b2f9605f` |

版本归档为 `runtime/resource/v2.2.0-build14/`，清单生成时间为
`2026-09-22T11:05:05.6199876Z`。构建脚本在全部门禁成功后，逐字节同步三个包到
`resources/runtime/`，并更新 `update.json` 的版本和平台 SHA-256。

## SDK 同源检查

构建先从主 App 唯一来源生成 SDK，再以临时硬链接提供 Runtime assets。三个包及阶段
清单中的四个文件与主 App 一致，并与上一稳定发行的 SDK 哈希相同：

| SDK 文件 | SHA-256 |
| --- | --- |
| `playmesh-main.js` | `842983bbc9138fff355431473f1a493225d820e6c76d4c78b6bd36ffe2b51b77` |
| `playmesh-main.d.ts` | `e12b662491ccf258635eec3e881fcd897a6e7233c418560090f58573b02cb9bf` |
| `playmesh-app.js` | `b9c7f83115b6e3f2d480df9506a4feeb54f3dc0758128c446068194da7209a92` |
| `playmesh-app.d.ts` | `3c7806d835ebbd61346233a240834c58fa76c6a9b1a54b792e61fa706ad23123` |

## 门禁与测试

- Android：两个包均通过目标 ABI 唯一性、APK Signature Scheme v2、16 KiB ZIP 对齐、
  加密包结构、私钥/源码排除和 SDK 哈希检查。底包签名用于模板构建校验，不代表导出应用
  的生产签名；最终独立应用仍按导出流程签名。
- Windows：HostX64 MSVC + Ninja 构建通过，包含 `playmesh-runtime.exe`、
  `playmesh-runtime-crypto.dll`、`playmesh-core.exe`、Flutter/WebView2 必需运行库和
  加密载荷。私有 Go 解密桥测试、安装目录解密、ZIP 结构与 SDK 哈希检查均通过。
  EXE FileVersion 与 ProductVersion 均为 `2.2.0+14`。Android 两包另用 aapt 验证
  `versionName=2.2.0`、`versionCode=14` 与目标 ABI。
- Runtime `dart analyze lib test`：零问题；`flutter test --no-pub`：93 项通过。
- Go Core `go test ./...` 通过；平台构建还执行了移动端与 Runtime 解密模块测试。
- 主工程的真实 HTTP Bucket/网关回归覆盖两端 HEAD、单段/多段 Range、If-Range、
  416、缓存与鉴权边界。下载 Widget 检查包含隐藏后下载继续、已有进度不唤醒入口和新任务恢复。

## 环境与验证边界

- 使用项目指定 Flutter、Go、Android SDK Build Tools `36.0.0` 和本机原生工具链，
  平台构建在沙箱外串行执行；仅在本次构建进程设置文档中的 Java 套接字临时目录。
- 首轮构建后的属性复核发现 Windows EXE 仍为 `1.0.0+1`：Ninja 已传入版本参数，
  Runtime CMake 却没有覆盖 Flutter 旧生成配置。修复参数传递并加入版本门禁后，对尚未
  发布的 build14 使用 `-Force` 完整重建三个平台，未复用第一轮包；上表只记录最终产物。
- Android 仍有 Built-in Kotlin 未来兼容提示，Windows 仍有警告级别覆盖提示；本次未造成
  构建或门禁失败。首轮 Windows 未使用版本变量的警告已随版本配置修复消失。
- 本轮没有安装并操作 Android/Windows 独立应用，系统保存框、覆盖写、媒体拖动和实际
  下载退出中断尚未完成实机验收。用户要求正式发布不等于上述验收已经通过。
- 旧导出应用需重新导出、安装以取得新 Runtime。回滚须同时恢复三个固定包和下载清单。

发布版本与兼容限制见 [Playmesh 5.2.0](../version/5.2.0.md)。
