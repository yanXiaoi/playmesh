const playmeshVersion = '2.2.0';
const playmeshBuildNumber = 21;

const playmeshReleaseHighlights = <String>[
  'Game SDK 与 App Bridge SDK 改为 Dart 唯一手写源，同一 feature 集中维护网页片段、类型声明与宿主执行器。',
  'App 运行时直接从统一注册表组装最新 JavaScript 和类型声明，重新运行或打包即可生效。',
  '游戏资源网关、分享网关、Developer Gateway、SDK 下载和 AI 提示均禁止绕过统一 SDK 注册表。',
  '新增明确的 SDK 多版本兼容发行范围；已安装旧游戏按清单版本选择兼容实现，未知版本会被拒绝。',
  '正式 Android 与 Windows 构建会自动生成并校验 SDK 静态产物，不再要求日常手动执行生成命令。',
  'Game SDK 升级到 2.2.2，App Bridge SDK 升级到 2.1.1，Developer API 升级到 2.1.0。',
];
