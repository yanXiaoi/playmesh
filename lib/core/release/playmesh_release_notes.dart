const playmeshVersion = '1.8.2';
const playmeshBuildNumber = 15;

const playmeshReleaseHighlights = <String>[
  '修复单屏多人角色能力串用：权威显示端只读取 required，控制器只读取 controllerRequired；显示端为空时不再弹能力确认。',
  '旧游戏缺少作者或最后上传时间时仍可进入游戏库；其他清单错误只要能识别 ID，也会保留为待修复项目。',
  '新增仅存本机的最近打开时间，游戏库默认按最近打开排序，删除游戏时同步清除记录。',
  '开发者工作区与 CLI 可无语义校验拉取损坏项目，便于在无法运行时修复；运行和发布仍执行完整校验。',
  '导入导出统一复用固定临时文件并在操作前后清理，避免临时文件持续累积。',
  '单屏多人新增独立控制器方向，App WebView 与普通浏览器全屏时按主画面或控制器角色锁定横竖屏。',
  'main.json 新增只读作者与最后上传时间；上传时由当前 App 昵称和 Unix 毫秒时间戳统一注入，详情页按设备时区紧凑展示。',
  'capabilities.json 拆分主画面 required 与控制器 controllerRequired，运行时按当前页面角色授权能力。',
  'Agent/CLI 发布接入开发者本地历史，整包替换可恢复 main.json、capabilities.json 与 app/。',
  'Game SDK 2.2.1、App Bridge SDK 2.1.0、Developer API 1.6.1、Developer CLI 1.3.1。',
];
