# Playmesh File System Access 桥实现

## 范围

本实现为 Windows 和 Android 内置游戏 WebView、独立 Runtime 提供标准
`showOpenFilePicker()`、`showSaveFilePicker()`、`showDirectoryPicker()`。它修复的是
WebView 平台实现虽然暴露函数、后续却以“不允许当前上下文”拒绝调用的问题，不把 API
伪装成不可用，也不改变普通浏览器的原生实现。

## 调用链

1. `app_file_system_access_feature.dart` 在检测到 Playmesh App Bridge 时覆盖三个全局函数，
   并把标准选项规范化为内部 `app.fileSystem.*` 命令。
2. `AppWebViewBridge` 和 `RuntimeAppBridge` 在打开选择器前消费一次宿主记录的可信用户操作。
3. `packages/playmesh_file_system_access` 在 Windows 使用 `file_selector`，在 Android 使用
   自有 Flutter 插件连接 Storage Access Framework。
4. 宿主只向网页返回随机 ID、`kind` 和 `name`。读取和写入每次最多传输 512 KiB；写入先
   落到临时文件，`close()` 才提交到用户选定目标，`abort()` 或页面销毁会删除临时文件。

## Android 边界

- 打开文件：`ACTION_OPEN_DOCUMENT`，支持单选和多选。
- 保存文件：`ACTION_CREATE_DOCUMENT`，使用 `suggestedName` 与 MIME 过滤。
- 选择目录：`ACTION_OPEN_DOCUMENT_TREE`，目录枚举和变更通过 `DocumentsContract` 完成。
- URI 授权只保存在原生插件；不把 `content://` 或推导出的设备路径发给游戏。

## 生命周期和错误

选择器取消返回 `user_cancelled`，网页映射为 `AbortError`；缺少用户操作映射为
`NotAllowedError`。不存在、类型不匹配、句柄失效分别映射到对应 DOMException。导航、
重载与 Bridge 关闭会清空句柄并中止所有未关闭的可写流。选择器本身不使用 30 秒 Bridge
超时，避免用户在系统对话框中停留较久时被误判为失败。

## 验证入口

- `node tool/test_file_system_access_sdk.mjs`
- `node tool/test_app_bridge_sdk.mjs`
- `node tool/test_sdk_declarations.mjs`
- `test/core/game_sdk/app_webview_bridge_test.dart`
- `runtime/src/test/runtime_app_bridge_test.dart`
