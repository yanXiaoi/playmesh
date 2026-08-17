// @flow

import { browserHTML5ExportPipeline } from './BrowserExporters/BrowserHTML5Export';
import GDevelopAuthorityBootstrapSource from '../PlaymeshShared/GDevelopAuthorityBootstrapSource';
import GDevelopFpsProbeSource from '../PlaymeshShared/GDevelopFpsProbeSource';
import GDevelopMultiplayerBridgeSource from '../PlaymeshShared/GDevelopMultiplayerBridgeSource';
import {
  buildGDevelopGameManifest,
  createPlaymeshPackageEntryProducer,
  createPlaymeshPackageFileMap,
  GDEVELOP_AUTHORITY_ENTRY,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import { resolvePlaymeshProjectRuntimePlan } from '../PlaymeshProjectConfig/PlaymeshRuntimePlanResolver';
import { getPlaymeshMessage } from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

/*::
import type { I18n as I18nType } from '@lingui/core';
import type { EventsFunctionsExtensionsState } from '../EventsFunctionsExtensionsLoader/EventsFunctionsExtensionsContext';
import type {
  GDevelopGameManifest,
  PlaymeshPackageEntryProducer,
  PlaymeshPackageFileMap,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import type { ResolvedPlaymeshProjectRuntimePlan } from '../PlaymeshProjectConfig/PlaymeshRuntimePlanResolver';

type PlaymeshMixedRecord = { +[string]: mixed };

export type PlaymeshDeveloperStatus = {
  gameSdkVersion: string,
  appSdkVersion: string,
  [string]: mixed,
};

export type PlaymeshPreparedPublish = {|
  gameId: string,
  manifest: GDevelopGameManifest,
  fileMap: PlaymeshPackageFileMap,
  producer: PlaymeshPackageEntryProducer,
  runtimePlan: ResolvedPlaymeshProjectRuntimePlan,
|};

type PlaymeshPublishPipeline = typeof browserHTML5ExportPipeline;
type PlaymeshPublishProgress = {| count: number, total: number |};
type PlaymeshRuntimePlanLoader = typeof resolvePlaymeshProjectRuntimePlan;
type PlaymeshPublishOptions = {|
  project: gdProject,
  gameId: string,
  i18n: I18nType,
  eventsFunctionsExtensionsState?: ?EventsFunctionsExtensionsState,
  onProgress?: PlaymeshPublishProgress => void,
  signal?: ?AbortSignal,
  pipeline?: PlaymeshPublishPipeline,
  statusLoader?: () => Promise<PlaymeshDeveloperStatus>,
  runtimePlanLoader?: PlaymeshRuntimePlanLoader,
|};
*/

export class PlaymeshPublishError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshPublishError';
    this.code = code;
  }
}

const mixedRecord = (value /*: mixed */) /*: ?PlaymeshMixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

export const fetchPlaymeshDeveloperStatus = async () /*: Promise<PlaymeshDeveloperStatus> */ => {
  let response;
  try {
    response = await fetch('/dev/api/status', {
      credentials: 'same-origin',
      cache: 'no-store',
    });
  } catch (_) {
    throw new PlaymeshPublishError(
      'developer_gateway_unavailable',
      '当前无法连接 Playmesh 本地开发通道。'
    );
  }
  if (!response.ok) {
    throw new PlaymeshPublishError(
      'developer_gateway_unavailable',
      `Playmesh 本地开发通道返回 HTTP ${response.status}。`
    );
  }
  const status /*: mixed */ = await response.json();
  const statusRecord = mixedRecord(status);
  if (
    !statusRecord ||
    typeof statusRecord.gameSdkVersion !== 'string' ||
    typeof statusRecord.appSdkVersion !== 'string'
  ) {
    throw new PlaymeshPublishError(
      'invalid_developer_status',
      'Playmesh 本地开发通道没有返回 SDK 版本。'
    );
  }
  return {
    gameSdkVersion: statusRecord.gameSdkVersion,
    appSdkVersion: statusRecord.appSdkVersion,
  };
};

export const createPlaymeshGDevelopPublishFileMap = async (
  {
    project,
    gameId,
    i18n,
    eventsFunctionsExtensionsState,
    onProgress,
    signal,
    pipeline = browserHTML5ExportPipeline,
    statusLoader = fetchPlaymeshDeveloperStatus,
    runtimePlanLoader = resolvePlaymeshProjectRuntimePlan,
  } /*: PlaymeshPublishOptions */
) /*: Promise<PlaymeshPreparedPublish> */ => {
  const throwIfCancelled = () => {
    if (signal && signal.aborted) {
      const error = new Error('发布已取消。');
      error.name = 'AbortError';
      throw error;
    }
  };
  throwIfCancelled();
  const runtimePlan = await runtimePlanLoader({
    gameId,
    project,
    target: 'publish',
    signal,
  });
  throwIfCancelled();
  const { plan } = runtimePlan;
  if (plan.blockBeforeExport) {
    throw new PlaymeshPublishError(
      'project_config_blocks_multiplayer_publish',
      getPlaymeshMessage(playmeshMessages.projectConfigPublishBlocked)
    );
  }
  if (
    plan.manifestMode === 'official' ||
    plan.bundlePresence !== 'full'
  ) {
    throw new PlaymeshPublishError(
      'invalid_runtime_plan',
      'Playmesh 发布运行计划无效。'
    );
  }
  if (plan.warning === 'multiplayer_scan_unknown') {
    console.warn(
      getPlaymeshMessage(playmeshMessages.projectConfigScanUnknownWarning)
    );
  }
  const manifestMode =
    plan.manifestMode === 'multiplayer' ? 'multiplayer' : 'solo';
  const isMultiplayer = manifestMode === 'multiplayer';
  const projectConfig = runtimePlan.config;
  const status = await statusLoader();
  throwIfCancelled();
  const manifest = buildGDevelopGameManifest({
    project,
    gameId,
    sdkVersion: status.gameSdkVersion,
    appSdkVersion: status.appSdkVersion,
    lastModifiedAt: Date.now(),
    mode: manifestMode,
    displayMode: 'multi_screen',
    minPlayers: isMultiplayer && projectConfig ? projectConfig.minPlayers : 1,
    maxPlayers: isMultiplayer && projectConfig ? projectConfig.maxPlayers : 1,
    gameEntry: 'index.html',
    authorityEntry: isMultiplayer ? GDEVELOP_AUTHORITY_ENTRY : undefined,
    tags: projectConfig ? projectConfig.tags : [],
  });
  const exportState = pipeline.getInitialExportState(project);
  const context = {
    project,
    exportState,
    i18n,
    updateStepProgress: (
      count /*: number */,
      total /*: number */
    ) /*: void */ => {
      if (onProgress) onProgress({ count, total });
    },
  };
  const preparedExporter = await pipeline.prepareExporter(context);
  throwIfCancelled();
  if (eventsFunctionsExtensionsState) {
    await eventsFunctionsExtensionsState.ensureLoadFinished();
  }
  throwIfCancelled();
  const exportOutput = await pipeline.launchExport(
    context,
    preparedExporter,
    null
  );
  throwIfCancelled();
  const resourcesDownloadOutput = await pipeline.launchResourcesDownload(
    context,
    exportOutput
  );
  throwIfCancelled();
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
