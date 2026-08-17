// @flow
import PlaymeshGameManifest from '../PlaymeshShared/GameManifest';
import {
  detectGDevelopMultiplayerActivation,
  ensureSdkPlaceholder,
  GDEVELOP_AUTHORITY_ENTRY,
  getPlaymeshMultiplayerRuntimeScriptTags,
  getPlaymeshMultiplayerRuntimeTextFiles,
  injectMultiplayerCompatibility,
  shouldInjectPlaymeshMultiplayerRuntime,
} from '../PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection';

/*::
export type PlaymeshGameMode = 'solo' | 'multiplayer';
export type PlaymeshDisplayMode =
  | 'multi_screen'
  | 'single_screen_multiplayer';
export type PlaymeshOrientation = 'landscape' | 'portrait';

export type GDevelopGameManifest = {|
  id: string,
  name: string,
  author?: string,
  lastModifiedAt?: number,
  remarks: string,
  version: string,
  sdkVersion: string,
  appSdkVersion: string,
  orientation: PlaymeshOrientation,
  controllerOrientation?: PlaymeshOrientation,
  modes: Array<PlaymeshGameMode>,
  displayModes: Array<PlaymeshDisplayMode>,
  players: {|
    min: number,
    max: number,
  |},
  entries: {|
    game: string,
    controller?: string,
  |},
  tags: Array<string>,
  authority?: {|
    entry: string,
  |},
|};

export type GDevelopResourcesDownloadOutput = {|
  textFiles: Array<{| filePath: string, text: string |}>,
  blobFiles: Array<{| filePath: string, blob: Blob |}>,
|};

export type PlaymeshPackageTextEntry = {|
  filePath: string,
  kind: 'text',
  text: string,
|};

export type PlaymeshPackageBlobEntry = {|
  filePath: string,
  kind: 'blob',
  blob: Blob,
|};

export type PlaymeshPackageEntry =
  | PlaymeshPackageTextEntry
  | PlaymeshPackageBlobEntry;

type PlaymeshPackageEntryContent =
  | {| kind: 'text', text: string |}
  | {| kind: 'blob', blob: Blob |};

export type PlaymeshPackageFileMap = Map<string, PlaymeshPackageEntry>;

export type PlaymeshPackageEntryProducer = {|
  fileCount: number,
  entries: () => Iterator<PlaymeshPackageEntry>,
|};

type GDevelopGameIdOptions = {|
  randomValues?: Uint8Array => void | Uint8Array,
|};

type GDevelopMultiplayerActivation = 'enabled' | 'disabled' | 'unknown';
*/

export const GDEVELOP_DEFAULT_PACKAGE_NAME = 'com.example.gamename';
export { GDEVELOP_AUTHORITY_ENTRY };

export const isUnassignedGDevelopGameId = (
  value /*: mixed */
) /*: boolean */ => {
  const normalized = typeof value === 'string' ? value.trim() : '';
  return !normalized || normalized === GDEVELOP_DEFAULT_PACKAGE_NAME;
};

export const ensureGDevelopGameId = (
  project /*: gdProject */,
  options /*: ?GDevelopGameIdOptions */
) /*: string */ => {
  const current = String(project.getPackageName() || '').trim();
  if (!isUnassignedGDevelopGameId(current)) {
    if (!PlaymeshGameManifest.isAndroidPackageName(current)) {
      throw new Error('GDevelop packageName 不是有效的小写 Android 包名。');
    }
    return current;
  }
  const generated = PlaymeshGameManifest.generateGameId({
    profile: 'android',
    randomValues: options?.randomValues,
  });
  project.setPackageName(generated);
  return generated;
};

export const generateCopiedGDevelopGameId = (
  options /*: ?GDevelopGameIdOptions */
) /*: string */ =>
  PlaymeshGameManifest.generateGameId({
    profile: 'android',
    randomValues: options?.randomValues,
  });

export const getPlaymeshOrientationFromGDevelop = (
  project /*: gdProject */
) /*: PlaymeshOrientation */ => {
  const orientation = project.getOrientation();
  if (orientation === 'portrait' || orientation === 'landscape') {
    return orientation;
  }
  return project.getGameResolutionHeight() > project.getGameResolutionWidth()
    ? 'portrait'
    : 'landscape';
};

export const isGDevelopMultiplayerProject = (
  project /*: gdProject */
) /*: boolean */ => {
  const activation = detectGDevelopMultiplayerActivation(project);
  return (
    resolveGDevelopMultiplayerManifestMode({
      multiplayerActivation: activation,
    }) === 'multiplayer'
  );
};

export const resolveGDevelopMultiplayerManifestMode = (
  {
    multiplayerActivation,
    explicitMultiplayer,
  } /*: {|
  multiplayerActivation: GDevelopMultiplayerActivation,
  explicitMultiplayer?: ?boolean,
|} */
) /*: PlaymeshGameMode */ => {
  // 兼容层保守注入和包清单是两个维度：unknown 可以注入空操作运行层，
  // 但不能凭一次探测失败把普通项目提升为多人游戏。
  shouldInjectPlaymeshMultiplayerRuntime(multiplayerActivation);
  if (explicitMultiplayer === true) return 'multiplayer';
  if (explicitMultiplayer === false) return 'solo';
  return multiplayerActivation === 'enabled' ? 'multiplayer' : 'solo';
};

export const resolveGDevelopRuntimeActivation = (
  {
    multiplayerActivation,
    explicitMultiplayer,
  } /*: {|
  multiplayerActivation: GDevelopMultiplayerActivation,
  explicitMultiplayer?: ?boolean,
|} */
) /*: GDevelopMultiplayerActivation */ => {
  shouldInjectPlaymeshMultiplayerRuntime(multiplayerActivation);
  // 显式多人设置比扩展扫描更可靠；扫描为 disabled 时必须仍加载兼容层。
  return explicitMultiplayer === true && multiplayerActivation === 'disabled'
    ? 'enabled'
    : multiplayerActivation;
};

export const buildGDevelopGameManifest = (
  {
    project,
    gameId,
    sdkVersion,
    appSdkVersion,
    author,
    lastModifiedAt,
    mode = 'solo',
    displayMode = 'multi_screen',
    minPlayers = mode === 'solo' ? 1 : 2,
    maxPlayers = mode === 'solo' ? 1 : 5,
    gameEntry = 'index.html',
    controllerEntry,
    controllerOrientation,
    authorityEntry,
    tags = [],
  } /*: {|
  project: gdProject,
  gameId?: string,
  sdkVersion: string,
  appSdkVersion: string,
  author?: string,
  lastModifiedAt?: number,
  mode?: PlaymeshGameMode,
  displayMode?: PlaymeshDisplayMode,
  minPlayers?: number,
  maxPlayers?: number,
  gameEntry?: string,
  controllerEntry?: string,
  controllerOrientation?: PlaymeshOrientation,
  authorityEntry?: string,
  tags?: Array<string>,
|} */
) /*: GDevelopGameManifest */ => {
  const resolvedGameId =
    gameId === undefined ? ensureGDevelopGameId(project) : gameId.trim();
  if (!PlaymeshGameManifest.isAndroidPackageName(resolvedGameId)) {
    throw new Error('Playmesh gameId 不是有效的小写 Android 包名。');
  }
  return (PlaymeshGameManifest.buildGameManifest({
    id: resolvedGameId,
    name: project.getName(),
    author: author === undefined ? project.getAuthor() : author,
    lastModifiedAt,
    remarks: project.getDescription(),
    version: project.getVersion(),
    sdkVersion,
    appSdkVersion,
    orientation: getPlaymeshOrientationFromGDevelop(project),
    mode,
    displayMode,
    minPlayers,
    maxPlayers,
    gameEntry,
    controllerEntry,
    controllerOrientation,
    authorityEntry,
    tags,
  }) /*: GDevelopGameManifest */);
};

const normalizeExportFilePath = (rawPath /*: mixed */) /*: string */ => {
  const normalized =
    typeof rawPath === 'string' ? rawPath.replace(/\\/g, '/') : '';
  const displayPath = typeof rawPath === 'string' ? rawPath : '<non-string>';
  if (!normalized.startsWith('/export/')) {
    throw new Error(`GDevelop HTML 导出路径不在 /export/ 中：${displayPath}`);
  }
  const path = normalized.slice('/export/'.length);
  if (
    !path ||
    path
      .split('/')
      .some(segment => !segment || segment === '.' || segment === '..')
  ) {
    throw new Error(`GDevelop HTML 导出包含无效路径：${displayPath}`);
  }
  return `app/${path}`;
};

export const createPlaymeshPackageFileMap = (
  {
    resourcesDownloadOutput,
    manifest,
    iconBlob,
    fpsProbeSource,
    multiplayerBridgeSource,
    authorityBootstrapSource,
  } /*: {|
  resourcesDownloadOutput: ?GDevelopResourcesDownloadOutput,
  manifest: GDevelopGameManifest,
  iconBlob?: ?Blob,
  fpsProbeSource: string,
  multiplayerBridgeSource: string,
  authorityBootstrapSource: string,
|} */
) /*: PlaymeshPackageFileMap */ => {
  PlaymeshGameManifest.assertGameManifest(manifest);
  if (
    !resourcesDownloadOutput ||
    !Array.isArray(resourcesDownloadOutput.textFiles) ||
    !Array.isArray(resourcesDownloadOutput.blobFiles)
  ) {
    throw new Error('GDevelop HTML 导出结果无效。');
  }
  const fileMap /*: PlaymeshPackageFileMap */ = new Map();
  const add = (
    path /*: string */,
    entry /*: PlaymeshPackageEntryContent */
  ) /*: void */ => {
    if (fileMap.has(path)) {
      throw new Error(`GDevelop HTML 导出包含重复路径：${path}`);
    }
    if (entry.kind === 'text') {
      fileMap.set(path, {
        filePath: path,
        kind: 'text',
        text: entry.text,
      });
    } else {
      fileMap.set(path, {
        filePath: path,
        kind: 'blob',
        blob: entry.blob,
      });
    }
  };
  const isMultiplayer = manifest.modes[0] === 'multiplayer';
  resourcesDownloadOutput.textFiles.forEach(file => {
    if (!file || typeof file.text !== 'string') {
      throw new Error('GDevelop HTML 导出包含无效文本文件。');
    }
    const path = normalizeExportFilePath(file.filePath);
    const text =
      path === 'app/index.html'
        ? injectMultiplayerCompatibility({
            html: ensureSdkPlaceholder({ html: file.text }),
            activation: isMultiplayer ? 'enabled' : 'disabled',
          })
        : file.text;
    add(path, { kind: 'text', text });
  });
  resourcesDownloadOutput.blobFiles.forEach(file => {
    if (!file || !(file.blob instanceof Blob)) {
      throw new Error('GDevelop HTML 导出包含无效二进制文件。');
    }
    const path = normalizeExportFilePath(file.filePath);
    add(path, { kind: 'blob', blob: file.blob });
  });
  add(PlaymeshGameManifest.MAIN_MANIFEST_FILENAME, {
    kind: 'text',
    text: `${JSON.stringify(manifest, null, 2)}\n`,
  });
  if (isMultiplayer) {
    const authority = manifest.authority;
    if (!authority || authority.entry !== GDEVELOP_AUTHORITY_ENTRY) {
      throw new Error('GDevelop 多人清单的 Authority 入口不匹配。');
    }
    if (!fileMap.has('app/index.html')) {
      throw new Error('GDevelop 多人 HTML 导出缺少 app/index.html。');
    }
  }
  if (!fileMap.has('app/index.html')) {
    throw new Error('GDevelop HTML 导出缺少 app/index.html。');
  }
  getPlaymeshMultiplayerRuntimeTextFiles({
    fpsProbeSource,
    bridgeSource: multiplayerBridgeSource,
    authorityBootstrapSource,
  }).forEach(file => {
    add(`app/${file.relativePath}`, {
      kind: 'text',
      text: file.text,
    });
  });
  const mainHtmlEntry = fileMap.get('app/index.html');
  if (!mainHtmlEntry || mainHtmlEntry.kind !== 'text') {
    throw new Error('GDevelop HTML 导出缺少有效的 app/index.html。');
  }
  const html = mainHtmlEntry.text;
  getPlaymeshMultiplayerRuntimeScriptTags().forEach((
    expectedTag /*: string */
  ) /*: void */ => {
    if (html.split(expectedTag).length - 1 !== 1) {
      throw new Error('Playmesh 兼容运行层必须在主 HTML 中恰好加载一次。');
    }
  });
  if (iconBlob !== undefined && iconBlob !== null) {
    if (!(iconBlob instanceof Blob))
      throw new Error('Playmesh 图标不是 Blob。');
    add(PlaymeshGameManifest.ICON_FILENAME, {
      kind: 'blob',
      blob: iconBlob,
    });
  }
  return fileMap;
};

// This producer is the hand-off boundary for the future App streaming ZIP/import
// contract. It intentionally preserves text/Blob entries and never aggregates the
// package into a single in-memory Blob.
export const createPlaymeshPackageEntryProducer = (
  fileMap /*: PlaymeshPackageFileMap */
) /*: PlaymeshPackageEntryProducer */ => ({
  fileCount: fileMap.size,
  entries: () => fileMap.values(),
});
