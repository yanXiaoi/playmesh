# Playmesh 1.6.2 OpenHarmony 构建验证（2026-07-22）

## 验证范围

- App：`1.6.2+9`（开发中，尚未正式发布）
- 目标：OpenHarmony API 12、`ohos-arm64`
- Flutter：OpenHarmony SIG Flutter `3.22.3`，revision `c44cfb3a15b27abcfd6056ff447d6256cde7bc19`
- Go：OpenHarmony SIG `go1.24.5.ohosv1r1`，固定 commit `2d8b23f6923100d8c90d8add9299da2c9d032a20`
- 构建模式：Release AOT、无生产签名的内部测试 HAP

## 执行命令

```powershell
.\tool\build_release.ps1 -Target harmony -AllowDebugSigning
```

统一脚本从干净的 `build/harmony-release/` staging 开始，依次完成 SDK 生成、Go Core 交叉编译、Dart 依赖解析、Flutter AOT、HAR/CMake/Ninja 和 HAP 打包。`-AllowDebugSigning` 只允许内部构建接收 `entry-default-unsigned.hap`；生产流程仍要求 `-HarmonySigningProfile` 并只接受签名 HAP。

## HAP 产物

本节记录独立 `-Target harmony` 构建当时的产物；随后执行的完整 `-Target all` 构建会重新生成同名 HAP。最新全平台产物与哈希见 [全平台构建验证](playmesh-1.6.2-all-build-2026-07-22.md)。

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| `Playmesh-1.6.2-build9-harmonyos-arm64.hap` | 33,424,471 字节 | `9367B8281CFF5E099B43D03016C3B2565C0DB7BC88EB2F1D99369815667ADCEE` |

包内关键条目检查通过：

| 条目 | 大小 |
|---|---:|
| `module.json` | 1,362 字节 |
| `resources.index` | 637 字节 |
| `libs/arm64-v8a/libapp.so` | 7,390,128 字节 |
| `libs/arm64-v8a/libplaymesh_core.so` | 6,686,200 字节 |
| `libs/arm64-v8a/libplaymesh_core_napi.so` | 175,832 字节 |

## Core 原生验证

- `libplaymesh_core.so`：ELF64、AArch64。
- SONAME：`libplaymesh_core.so`。
- 已导出 `PlaymeshCoreStart`、`PlaymeshCoreStop`、`PlaymeshCoreFree`。
- 自研能力 HAR 的 ArkTS、CMake、Ninja 与异步 Node-API 编译成功。
- 干净 staging 的模块列表不包含依赖 HMS `@kit.ScanKit` 的原生 `mobile_scanner` 模块。

## 自动回归

- `node tool/test_harmony_release.mjs`：通过。
- Go Core `go test ./...`：`health`、`server`、`session`、`mobile` 全部通过。
- `git diff --check`：通过，仅有现有 Windows 行尾提示。

## 已知边界

- 本次 HAP 未配置生产签名，不能作为应用市场发布物。
- 尚未执行 OpenHarmony/HarmonyOS 真机安装、网络、TLS、前后台切换、连续 Core 启停、传感器和系统分享验收。
- OpenHarmony Public SDK 不包含 HMS `@kit.ScanKit`。鸿蒙构建使用本地 Dart 兼容层显示手动输入提示，不宣称已支持系统扫码。
- Android `ACTION_VIEW` 外部文件接收未映射为鸿蒙能力；应用内文件选择仍由 `file_selector_ohos` 提供。
