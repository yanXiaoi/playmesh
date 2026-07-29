# Playmesh 下一版本临时更新日志

## 状态

- 状态：`3.1.0` 已发布，当前存在未发布的 App 兼容修复；发布版本号与构建号待定。
- 当前发行基线：App `3.1.0+24`、Go Core `0.5.0`、Core 协议 `1.3.0`、
  Game SDK `3.1.0`、App Bridge SDK `3.0.0`、Catalog API `2.0.0`、
  Relay 协议 `2.0.0`、Developer API / OpenAPI `2.3.0`、Developer CLI `1.4.0`。
- 最新详细日志：`docs/version/3.1.0.md`。

## 未发布变更

- 修复 App 加入端加载权威主机游戏或单屏多人控制器时，虽已通过
  `controllerRequired` 声明并获得系统摄像头/麦克风权限，WebView 仍因没有接通权限
  回调而拒绝 `getUserMedia()` 的问题。
- Android、iOS 与 macOS 加入端现在按权威页面下发的最新运行时能力声明处理 WebView
  摄像头、麦克风和 MIDI SysEx 权限；Windows 加入端改为读取 App Bridge 的运行时
  声明，不再使用构造阶段的空能力数组。
- App WebView 敏感权限改为统一能力注册表模型：统一层按当前页面角色声明把请求资源
  映射为现有能力 code，检查插件可用性，再按 code 调用能力注册时绑定的唯一平台授权
  执行器。执行器不再维护额外 ID，也不负责路由或声明判断；本地页、加入页、Windows
  WebView 和 Android Activity 不再维护摄像头、麦克风或 MIDI 的外部 switch。普通
  浏览器不进入 App 原生权限执行链；新增权限型能力只需注册资源映射与唯一执行器，
  系统静态权限声明仍按平台要求同步配置。
- 加入端开始新导航时立即清除上一页面的动态能力声明和确认状态，避免旧页面权限被
  后续页面短暂沿用；未知、未声明或平台不支持的权限继续默认拒绝。
- Android 加入端补齐网页文件选择器接入，与本地游戏 WebView 保持一致，文件选择仍由
  用户主动触发且不申请存储权限。
- 新增动态权限声明、权限重置及加入端跨平台权限接线回归测试；全量
  `flutter test` 共 308 项通过，`flutter analyze lib test` 无问题，
  `flutter build apk --debug` 构建成功。摄像头、麦克风系统弹窗及 Windows WebView2
  行为仍需目标平台真机/实机验收。
