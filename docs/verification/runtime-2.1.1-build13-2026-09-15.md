# Runtime 2.1.1+13 构建验证（2026-09-15）

## 范围与结论

按统一入口 `runtime/src/tool/build_runtime_packages.ps1` 构建 Android x86_64、Android
ARM64 与 Windows x64 固定底包。Runtime 从 `2.1.0+12` 升级到 `2.1.1+13`；Game SDK
`4.3.0` 与 App Bridge SDK `3.5.0` 不变。

最终包使用 Go Core `0.7.1`、Core 协议 `1.6.0` 与当前 Runtime 源码。Android 两包在同一
源码状态下完成后，Windows 阶段因审计暂停；确认 Runtime 没有写入精确 Core 协议校验且
源码、SDK 与 Android 暂存包输入未变化后，按脚本定义使用 `-Resume` 复用已校验 Android
暂存包并完成 Windows 构建。脚本最后重新校验全部三包后才覆盖固定资源和清单。

## 制品

| 文件 | 平台/架构 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| `playmesh-runtime-x86.apk` | Android x86_64 | 59,099,083 | `1f83a8d3f284ce1e33f727d66484103311f8a3e0f718872d96e91b78df8af418` |
| `playmesh-runtime-arm.apk` | Android ARM64 | 51,709,920 | `7021b2bd3f20a1dba25bd45919e8de373823e11e103a98458e603e6ffd389454` |
| `playmesh-runtime-win.zip` | Windows x64 | 20,602,182 | `869506dfac9da31ca8329dadd5e5b6f35e1602452532165a2193124783ebfcdf` |

版本归档为 `runtime/resource/v2.1.1-build13/`；`resources/runtime/` 的三个固定文件与归档
逐字节相同，`resources/runtime/update.json` 已写入同一版本与哈希。

## SDK 同源检查

构建先从主 App 唯一生成源重新生成 SDK，再以临时硬链接提供给 Runtime Flutter assets；
构建完成后临时文件被清理。三包与 `runtime-packages.json` 均核对：

| SDK 文件 | SHA-256 |
| --- | --- |
| `playmesh-main.js` | `842983bbc9138fff355431473f1a493225d820e6c76d4c78b6bd36ffe2b51b77` |
| `playmesh-main.d.ts` | `e12b662491ccf258635eec3e881fcd897a6e7233c418560090f58573b02cb9bf` |
| `playmesh-app.js` | `b9c7f83115b6e3f2d480df9506a4feeb54f3dc0758128c446068194da7209a92` |
| `playmesh-app.d.ts` | `3c7806d835ebbd61346233a240834c58fa76c6a9b1a54b792e61fa706ad23123` |

主工程新增 Runtime Game/App Bridge 支持命令集合与 `SdkFeatureRegistry` 完全一致的回归门禁。
这可阻止 Runtime 漏实现或私自增加宿主命令；平台适配行为仍由 Runtime 91 项测试与主工程
对应功能测试分别覆盖。独立 Runtime 按设计可跨兼容版本使用，不对 Core 健康响应做精确
协议版本锁定。

## 构建门禁

- Android：两个 APK 都只包含目标 ABI，APK Signature Scheme v2、16 KiB ZIP 对齐、
  加密包结构、禁止私钥/源码泄露和 SDK 哈希检查通过。
- Windows：HostX64 MSVC + Ninja 构建；私有 Go 解密桥测试、安装目录载荷解密、必需
  DLL/资源、可移植 ZIP 路径、私有文件排除和 SDK 哈希检查通过。
- 三包在发布前再次从暂存目录独立读取并校验；固定资源和两份清单只在全部成功后更新。

## 环境问题与限制

- 受限构建环境不能写外部 Go 缓存，使用已授权的本机工具链权限执行正式脚本。
- Gradle 在项目编译前出现 `Unable to establish loopback connection`。只为构建进程把
  `TEMP` 与 `TMP` 指向短路径 `C:\jtmp` 后成功；没有修改系统级环境变量、防火墙或仓库
  构建配置。
- Windows 依赖仍有 `/W3` 被 `/W4` 覆盖提示；Android 插件仍有 Flutter Built-in Kotlin
  未来兼容警告；两者本轮均未阻止构建和校验。
- 本次自动构建没有安装 Android 真机或模拟器，也没有运行 Windows 导出应用窗口；发布人
  随后确认已完成目标发布环境测试。具体设备、网络矩阵和原始日志未纳入仓库，因此该结论
  记录为发布人验收，不写成本自动构建独立复现。
- 三端固定资源已随 Playmesh `5.1.1+38` 稳定正式发行提交并公开；下载清单指向本次包。
