# WebView 原生下载

此项是宿主兼容性修复，不新增公开 SDK 方法、不升级 Game SDK 或 App Bridge SDK。
主 App 和独立 Runtime 共用 `packages/playmesh_file_system_access` 的下载管理器和
Flutter 叠加层。普通浏览器继续使用浏览器下载功能。

## 用户行为

- WebView 检测到下载时自动弹出系统保存选择器，由用户选择名称和位置。取消选择不会开始保存。
- 支持普通 HTTP(S) 文件下载和网页通过 `<a download>` 导出的 Blob / data URL。
  普通页面导航不作为下载，视频播放也不会因为扩展名是 `.mp4` 就弹出保存框。
- 有任务后在 WebView 右上方显示原生下载按钮；列表包含全部、下载中和已完成筛选。
  详情显示状态、字节数、进度、保存位置、来源、创建/结束时间和错误。
  来源展示去掉用户名、密码、查询参数和 fragment，避免直接展示签名凭据。
- 下载按钮旁的关闭按钮可手动隐藏悬浮入口，不影响进行中的下载或内存历史。
  已有任务的进度和完成事件不会重新显示入口；新增下载任务或重新打开游戏后再次显示。
- 历史只保存在进程内存，以真实 `gameId` 隔离。重开相同游戏可查看本进程历史，
  重启进程后清空；无游戏 ID 的独立页面使用独立队列。
- App 按单游戏实例流程运行。关闭当前游戏 WebView 时，取消全部等待选择、排队和
  传输中任务；已完成的文件保留，取消记录保留在该游戏的内存历史。按 `gameId` 分组
  用于切换游戏和重新打开游戏后的历史展示，不引入多游戏实例。队列只存元数据，
  不缓存完整下载内容。

## Windows

仓库内 `webview_flutter_windows` 在 WebView2 `DownloadStarting` 时隐藏默认下载 UI，
取得 deferral，然后将 `IFileSaveDialog` 调度到事件返回之后打开。选定路径后才允许
原来的下载继续，因此 Cookie、POST 请求和 Blob 由 WebView2 自己处理。
同一 WebView 的系统保存框依次打开；已选择目标的下载可以并行传输。

原生事件附带每实例递增任务 ID，Flutter 再添加宿主实例 ID，同一个 URL 重复下载也不会
合并。完成、取消、失败均为独立终态。销毁宿主时关闭保存框、取消活动下载、完成未处理的
deferral，并利用弱生命周期标记阻止回调访问已销毁对象。插件显式链接 `runtimeobject`，
用于在 UI 线程上调度保存框。

依据：[WebView2 下载事件参数](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2downloadstartingeventargs)
和 [WebView2 线程模型](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/threading-model)。

## Android

原生适配器使用 `DownloadListener` 与文档开始脚本。HTTP(S) 下载在用户选择保存位置后
通过 Dart `HttpClient` 流式读取；每次重定向重新从 Android CookieManager 取得目标 URL
的 Cookie，不向新域转发前一站的 Cookie。网页导出通过有确认的 256 KiB 分块传输，
点击后立即读取 Blob，兼容紧接着执行 `URL.revokeObjectURL()` 的导出写法。

保存复用现有 SAF 文件系统桥：先写临时文件，完成后提交到用户选择的目标；中断时关闭
连接、丢弃临时写入。保存框返回前若页面已经导航或关闭，返回的句柄只释放，不启动写入。
每个 WebView 串行处理 Android 下载；取消和错误释放资源后才调度下一项。

Android `DownloadListener` 只给出 URL、User-Agent、Content-Disposition、MIME 和长度，
不提供原请求的 POST body 或自定义认证请求头。因此直接由 POST 响应触发的下载、只接受
一次请求的 URL，或必须带自定义请求头的下载不能保证重放成功；这类网页应先获取响应并以
Blob 导出。Android Blob 自动拦截目前限于顶层文档；文件选择器可能在目标提供方创建空文件，
中断后不会擅自删除用户选择的目标。下载队列本身不写入数据库、偏好设置或磁盘。

依据：[Android DownloadListener](https://developer.android.com/reference/android/webkit/DownloadListener)。

## 验证

- `test/core/game_web/webview_downloads_test.dart`：文件选择、分块写入、HTTP Cookie、任务串行、
  导航/关闭时的活动与等待任务取消、迟到选择结果、异常消息、Windows 任务 ID 和游戏隔离。
- `test/features/game/webview_download_overlay_test.dart`：手机/桌面布局、列表、详情和来源脱敏，
  手动隐藏不取消任务、进度更新保持隐藏、新增任务恢复入口。
- `tool/test_webview_downloads.mjs`：普通导航、脱离 DOM 的下载链接、立即撤销 Blob、分块和取消。
- Android 原生源码编译检查与 Windows C++ 源码检查通过；SDK 既有文件系统契约与 Bucket
  HEAD 回归独立运行。原生改动需要重新编译 App / Runtime；系统保存框、覆盖写入及实际平台
  下载取消仍需 Windows / Android 实机验收，单元测试不能替代该验收。
