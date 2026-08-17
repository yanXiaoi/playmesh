// @flow

import {
  PlaymeshProjectConfigClient,
  PlaymeshProjectConfigClientError,
} from './PlaymeshProjectConfigClient';
import { resolveRuntimePlan } from './PlaymeshRuntimePlan';
import { detectGDevelopMultiplayerActivation } from '../PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection';

/*::
import type {
  PlaymeshProjectConfig,
  PlaymeshProjectConfigReadResponse,
} from './PlaymeshProjectConfigProtocol';
import type {
  PlaymeshRuntimeConfigStatus,
  PlaymeshRuntimePlan,
  PlaymeshRuntimeScanActivation,
  PlaymeshRuntimeTarget,
} from './PlaymeshRuntimePlan';

interface PlaymeshRuntimeConfigReader {
  read(options: {|
    gameId: string,
    signal?: ?AbortSignal,
  |}): Promise<PlaymeshProjectConfigReadResponse>;
}

type ResolvePlaymeshProjectRuntimePlanOptions = {|
  gameId: string,
  project: ?gdProject,
  target: PlaymeshRuntimeTarget,
  signal?: ?AbortSignal,
  client?: PlaymeshRuntimeConfigReader,
  detectActivation?: ?gdProject => PlaymeshRuntimeScanActivation,
|};

export type ResolvedPlaymeshProjectRuntimePlan = {|
  configStatus: PlaymeshRuntimeConfigStatus,
  config: ?PlaymeshProjectConfig,
  scanActivation: PlaymeshRuntimeScanActivation,
  plan: PlaymeshRuntimePlan,
|};
*/

const configStatusFromResponse = (
  response /*: PlaymeshProjectConfigReadResponse */
) /*: PlaymeshRuntimeConfigStatus */ => {
  if (response.status === 'ready') return response.config.gameType;
  return response.status;
};

const isCancelled = (error /*: mixed */, signal /*: ?AbortSignal */) =>
  !!signal?.aborted ||
  (error instanceof PlaymeshProjectConfigClientError &&
    error.code === 'cancelled');

export const resolvePlaymeshProjectRuntimePlan = async (
  {
    gameId,
    project,
    target,
    signal,
    client = new PlaymeshProjectConfigClient(),
    detectActivation = detectGDevelopMultiplayerActivation,
  } /*: ResolvePlaymeshProjectRuntimePlanOptions */
) /*: Promise<ResolvedPlaymeshProjectRuntimePlan> */ => {
  let scanActivation /*: PlaymeshRuntimeScanActivation */ = 'unknown';
  try {
    scanActivation = detectActivation(project);
  } catch (_) {
    scanActivation = 'unknown';
  }

  let configStatus /*: PlaymeshRuntimeConfigStatus */ = 'unavailable';
  let config /*: ?PlaymeshProjectConfig */ = null;
  try {
    const response = await client.read({ gameId, signal });
    configStatus = configStatusFromResponse(response);
    config = response.status === 'ready' ? response.config : null;
  } catch (error) {
    if (isCancelled(error, signal)) {
      const cancelledError = new Error('Aborted');
      cancelledError.name = 'AbortError';
      throw cancelledError;
    }
    configStatus = 'unavailable';
    config = null;
  }

  return {
    configStatus,
    config,
    scanActivation,
    plan: resolveRuntimePlan(configStatus, scanActivation, target),
  };
};
