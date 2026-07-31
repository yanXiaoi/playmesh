# Playmesh 4.0.0 发布验证记录

## 验证基线

- 日期：2026-07-31
- App：`4.0.0+26`
- Game SDK：`4.0.0`
- App Bridge SDK：`3.2.0`
- Developer API / OpenAPI：`4.0.0`
- Developer CLI：`2.0.0`
- Catalog API：`3.0.0`
- Relay 协议：`3.0.0`
- Go Core：`0.5.0`
- Core 协议：`1.3.0`

## 自动验证结果

| 验证项 | 结果 |
| --- | --- |
| `flutter analyze` | 通过，无问题 |
| `flutter test --no-pub` | 通过，共 `381` 项 |
| Game SDK Node 契约与浏览器契约 | 通过 |
| App Bridge SDK 契约 | 通过 |
| SDK TypeScript 声明与中文 JSDoc 契约 | 通过 |
| 默认 Authority 同步模板契约 | 通过 |
| 平台 UI 本地化源契约 | 通过 |
| Android Developer 通知本地化契约 | 通过 |
| Windows/Linux Developer CLI 跟随编译与产物命名契约 | 通过 |
| Developer CLI `go test ./...` 与 `go vet ./...` | 通过 |
| Go Core `go test ./...` 与 `go vet ./...` | 通过 |
| Go Server `go test ./...` | 通过 |
| Android/Windows 包内 13 项提示词与本地化资源 | 与当前工作树逐项一致 |

验证同时确认公开 Game SDK 文件为 `playmesh-main.js/.d.ts`，App SDK 文件为
`playmesh-app.js/.d.ts`；当前清单只接受 Game SDK `4.0.0` 与 App SDK `3.2.0`。
提示词中的命名空间、能力声明、平台角色和开发流程与同一 SDK 注册表生成的声明一致。

## 发布产物

- `Playmesh-4.0.0-build26-android-universal.apk`
- `Playmesh-4.0.0-build26-windows-x64-portable.zip`
- `Playmesh-4.0.0-build26-SHA256SUMS.txt`

Android 与 Windows 产物均通过发布资源快照校验。校验和文件由统一发布脚本在上传前
基于最终产物重新生成，并与两份二进制一起发布到 GitHub 和 Gitee Release。

## 仍需目标环境验收

- Android 相机、麦克风、MIDI、文件选择器、ARCore `sensor.pose6d` 和 WebRTC 媒体。
- Windows WebView2 权限、窗口化开发运行和完整桌面操作。
- 真实 Cocos Creator 3.x Editor 扩展、构建后运行和预览地址接入。
- 局域网多网卡、跨公网中转与长时间连接。
- macOS Keychain 和 Linux Secret Service 凭据保存。

这些项目不由当前 Windows 自动化测试替代；发现问题时按组件版本规则发布后续修复版。
