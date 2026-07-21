# Playmesh 1.2.0 在线游戏源验证（2026-07-18）

## 验证范围

- Catalog API `1.0.0` 的 Bearer 鉴权、分页、名称/标签/描述搜索和完整 Manifest 返回。
- `/apps/download` 标准游戏包导出、下载和接收端安全再导入。
- 多个启用源并发请求、单源失败隔离和按游戏 ID 去重。
- Host/Token、开关、默认获取数量和二维码配置持久化。
- 多选下载队列的成功、进度、停止、删除和退出等待收尾。
- 现有游戏库内唯一在线入口、设置页简略版本日志和 App `1.2.0+3` 文案。

## 自动验证

| 验证项 | 结果 |
| --- | --- |
| Dart 格式化 | 通过，`lib` 与相关测试无剩余格式变化 |
| Flutter 静态分析 | 通过，0 个诊断，4.2 秒 |
| Catalog/游戏库/设置/Manifest 定向测试 | 通过，22 项，10.4 秒 |
| Flutter 完整测试 | 通过，97 项，18.9 秒 |

Catalog 定向测试使用真实本机临时 HTTP Server 和临时游戏库，确认无 Token 返回 `401`、正确 Token 返回搜索结果和 ZIP，下载文件能再次通过 `GamePackageTransferService` 安装。双源测试使用请求屏障确认两个源同时到达服务端，避免把串行请求误判为并发。

## 验证中修正

- 初次队列测试发现关闭控制器时会先释放 `ChangeNotifier`，活动下载完成后的异步回调仍可能刷新队列。现已改为先取消请求并等待处理循环结束，再释放通知器。
- 一次将 `flutter analyze` 与 `flutter test` 并行启动后，两者争用 Flutter SDK lockfile 并长时间无输出；该轮按 60 秒规则中止，确认没有本轮遗留进程后改为串行执行并全部通过。规则已补充到 `docs/04-dev-env.md`。

## 后续平台构建

本功能验证完成时尚未执行平台构建；随后已按用户明确要求完成 Android Release APK 与 Windows x64 Release 便携 ZIP，记录见 `docs/verification/playmesh-1.2.0-release-build-2026-07-18.md`。iOS、macOS 和 Linux 仍未构建；真机扫码权限、二维码配置、局域网防火墙提示、多地址选择和大文件下载体验仍需在目标平台手工验证。
