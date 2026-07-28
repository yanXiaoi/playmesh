# Playmesh 3.0.0 输入与焦点审计清单

日期：2026-07-26

本清单记录 App 路由、App 覆盖层、App 内 Developer Workspace、Game SDK
注入 UI 和 go-server Web 的可交互入口。它是实现审计，不替代 Android TV
真机、触摸设备和浏览器端到端验收；正式执行结果记录在本版本最终验证记录中。

## 统一输入与返回规则

| 意图 | 触摸/鼠标 | 键盘 | Android TV | 关闭后的焦点 |
| --- | --- | --- | --- | --- |
| 移动焦点 | 点击、滚动 | `Tab`、`Shift+Tab`、方向键 | DPAD 方向键 | 保持当前业务项；离屏时滚动到完整可见 |
| 激活 | 点击/轻触 | `Enter`、`Space` | DPAD Center / Select | 留在当前控件，或进入新路由/上层 |
| 返回 | 系统返回、关闭按钮 | `Escape`、Browser Back | Back | 先回到打开当前层的控件，再允许路由返回 |
| 打开游戏工具 | 悬浮球、工具按钮 | `F10`、Menu | Menu；无 Menu 时使用可聚焦悬浮球 | 关闭菜单后回到悬浮球 |
| 移动游戏工具 | 拖动 | `Alt+M` 后方向键，`Enter` 保存、`Escape` 取消 | 菜单进入移动模式后 DPAD，Center 保存、Back 取消 | 悬浮球 |
| 搜索 | 点击搜索框 | `Ctrl/Cmd+F` 后输入，`Enter` 立即查询 | 聚焦搜索后使用系统输入法 | 搜索框；清除后仍回到搜索框 |

原始键值只由 `PlaymeshShortcutRegistry` 解析。页面通过 Intent/Action 响应；
游戏 WebView 获得焦点时，运行页的全局硬件入口也调用同一注册表。
`PlaymeshFocusPolicy` 负责方向遍历后的 `ensureVisible`。
`PlaymeshFocusRestorationController` 在异步本地游戏列表和游戏源列表中分别以
`gameId`、`sourceId` 登记节点；刷新或重排后恢复同一业务 ID，删除后选择原项
之后、之前的最近可用项，最后才回退页面主操作。

## Flutter App 路由

| 路由/页面 | 可交互控件 | 触摸/鼠标入口 | 键盘/TV 入口 | 返回或刷新后的焦点 |
| --- | --- | --- | --- | --- |
| 首页 `/` | 资料；本地库标题、查看全部、游戏行/导入空状态；在线库；加入对局、开发者、资料、设置 | 点击按钮、标题、列表项 | 阅读顺序 Tab/DPAD；Enter/Center | 子路由关闭后回到原入口；首页不自动聚焦文本框 |
| 本地游戏库 `/games` | 在线库、导入、刷新；唯一搜索框、清除；错误重试；更新提示；每个游戏“查看详情” | 点击、下拉刷新、文件选择 | `Ctrl/Cmd+F`；Tab/DPAD；Enter/Center | `gameId` 稳定恢复并自动滚动；删除后最近项；搜索清除回搜索框 |
| 游戏详情 `/game-details` | 启动、导出、删除、清除数据、确认/取消 | 点击按钮 | Tab/DPAD；Enter/Center；Escape/Back 关闭确认 | Dialog 回触发按钮；页面返回回原游戏项 |
| 在线游戏库 `/games/online` | 首页/搜索 Tab；下载队列；管理源；每源重试、游戏项、加载更多；搜索输入、清除和结果；版本/源选择 | 点击、下拉刷新、滚动 | `Ctrl/Cmd+F` 切到搜索；Tab/DPAD；Enter/Center | Dialog 回触发按钮；分页/刷新保留当前业务项 |
| 游戏源管理 | 扫码、手工链接；源启用开关、详情、更多菜单、分享、编辑、删除；空状态添加 | 点击、扫码、输入链接 | Tab/DPAD；菜单方向键；Enter/Center；Escape/Back | `sourceId` 稳定恢复；删除后最近源；菜单回“更多” |
| 游戏源详情 | 刷新声明、编辑；所有表单和返回 | 点击、输入 | Tab/DPAD；Enter/Center；Back | 编辑 Dialog 回编辑按钮；页面返回回对应源 |
| 下载队列/版本选择 | 版本、来源、下载、停止、删除、关闭 | 点击按钮/列表项 | Dialog 焦点陷阱；Tab/DPAD；Enter/Center；Escape/Back | 回打开下载队列或升级提示的按钮 |
| 加入对局 `/join-game` | 邀请链接/代码输入、扫描、加入、重试 | 点击、扫码、输入 | Tab/DPAD；Enter 提交；Escape/Back | 扫描页回扫描按钮；失败重试保持可见 |
| 邀请/源扫码页 | 相机扫描、关闭/返回；对应页面保留手工输入 | 相机、返回 | Back；手工输入是无相机替代路径 | 回原“扫描”按钮 |
| 用户资料 `/profile` | 头像选择/移除、昵称输入、保存 | 点击、文件/图片选择 | Tab/DPAD；Enter/Center | 选择器关闭回头像操作；保存后回保存按钮 |
| 设置 `/settings` | 语言、主题；运行状态；开发者模式、端口/入口、工作区；Catalog 共享；各开关、输入和测试操作 | 点击、输入、滚动 | Tab/DPAD；Enter/Center；Back | Dialog 回触发按钮；Developer Workspace 返回回打开入口 |
| Developer Workspace | AppBar 返回、重新加载；WebView 内完整工作区 | 点击/触摸 WebView | AppBar 与 WebView 均可聚焦；WebView 内键盘见下表 | WebView 返回 Flutter 后回原 App 控件 |
| 本地游戏运行 `/game` | 系统返回；收起悬浮球；工具栏、更多；性能、分享、信息、日志、调试；设置；玩家/链接 Sheet | 点击、拖动悬浮球 | F10/Menu、Alt+M、Tab/DPAD、Enter/Center、Escape/Back | 最上层优先关闭；分享恢复游戏调用元素，缺失时回悬浮球 |
| 远程游戏运行 | 返回；悬浮球；性能、信息、日志、调试；玩家 Sheet、设置 | 点击、拖动 | 与本地运行页相同 | 最上层优先关闭，之后回悬浮球或游戏内容 |
| 独立 HTML/Windows WebView | AppBar 返回、刷新/运行容器；注入平台 UI | 点击 | 平台快捷键、Tab/DPAD、Enter/Center、Back | 平台层关闭后恢复网页元素或悬浮球 |

## Flutter 上层与平台覆盖层

| 上层 | 控件与替代路径 | 焦点陷阱与返回 |
| --- | --- | --- |
| Material Dialog | 确认、取消、关闭、表单、版本/源列表 | Flutter Route 限制焦点；Escape/Back 或按钮关闭并恢复触发点 |
| BottomSheet | 玩家、链接、运行信息和二级操作 | 上层先消费 Back；关闭后回打开 Sheet 的工具项 |
| PopupMenu | 游戏源“更多”等菜单项 | 打开聚焦首项；方向键遍历；关闭回菜单按钮 |
| Snackbar action | 重试/撤销类操作 | 可 Tab/DPAD 到达；完成后不把焦点移到隐藏 Snackbar |
| `GameToolDock` | 悬浮球、展开工具、更多菜单、全部二级项、移动模式 | 显式 FocusNode；展开进首项；收起/关闭回悬浮球；移动取消恢复原位置 |
| 分享覆盖层 | 关闭、二维码、链接及 App 提供的操作 | SDK 调用前同步记录网页活动元素；关闭恢复该元素，节点失效时回悬浮球 |
| 性能/信息/日志/调试层 | 关闭、复制、滚动和各操作 | Back 按 z-order 关闭；回对应工具项或悬浮球；日志正文保持原文 |

## Game SDK 注入平台 UI

| 注入层 | 可交互控件 | 键盘/TV | 返回目标 |
| --- | --- | --- | --- |
| 浏览器昵称确认/修改 | 昵称输入、确认、取消/关闭 | Tab、方向键、Enter、Escape | 游戏内容此前元素 |
| 能力确认 | 能力列表、同意、拒绝 | 焦点限制在当前层；Tab/DPAD、Enter、Back | 游戏内容或平台悬浮工具 |
| 收起悬浮工具/展开菜单 | 悬浮按钮、信息、日志、关闭、收起 | Tab/DPAD、Enter；Menu/F10 由 App 宿主接管 | 菜单关闭回悬浮按钮 |
| 信息层 | 关闭、可滚动内容 | Tab/DPAD；Escape/Back | 打开它的“信息”项 |
| Console 日志层 | 关闭、复制、清空、滚动 | Tab/DPAD；Escape/Back | 打开它的“日志”项；消息/级别/来源不翻译 |

SDK Shadow DOM 为菜单和上层实现循环焦点；隐藏元素不进入顺序。SDK 只本地化
App 提供的固定外壳，游戏名称、发布者、玩家昵称、API 数据和日志逐字显示。

## App 内 Developer Workspace

| 区域 | 可交互控件 | 键盘/TV | 返回目标 |
| --- | --- | --- | --- |
| 顶栏 | 项目选择、保存、运行、发布、AI、更多 | Tab/方向键；Enter/Space；菜单 Home/End/Escape | 菜单回触发按钮 |
| 项目选择层 | 搜索、项目列表、新建、复制、设置、删除 | 打开聚焦搜索；方向键遍历；Escape | 项目按钮；首次无项目时保持选择层 |
| 项目树 | 文件夹、文件、键盘上下文菜单、上传、复制/剪切/粘贴/移动/解压/删除 | Tab/方向键；Enter/Space；ContextMenu 或 Shift+F10 | 菜单回原树节点 |
| 编辑器 | CodeMirror 编辑、保存、补全、滚动 | 标准文本键；Ctrl/Cmd+S；Ctrl+Space/Alt+/ | Modal 关闭后回编辑器或原命令 |
| 运行/日志 | 运行、重启、停止、链接、复制/清空日志 | Tab/DPAD、Enter；链接可键盘打开 | 保持原运行命令 |
| 移动三视图 | 项目、编辑、运行 | Tab/DPAD、Enter | 切换后进入目标视图首个可用控件 |
| 所有普通 Modal | 表单、列表、保存、取消、关闭 | 打开聚焦指定主控件；Tab/Shift+Tab 和方向键陷阱；Escape | 打开 Modal 前的精确元素 |
| AI 审批 Modal | 允许一次、按项目、始终允许、拒绝 | 打开聚焦首个决定；循环焦点；Escape 不能绕过决定 | 审批完成/超时后回原元素 |
| 语言/主题偏好 | 语言清单、system/light/dark、关闭 | 选项完全来自 App 投影；循环焦点；Escape | 偏好按钮 |

拖放上传不是唯一入口：文件树上下文操作和隐藏文件选择器提供键盘路径。超过
50 项的项目、树、历史和日志节点使用分批渲染或 `content-visibility`，避免无界
首帧布局。

## go-server Web

| 页面 | 可交互控件 | 键盘/触控 | 返回规则 |
| --- | --- | --- | --- |
| 公共 Catalog | 语言、主题、登录/注册、源链接复制、筛选、分页、下载 | 原生按钮/链接/表单；Tab、Enter、Space | 登录层关闭回账号入口 |
| 用户门户 | 资料、上传密钥、ZIP 上传、游戏版本上下架/删除 | 原生表单和按钮；所有状态有 `aria-live` | 确认层回发起版本操作 |
| 管理登录 | 账号、密码、文字/算术/点选验证码、刷新 | 验证码支持方向键移动与 Enter 选择 | 登录失败回当前表单 |
| 管理后台 | 导航、审核、上下架、删除、设置、运行配置、语言、主题、退出 | 原生按钮/链接/表单；Tab、方向键、Enter | 操作完成保留当前导航和业务项 |

两套 Web 在样式表之前设置保存的/系统主题和浏览器语言，并在清单词典完成应用前
隐藏正文，避免错误主题或语言首帧闪烁。API code/message、动态名称和日志不因
locale 或主题改变。

## 仅手势/鼠标能力排除表

| 原交互 | 非触摸替代 |
| --- | --- |
| 拖动游戏悬浮球 | 工具菜单“移动工具位置”与 Alt+M/DPAD 移动模式 |
| 拖文件到工作区树 | 树上下文“上传文件”和文件选择器 |
| 右键文件树 | ContextMenu 键或 Shift+F10 |
| 扫描二维码 | 同页手工输入邀请链接或 `publicURL` |
| hover 提示 | 图标按钮同时具有可访问名称、tooltip 和可见焦点 |
| 下拉刷新 | AppBar 的显式刷新按钮 |

上述任一替代入口缺失、不可聚焦，或关闭后焦点落入隐藏/已删除控件，都应作为
FR-24 回归缺陷处理。
