// @flow

import assignIn from 'lodash/assignIn';
import { findGDJS } from '../GameEngineFinder/BrowserS3GDJSFinder';
import BrowserFileSystem from '../ExportAndShare/BrowserExporters/BrowserFileSystem';
import { downloadUrlFilesToBlobFiles } from '../Utils/BrowserArchiver';
import Window from '../Utils/Window';
import { getIDEVersionWithHash } from '../Version';
import { isNativeMobileApp } from '../Utils/Platform';
import GDevelopAuthorityBootstrapSource from '../PlaymeshShared/GDevelopAuthorityBootstrapSource';
import GDevelopAppRuntimeDebuggerClientSource from '../PlaymeshShared/GDevelopAppRuntimeDebuggerClientSource';
import GDevelopFpsProbeSource from '../PlaymeshShared/GDevelopFpsProbeSource';
import GDevelopMultiplayerBridgeSource from '../PlaymeshShared/GDevelopMultiplayerBridgeSource';
import { fetchPlaymeshDeveloperStatus } from '../ExportAndShare/PlaymeshPublishController';
import {
  buildGDevelopGameManifest,
  createPlaymeshPackageEntryProducer,
  createPlaymeshPackageFileMap,
  GDEVELOP_AUTHORITY_ENTRY,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import { resolvePlaymeshProjectRuntimePlan } from '../PlaymeshProjectConfig/PlaymeshRuntimePlanResolver';
import {
  getPlaymeshMessage,
} from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

/*::
import type {
  PreviewLauncherProps,
  PreviewOptions,
} from '../ExportAndShare/PreviewLauncher.flow';
import type { PlaymeshDeveloperStatus } from '../ExportAndShare/PlaymeshPublishController';
import type {
  GDevelopGameManifest,
  GDevelopResourcesDownloadOutput,
  PlaymeshPackageEntryProducer,
  PlaymeshPackageFileMap,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import type { ResolvedPlaymeshProjectRuntimePlan } from '../PlaymeshProjectConfig/PlaymeshRuntimePlanResolver';

type PlaymeshPreviewResourceProgress = {|
  phase: 'resources',
  count: number,
  total: number,
|};

export type PlaymeshGatewayPreviewPackage = {|
  gameId: string,
  manifest: GDevelopGameManifest,
  fileMap: PlaymeshPackageFileMap,
  producer: PlaymeshPackageEntryProducer,
  runtimePlan: ResolvedPlaymeshProjectRuntimePlan,
|};

type ConfigurePreviewExportOptions = {|
  exportOptions: gdPreviewExportOptions,
  previewOptions: PreviewOptions,
  launcherProps: PreviewLauncherProps,
|};

type PlaymeshRuntimePlanLoader = typeof resolvePlaymeshProjectRuntimePlan;
type CreatePlaymeshGatewayPreviewPackageOptions = {|
  previewOptions: PreviewOptions,
  launcherProps: PreviewLauncherProps,
  statusLoader?: () => Promise<PlaymeshDeveloperStatus>,
  runtimePlanLoader?: PlaymeshRuntimePlanLoader,
  onProgress?: PlaymeshPreviewResourceProgress => void,
  signal?: ?AbortSignal,
|};
*/

const gd: libGDevelop = global.gd;
const PLAYMESH_APP_RUNTIME_DEBUGGER_CLIENT =
  'playmesh-gdevelop-app-runtime-debugger-client.js';

const createAbortError = () /*: Error */ => {
  const error = new Error('Aborted');
  error.name = 'AbortError';
  return error;
};

const configurePreviewExportOptions = (
  {
    exportOptions,
    previewOptions,
    launcherProps,
  } /*: ConfigurePreviewExportOptions */
) /*: void */ => {
  const {
    project,
    sceneName,
    externalLayoutName,
    eventsBasedObjectType,
    eventsBasedObjectVariantName,
  } = previewOptions;
  exportOptions.setLayoutName(sceneName);
  exportOptions.setIsDevelopmentEnvironment(Window.isDev());
  exportOptions.setIsInGameEdition(previewOptions.isForInGameEdition);
  exportOptions.setEditorId(previewOptions.editorId || '');
  if (externalLayoutName) {
    exportOptions.setExternalLayoutName(externalLayoutName);
  }
  if (eventsBasedObjectType) {
    exportOptions.setEventsBasedObjectType(eventsBasedObjectType);
    exportOptions.setEventsBasedObjectVariantName(
      eventsBasedObjectVariantName || ''
    );
  }

  // v1 intentionally performs a complete export and a DeveloperRun restart on
  // every playable preview. It never advertises or emulates GDevelop hot reload.
  exportOptions.setShouldClearExportFolder(true);
  exportOptions.setShouldReloadProjectData(true);
  exportOptions.setShouldReloadLibraries(true);
  exportOptions.setShouldGenerateScenesEventsCode(true);
  // BrowserFileSystem checks generated absolute includes as physical paths
  // while completing index.html. A query suffix makes data.js and every
  // generated codeN.js fail that existence check, so this full, no-store
  // DeveloperRun export must keep their physical filenames unchanged.
  exportOptions.setNonRuntimeScriptsCacheBurst(0);
  exportOptions.setFullLoadingScreen(previewOptions.fullLoadingScreen);
  exportOptions.setNativeMobileApp(isNativeMobileApp());
  exportOptions.setGDevelopVersionWithHash(getIDEVersionWithHash());
  exportOptions.setCrashReportUploadLevel(launcherProps.crashReportUploadLevel);
  exportOptions.setPreviewContext(launcherProps.previewContext);
  exportOptions.setProjectTemplateSlug(project.getTemplateSlug());
  exportOptions.setSourceGameId(launcherProps.sourceGameId);
  // Playmesh App previews export the canonical GDevelop debugger runtime and
  // then bind it to the existing local App relay below.
  exportOptions.useWindowMessageDebuggerClient();

  const includeFileHashs = launcherProps.getIncludeFileHashs();
  for (const includeFile in includeFileHashs) {
    exportOptions.setIncludeFileHash(
      includeFile,
      includeFileHashs[includeFile]
    );
  }
  if (previewOptions.inAppTutorialMessageInPreview) {
    exportOptions.setInAppTutorialMessageInPreview(
      previewOptions.inAppTutorialMessageInPreview,
      previewOptions.inAppTutorialMessagePositionInPreview
    );
  }
  if (previewOptions.fallbackAuthor) {
    exportOptions.setFallbackAuthor(
      previewOptions.fallbackAuthor.id,
      previewOptions.fallbackAuthor.username
    );
  }
  if (previewOptions.editorCameraState3D) {
    const camera = previewOptions.editorCameraState3D;
    exportOptions.setEditorCameraState3D(
      camera.cameraMode,
      camera.positionX,
      camera.positionY,
      camera.positionZ,
      camera.rotationAngle,
      camera.elevationAngle,
      camera.distance
    );
  }
  if (previewOptions.inGameEditorSettings) {
    exportOptions.setInGameEditorSettingsJson(
      JSON.stringify(previewOptions.inGameEditorSettings)
    );
  }
};

const exportPlayablePreview = async (
  {
    previewOptions,
    launcherProps,
    onProgress,
    signal,
  } /*: {|
  previewOptions: PreviewOptions,
  launcherProps: PreviewLauncherProps,
  onProgress?: PlaymeshPreviewResourceProgress => void,
  signal?: ?AbortSignal,
|} */
) /*: Promise<GDevelopResourcesDownloadOutput> */ => {
  if (signal?.aborted) throw createAbortError();
  const engine = await findGDJS('preview');
  if (signal?.aborted) throw createAbortError();
  const outputDir = '/export/';
  const abstractFileSystem = new BrowserFileSystem({
    textFiles: engine.filesContent,
  });
  const fileSystem = assignIn(
    new gd.AbstractFileSystemJS(),
    abstractFileSystem
  );
  const exporter = new gd.Exporter(fileSystem, engine.gdjsRoot);
  exporter.setCodeOutputDirectory(outputDir);
  const exportOptions = new gd.PreviewExportOptions(
    previewOptions.project,
    outputDir
  );
  try {
    configurePreviewExportOptions({
      exportOptions,
      previewOptions,
      launcherProps,
    });
    exporter.exportProjectForPixiPreview(exportOptions);
  } finally {
    exportOptions.delete();
    exporter.delete();
  }
  if (signal?.aborted) throw createAbortError();

  const textFiles = abstractFileSystem.getAllTextFilesIn(outputDir);
  const indexFile = textFiles.find(file => file.filePath === '/export/index.html');
  if (!indexFile || typeof indexFile.text !== 'string') {
    throw new Error('GDevelop App RuntimeView 预览缺少 index.html。');
  }
  const debuggerTag = `<script src="${PLAYMESH_APP_RUNTIME_DEBUGGER_CLIENT}"></script>`;
  if (indexFile.text.includes(debuggerTag)) {
    throw new Error('GDevelop App RuntimeView 调试器脚本被重复注入。');
  }
  if (!indexFile.text.includes('</head>')) {
    throw new Error('GDevelop App RuntimeView 预览入口缺少 head 结束标签。');
  }
  indexFile.text = indexFile.text.replace(
    '</head>',
    `  ${debuggerTag}\n</head>`
  );
  textFiles.push({
    filePath: `/export/${PLAYMESH_APP_RUNTIME_DEBUGGER_CLIENT}`,
    text: GDevelopAppRuntimeDebuggerClientSource,
  });
  const urlFiles = abstractFileSystem.getAllUrlFilesIn(outputDir);
  const blobFiles = await downloadUrlFilesToBlobFiles({
    urlFiles,
    onProgress: (count, total) => {
      if (onProgress) onProgress({ phase: 'resources', count, total });
    },
  });
  if (signal?.aborted) throw createAbortError();
  return { textFiles, blobFiles };
};

export const createPlaymeshGatewayPreviewPackage = async (
  {
    previewOptions,
    launcherProps,
    statusLoader = fetchPlaymeshDeveloperStatus,
    runtimePlanLoader = resolvePlaymeshProjectRuntimePlan,
    onProgress,
    signal,
  } /*: CreatePlaymeshGatewayPreviewPackageOptions */
) /*: Promise<PlaymeshGatewayPreviewPackage> */ => {
  if (previewOptions.isForInGameEdition) {
    throw new Error(
      'GDevelop 游戏内编辑器必须使用本地官方预览链，不能进入 Playmesh 包预览。'
    );
  }
  const { project } = previewOptions;
  const gameId = launcherProps.playmeshGameId;
  const [runtimePlan, status] = await Promise.all([
    runtimePlanLoader({ gameId, project, target: 'preview', signal }),
    statusLoader(),
  ]);
  if (signal?.aborted) throw createAbortError();
  const { plan } = runtimePlan;
  const manifestMode = plan.manifestMode;
  if (
    plan.blockBeforeExport ||
    manifestMode === 'official' ||
    plan.bundlePresence !== 'full'
  ) {
    throw new Error('Playmesh 预览运行计划无效。');
  }
  if (plan.warning === 'multiplayer_scan_unknown') {
    console.warn(
      getPlaymeshMessage(playmeshMessages.projectConfigScanUnknownWarning)
    );
  }
  const isMultiplayer = manifestMode === 'multiplayer';
  const projectConfig = runtimePlan.config;
  // A project/config mismatch disables only PlayMesh multiplayer. Preview must
  // still export and launch the real GDevelop game as a local solo package.
  // Never replace index.html with a diagnostic document here: doing so makes a
  // non-blocking runtime warning look like a failed/black game preview.
  const resourcesDownloadOutput = await exportPlayablePreview({
    previewOptions,
    launcherProps,
    onProgress,
    signal,
  });
  const manifest = buildGDevelopGameManifest({
    project,
    gameId,
    sdkVersion: status.gameSdkVersion,
    appSdkVersion: status.appSdkVersion,
    lastModifiedAt: Date.now(),
    mode: manifestMode,
    displayMode: 'multi_screen',
    minPlayers:
      isMultiplayer && projectConfig ? projectConfig.minPlayers : 1,
    maxPlayers:
      isMultiplayer && projectConfig ? projectConfig.maxPlayers : 1,
    gameEntry: 'index.html',
    authorityEntry: isMultiplayer ? GDEVELOP_AUTHORITY_ENTRY : undefined,
    tags: projectConfig ? projectConfig.tags : [],
    webRuntimeMultithreading:
      projectConfig?.webRuntimeMultithreading === true,
  });
  const fileMap = createPlaymeshPackageFileMap({
    resourcesDownloadOutput,
    manifest,
    fpsProbeSource: GDevelopFpsProbeSource,
    multiplayerBridgeSource: GDevelopMultiplayerBridgeSource,
    authorityBootstrapSource: GDevelopAuthorityBootstrapSource,
  });
  return {
    gameId: manifest.id,
    manifest,
    fileMap,
    producer: createPlaymeshPackageEntryProducer(fileMap),
    runtimePlan,
  };
};
