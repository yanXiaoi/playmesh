// @flow

export const PLAYMESH_MAIN_SDK_SCRIPT_PATH =
  '/playmesh/sdk/v1/playmesh-main.js';
export const GDEVELOP_FPS_PROBE_ENTRY =
  'static/js/service/playmesh-gdevelop-fps-probe.js';
export const GDEVELOP_MULTIPLAYER_BRIDGE_ENTRY =
  'static/js/service/playmesh-multiplayer-bridge.js';
export const GDEVELOP_AUTHORITY_ENTRY = 'static/js/service/index.js';

/*::
export type GDevelopMultiplayerActivation =
  | 'enabled'
  | 'disabled'
  | 'unknown';

export type PlaymeshMultiplayerRuntimeTextFile = {|
  relativePath: string,
  text: string,
|};
*/

const multiplayerCompatibilityScriptPaths /*: Array<string> */ = [
  GDEVELOP_FPS_PROBE_ENTRY,
  GDEVELOP_MULTIPLAYER_BRIDGE_ENTRY,
  GDEVELOP_AUTHORITY_ENTRY,
];

export const getPlaymeshSdkPlaceholderTag = () /*: string */ =>
  `<script src="${PLAYMESH_MAIN_SDK_SCRIPT_PATH}"></script>`;

export const getPlaymeshMultiplayerCompatibilityScriptTags = () /*: Array<string> */ =>
  multiplayerCompatibilityScriptPaths.map(
    path => `<script src="${path}"></script>`
  );

export const getPlaymeshMultiplayerRuntimeScriptTags = () /*: Array<string> */ =>
  [
    getPlaymeshSdkPlaceholderTag(),
    ...multiplayerCompatibilityScriptPaths.map(
      path => `<script src="${path}"></script>`
    ),
  ];

export const shouldInjectPlaymeshMultiplayerRuntime = (
  activation /*: mixed */
) /*: boolean */ => {
  if (
    activation !== 'enabled' &&
    activation !== 'disabled' &&
    activation !== 'unknown'
  ) {
    throw new Error(`未知的 GDevelop 多人启用状态：${String(activation)}`);
  }
  // Playmesh 预览和本地发布始终携带同一兼容层。是否真正联机由
  // canonical Bootstrap 在运行时依据 App 游戏信息与会话决定。
  return true;
};

export const detectGDevelopMultiplayerActivation = (
  project /*: ?gdProject */
) /*: GDevelopMultiplayerActivation */ => {
  try {
    const finder = global.gd && global.gd.UsedExtensionsFinder;
    if (!finder || typeof finder.scanProject !== 'function' || !project) {
      return 'unknown';
    }
    const usedExtensions = finder
      .scanProject(project)
      .getUsedExtensions()
      .toNewVectorString()
      .toJSArray();
    if (!Array.isArray(usedExtensions)) return 'unknown';
    return usedExtensions.some((name /*: string */) => name === 'Multiplayer')
      ? 'enabled'
      : 'disabled';
  } catch (_) {
    return 'unknown';
  }
};

const countExactOccurrences = (
  text /*: string */,
  fragment /*: string */
) /*: number */ =>
  text.split(fragment).length - 1;

const getClosingHeadIndex = (html /*: mixed */) /*: number */ => {
  if (typeof html !== 'string') {
    throw new Error('GDevelop 预览或发布的 HTML 无效。');
  }
  const closingHeadIndex = html.toLowerCase().lastIndexOf('</head>');
  if (closingHeadIndex === -1) {
    throw new Error('GDevelop HTML 缺少 </head>，无法安全注入运行层。');
  }
  return closingHeadIndex;
};

export const ensureSdkPlaceholder = ({
  html,
} /*: {|
  html: string,
|} */) /*: string */ => {
  const closingHeadIndex = getClosingHeadIndex(html);
  const sdkTag = getPlaymeshSdkPlaceholderTag();
  const count = countExactOccurrences(html, sdkTag);
  if (count > 1) {
    throw new Error('Playmesh Main SDK 占位脚本不能重复加载。');
  }
  if (count === 1) {
    if (html.indexOf(sdkTag) < closingHeadIndex) return html;
    throw new Error(
      'Playmesh Main SDK 占位脚本必须在 GDevelop 首个 RuntimeGame 创建前加载。'
    );
  }
  // The official exporter expands <!-- GDJS_CODE_FILES --> immediately before
  // </head>. This is therefore after all GDJS symbols exist and before the
  // body bootstrap constructs gdjs.RuntimeGame.
  return `${html.slice(0, closingHeadIndex)}${sdkTag}\n${html.slice(
    closingHeadIndex
  )}`;
};

export const injectMultiplayerCompatibility = ({
  html,
  activation,
} /*: {|
  html: string,
  activation: GDevelopMultiplayerActivation,
|} */) /*: string */ => {
  const closingHeadIndex = getClosingHeadIndex(html);
  const sdkTag = getPlaymeshSdkPlaceholderTag();
  const sdkCount = countExactOccurrences(html, sdkTag);
  if (sdkCount !== 1 || html.indexOf(sdkTag) >= closingHeadIndex) {
    throw new Error(
      '必须先在 GDevelop HTML 中确保唯一且正确排序的 Playmesh Main SDK 占位。'
    );
  }
  const scriptTags = getPlaymeshMultiplayerCompatibilityScriptTags();
  const counts = scriptTags.map((tag /*: string */) /*: number */ =>
    countExactOccurrences(html, tag)
  );
  if (counts.some((count /*: number */) /*: boolean */ => count > 1)) {
    throw new Error('Playmesh 多人运行层脚本不能重复加载。');
  }
  const presentCount = counts.filter(
    (count /*: number */) /*: boolean */ => count === 1
  )
    .length;
  shouldInjectPlaymeshMultiplayerRuntime(activation);
  if (presentCount === scriptTags.length) {
    const orderedPositions = getPlaymeshMultiplayerRuntimeScriptTags().map(
      (tag /*: string */) /*: number */ => html.indexOf(tag)
    );
    if (
      orderedPositions.every(
        (position, index) =>
          position >= 0 &&
          (index === 0 || orderedPositions[index - 1] < position)
      ) &&
      orderedPositions[orderedPositions.length - 1] < closingHeadIndex
    ) {
      return html;
    }
    throw new Error(
      'Playmesh 运行层必须按 main SDK、FPS probe、GDevelop bridge、canonical Bootstrap 顺序加载。'
    );
  }
  if (presentCount !== 0) {
    throw new Error('GDevelop HTML 只包含部分 Playmesh 多人运行层，拒绝继续注入。');
  }

  const compatibilityTags = multiplayerCompatibilityScriptPaths.map(
    path => `<script src="${path}"></script>`
  );
  return `${html.slice(
    0,
    closingHeadIndex
  )}${compatibilityTags.join('\n')}\n${html.slice(closingHeadIndex)}`;
};

export const getPlaymeshMultiplayerRuntimeTextFiles = ({
  fpsProbeSource,
  bridgeSource,
  authorityBootstrapSource,
} /*: {|
  fpsProbeSource: mixed,
  bridgeSource: mixed,
  authorityBootstrapSource: mixed,
|} */) /*: Array<PlaymeshMultiplayerRuntimeTextFile> */ => {
  if (
    typeof fpsProbeSource !== 'string' ||
    !fpsProbeSource.includes('playmesh.gdevelop.fps-probe.v1') ||
    !fpsProbeSource.includes('performanceApi.reportFrame()')
  ) {
    throw new Error('缺少 canonical GDevelop FPS probe。');
  }
  if (
    typeof bridgeSource !== 'string' ||
    !bridgeSource.includes('playmesh.runtime.backends.v1') ||
    !bridgeSource.includes('playmesh.gdevelop.multiplayer.coordinator.v1')
  ) {
    throw new Error('缺少 canonical GDevelop Multiplayer 私有 backend。');
  }
  if (
    typeof authorityBootstrapSource !== 'string' ||
    !authorityBootstrapSource.includes('playmeshGDevelopAuthorityBootstrap')
  ) {
    throw new Error('缺少 canonical GDevelop Authority Bootstrap。');
  }
  return [
    {
      relativePath: GDEVELOP_FPS_PROBE_ENTRY,
      text: fpsProbeSource,
    },
    {
      relativePath: GDEVELOP_MULTIPLAYER_BRIDGE_ENTRY,
      text: bridgeSource,
    },
    {
      relativePath: GDEVELOP_AUTHORITY_ENTRY,
      text: authorityBootstrapSource,
    },
  ];
};
