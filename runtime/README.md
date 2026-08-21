# Playmesh 独立运行底包

- `src/`：Android 与 Windows 共用的独立 Flutter Runtime 源码和原生宿主。
- `resource/`：最终发布的预编译底包资源；完成统一验证前不写入中间测试包。

本阶段只验证固定游戏底包。动态注入、加密、改包名和最终签名属于主 App 的后续导出链，
不在 Runtime 中执行。实现边界和模块说明见 `src/README.md`。
